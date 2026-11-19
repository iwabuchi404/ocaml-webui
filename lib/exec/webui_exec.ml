type exit_status =
  | Exited of int
  | Signaled of int
  | Stopped of int

type completed = {
  status : exit_status;
  stdout : string;
  stderr : string;
  duration_ms : float;
}

type partial = { stdout : string; stderr : string }

type error =
  | Spawn_failed of string
  | Timeout of partial
  | Cancelled of partial
  | Output_exceeded of partial
  | Io_error of string

(* POSIX: writing to a dead child's stdin raises EPIPE and the default
   SIGPIPE disposition would kill the whole process. Ignore it once so
   the writer domain sees a Sys_error instead. Harmless on Windows. *)
let ignore_sigpipe_once =
  let done_ = Atomic.make false in
  fun () ->
    if not (Atomic.exchange done_ true) then
      (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore with _ -> ())

(* Channels whose fd was force-closed underneath a still-blocked domain
   must never reach the GC finalizer — it would close a recycled fd.
   Keeping them reachable forever is the safe trade (bounded by edge
   cases where a descendant holds the pipe open). *)
let leaked_channels : Obj.t list ref = ref []
let leaked_mutex = Mutex.create ()

let leak_channel ch =
  Mutex.protect leaked_mutex (fun () ->
      leaked_channels := Obj.repr ch :: !leaked_channels)

let to_exit_status = function
  | Unix.WEXITED n -> Exited n
  | Unix.WSIGNALED n -> Signaled n
  | Unix.WSTOPPED n -> Stopped n

(* Terminate the direct child, then reap it. waitpid is owned solely by
   run's poller: a WNOHANG call also reaps, so it must never be used as a
   mere liveness check elsewhere. *)
let kill_and_reap pid =
  (try Unix.kill pid Sys.sigkill with _ -> ());
  try ignore (Unix.waitpid [] pid) with _ -> ()

let run ~argv ?stdin ?timeout_ms ?token
    ?(max_output_bytes = 16 * 1024 * 1024) ?trace ?(trace_id = "") () =
  ignore_sigpipe_once ();
  match argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ -> (
      let started = Unix.gettimeofday () in
      let emit name data =
        match trace with
        | None -> ()
        | Some sink -> sink (Webui_trace.make ~name ~trace_id ~data ())
      in
      match
        (try
           Ok
             (Unix.open_process_args_full prog (Array.of_list argv)
                (Unix.environment ()))
         with e -> Error (Printexc.to_string e))
      with
      | Error msg -> Error (Spawn_failed msg)
      | Ok (ic, oc, ec) -> (
          set_binary_mode_in ic true;
          set_binary_mode_out oc true;
          set_binary_mode_in ec true;
          let pid = Unix.process_full_pid (ic, oc, ec) in
          emit "exec_spawn"
            [ ("argv", `String (String.concat " " argv)); ("pid", `Int pid) ];
          let out_buf = Buffer.create 4096 in
          let err_buf = Buffer.create 4096 in
          let io_mutex = Mutex.create () in
          let exceeded = Atomic.make false in
          let out_done = Atomic.make false in
          let err_done = Atomic.make false in
          let in_done = Atomic.make false in
          let duration_ms () = (Unix.gettimeofday () -. started) *. 1000. in
          let partial () =
            Mutex.protect io_mutex (fun () ->
                {
                  stdout = Buffer.contents out_buf;
                  stderr = Buffer.contents err_buf;
                })
          in
          (* Each channel has exactly one owning domain. Reads stop (not
             truncate) once the combined cap is exceeded. *)
          let reader ch buf done_flag =
            let tmp = Bytes.create 65536 in
            (try
               let rec loop () =
                 match input ch tmp 0 65536 with
                 | 0 -> ()
                 | n ->
                     let stop =
                       Mutex.protect io_mutex (fun () ->
                           if
                             Buffer.length out_buf + Buffer.length err_buf + n
                             > max_output_bytes
                           then (
                             Atomic.set exceeded true;
                             true)
                           else (
                             Buffer.add_subbytes buf tmp 0 n;
                             false))
                     in
                     if not stop then loop ()
               in
               loop ()
             with _ -> ());
            Atomic.set done_flag true
          in
          let d_out = Domain.spawn (fun () -> reader ic out_buf out_done) in
          let d_err = Domain.spawn (fun () -> reader ec err_buf err_done) in
          let d_in =
            Domain.spawn (fun () ->
                (try
                   (match stdin with
                    | Some s -> output_string oc s
                    | None -> ());
                   (* Always close stdin so the child observes EOF, even
                      when no input was given. *)
                   close_out oc
                 with _ -> ());
                Atomic.set in_done true)
          in
          (* POSIX: closing the fd underneath the channel makes a blocked
             read/write fail, unblocking a domain stuck on a pipe that
             will never see EOF. Windows does NOT offer the same
             guarantee — CloseHandle cannot cancel an in-flight
             ReadFile/WriteFile, and the close leaves the channel's
             fd stale, so its GC finalizer could later close a recycled
             fd. Therefore force_close runs on POSIX only; on Windows a
             still-blocked domain is left as a lingering task (see
             finish) holding its still-valid channel. *)
          let force_close () =
            if not Sys.win32 then begin
              (try Unix.close (Unix.descr_of_in_channel ic) with _ -> ());
              (try Unix.close (Unix.descr_of_in_channel ec) with _ -> ());
              try Unix.close (Unix.descr_of_out_channel oc) with _ -> ()
            end
          in
          (* Channel-level close takes the channel mutex, which a blocked
             I/O op holds — only call it for domains already done. *)
          let mark_closed flag close_ch =
            if Atomic.get flag then (try close_ch () with _ -> ())
          in
          let join_if_done flag d =
            if Atomic.get flag then ignore (Domain.join d)
          in
          (* Bounded wait for the I/O domains. Beyond the grace window
             the pipes are force-closed (POSIX) once; a domain that still
             does not finish is left lingering — it keeps its channel
             alive, exits when the pipe eventually closes, and is never
             joined. *)
          let finish () =
            let rec wait t_end =
              if
                Atomic.get out_done && Atomic.get err_done
                && Atomic.get in_done
              then `All
              else if Unix.gettimeofday () >= t_end then `Pending
              else (
                Unix.sleepf 0.005;
                wait t_end)
            in
            (match wait (Unix.gettimeofday () +. 0.5) with
             | `All -> ()
             | `Pending ->
                 force_close ();
                 ignore (wait (Unix.gettimeofday () +. 0.5)));
            join_if_done out_done d_out;
            join_if_done err_done d_err;
            join_if_done in_done d_in;
            mark_closed out_done (fun () -> close_in_noerr ic);
            mark_closed err_done (fun () -> close_in_noerr ec);
            mark_closed in_done (fun () -> close_out_noerr oc);
            if not Sys.win32 then begin
              if not (Atomic.get out_done) then leak_channel ic;
              if not (Atomic.get err_done) then leak_channel ec;
              if not (Atomic.get in_done) then leak_channel oc
            end;
            if
              not
                (Atomic.get out_done && Atomic.get err_done
                && Atomic.get in_done)
            then emit "exec_io_lingering" []
          in
          let cancelled () =
            match token with
            | Some t -> Webui_async.is_cancelled t
            | None -> false
          in
          let deadline =
            match timeout_ms with
            | Some ms -> started +. (float_of_int ms /. 1000.)
            | None -> Float.max_float
          in
          (* The poller is the sole reap owner. *)
          let rec poll () =
            if Atomic.get exceeded then `Exceeded
            else if cancelled () then `Cancelled
            else if Unix.gettimeofday () >= deadline then `Timed_out
            else
              match
                (try `Ok (Unix.waitpid [ Unix.WNOHANG ] pid)
                 with Unix.Unix_error (e, _, _) ->
                   `Err (Unix.error_message e))
              with
              | `Ok (0, _) ->
                  Unix.sleepf 0.005;
                  poll ()
              | `Ok (_, st) -> `Exited st
              | `Err msg -> `Io msg
          in
          match poll () with
          | `Exited st ->
              finish ();
              let status = to_exit_status st in
              emit "exec_exit"
                [
                  ( "status",
                    `String
                      (match st with
                       | Unix.WEXITED n -> Printf.sprintf "exit %d" n
                       | Unix.WSIGNALED n -> Printf.sprintf "signal %d" n
                       | Unix.WSTOPPED n -> Printf.sprintf "stop %d" n) );
                  ("duration_ms", `Float (duration_ms ()));
                ];
              let p = partial () in
              Ok
                {
                  status;
                  stdout = p.stdout;
                  stderr = p.stderr;
                  duration_ms = duration_ms ();
                }
          | `Timed_out ->
              kill_and_reap pid;
              finish ();
              emit "exec_timeout"
                [
                  ("timeout_ms",
                    (match timeout_ms with
                     | Some ms -> `Int ms
                     | None -> `Null));
                  ("duration_ms", `Float (duration_ms ()));
                ];
              Error (Timeout (partial ()))
          | `Cancelled ->
              kill_and_reap pid;
              finish ();
              emit "exec_cancelled"
                [ ("duration_ms", `Float (duration_ms ())) ];
              Error (Cancelled (partial ()))
          | `Exceeded ->
              kill_and_reap pid;
              finish ();
              emit "exec_output_exceeded"
                [
                  ("max_output_bytes", `Int max_output_bytes);
                  ("duration_ms", `Float (duration_ms ()));
                ];
              Error (Output_exceeded (partial ()))
          | `Io msg ->
              kill_and_reap pid;
              finish ();
              emit "exec_io_error" [ ("message", `String msg) ];
              Error (Io_error msg)))
