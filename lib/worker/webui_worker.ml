type restart_policy = Never | On_crash of int

type error =
  | Spawn_failed of string
  | Worker_exited
  | Worker_killed
  | Worker_dead
  | Timeout
  | Cancelled
  | Remote_error of Yojson.Safe.t
  | Protocol_error of string

type status = Alive | Dead | Killed

type proc = {
  pid : int;
  ic : in_channel;
  oc : out_channel;
  pair : in_channel * out_channel;
}

type pending = {
  mutable result : (Yojson.Safe.t, error) result option;
  trace_id : string;
  started_at : float;
}

type worker = {
  name : string;
  prog : string;
  argv : string array;
  restart : restart_policy;
  on_notification : Yojson.Safe.t -> unit;
  trace : Webui_trace.sink option;
  mutex : Mutex.t;
  pending : (int, pending) Hashtbl.t;
  mutable proc : proc option;
  mutable status : status;
  mutable restart_count : int;
  mutable next_id : int;
  mutable resource : Webui_resource.resource option;
}

let emit w ?(trace_id = "") ?(request_id = "") ~name data =
  match w.trace with
  | None -> ()
  | Some sink ->
      sink
        (Webui_trace.make ~name ~trace_id ~request_id
           ~data:(("worker", `String w.name) :: data)
           ())

(* Force-terminates a process. On Windows [Unix.kill ... sigkill] maps to
   TerminateProcess on the process handle returned by open_process_args;
   on POSIX it is SIGKILL. Best effort: a stale handle is ignored. *)
let terminate pid =
  try Unix.kill pid Sys.sigkill with _ -> ()

(* All callers hold [w.mutex]. Marks every pending request as failed and
   returns how many were failed. *)
let fail_all_pending w err =
  let n = Hashtbl.length w.pending in
  Hashtbl.iter (fun _ p -> p.result <- Some (Error err)) w.pending;
  Hashtbl.clear w.pending;
  n

let spawn_proc w =
  match
    (try Ok (Unix.open_process_args w.prog w.argv)
     with e -> Error (Printexc.to_string e))
  with
  | Error msg -> Error (Spawn_failed msg)
  | Ok (ic, oc) ->
      let pid = Unix.process_pid (ic, oc) in
      Ok { pid; ic; oc; pair = (ic, oc) }

let safe_input_line ic =
  match (try Some (input_line ic) with _ -> None) with
  | Some line -> `Line line
  | None -> `Eof

let string_of_process_status = function
  | Unix.WEXITED n -> Printf.sprintf "exited %d" n
  | Unix.WSIGNALED n -> Printf.sprintf "signaled %d" n
  | Unix.WSTOPPED n -> Printf.sprintf "stopped %d" n

let truncate s n =
  if String.length s <= n then s else String.sub s 0 n ^ "..."

let result_of_fields fields =
  match List.assoc_opt "error" fields with
  | Some e when e <> `Null -> Error (Remote_error e)
  | _ -> (
      match List.assoc_opt "result" fields with
      | Some r -> Ok r
      | None ->
          Error (Protocol_error "response carries neither result nor error"))

(* Delivers a response to its pending entry, or reports it as late. *)
let deliver w id fields =
  let matched =
    Mutex.protect w.mutex (fun () ->
        match Hashtbl.find_opt w.pending id with
        | Some p ->
            let r = result_of_fields fields in
            p.result <- Some r;
            Hashtbl.remove w.pending id;
            Some (p, r)
        | None -> None)
  in
  match matched with
  | None ->
      emit w ~request_id:(string_of_int id) ~name:"worker_late_response" []
  | Some (p, r) ->
      emit w ~trace_id:p.trace_id ~request_id:(string_of_int id)
        ~name:"worker_response"
        [
          ("outcome", `String (match r with Ok _ -> "ok" | Error _ -> "error"));
          ("duration_ms",
            `Float ((Unix.gettimeofday () -. p.started_at) *. 1000.));
        ]

let notify w json =
  emit w ~name:"worker_notification"
    [
      ("method",
        (match json with
         | `Assoc f -> (
             match List.assoc_opt "method" f with
             | Some (`String m) -> `String m
             | _ -> `Null)
         | _ -> `Null));
    ];
  (try w.on_notification json with _ -> ())

let dispatch_line w line =
  match (try Some (Yojson.Safe.from_string line) with _ -> None) with
  | None ->
      emit w ~name:"worker_protocol_error"
        [ ("line", `String (truncate line 200)) ]
  | Some ((`Assoc fields) as json) -> (
      match List.assoc_opt "id" fields with
      | Some (`Int id) -> deliver w id fields
      | Some (`Intlit s) | Some (`String s) -> (
          match int_of_string_opt s with
          | Some id -> deliver w id fields
          | None -> notify w json)
      | _ -> notify w json)
  | Some json -> notify w json

(* Reader/supervisor loop: one domain per worker that survives restarts. *)
let rec reader_loop w p =
  match safe_input_line p.ic with
  | `Line line ->
      dispatch_line w line;
      reader_loop w p
  | `Eof -> on_eof w p

and on_eof w p =
  (* close_process reaps the child; it may block briefly if the child
     closed stdout but lingers. *)
  let pstatus =
    match (try Some (Unix.close_process p.pair) with _ -> None) with
    | Some s -> string_of_process_status s
    | None -> "unknown"
  in
  let events, next =
    Mutex.protect w.mutex (fun () ->
        let intentional = w.status = Killed in
        if w.proc == Some p then w.proc <- None;
        let failed =
          fail_all_pending w
            (if intentional then Worker_killed else Worker_exited)
        in
        let will_restart =
          (not intentional)
          &&
          match w.restart with
          | Never -> false
          | On_crash max -> w.restart_count < max
        in
        let exited =
          ( "worker_exited",
            [
              ("pid", `Int p.pid);
              ("status", `String pstatus);
              ("intentional", `Bool intentional);
              ("will_restart", `Bool will_restart);
              ("pending_failed", `Int failed);
            ] )
        in
        if will_restart then
          match spawn_proc w with
          | Ok np ->
              w.restart_count <- w.restart_count + 1;
              w.proc <- Some np;
              ( [
                  exited;
                  ( "worker_restart",
                    [
                      ("attempt", `Int w.restart_count);
                      ("pid", `Int np.pid);
                    ] );
                ],
                `Restart np )
          | Error e ->
              w.status <- Dead;
              ( [
                  exited;
                  ( "worker_spawn_failed",
                    [
                      ("phase", `String "restart");
                      ("message",
                        `String
                          (match e with Spawn_failed m -> m | _ -> "unknown"));
                    ] );
                ],
                `Stop )
        else (
          if not intentional then w.status <- Dead;
          ([ exited ], `Stop)))
  in
  List.iter (fun (name, data) -> emit w ~name data) events;
  match next with
  | `Restart np -> reader_loop w np
  | `Stop -> (
      match w.resource with
      | Some r -> Webui_resource.release r
      | None -> ())

(* Flat registry backing [shutdown_all]; entries are pruned lazily. *)
module Registry = struct
  let mutex = Mutex.create ()
  let workers : worker list ref = ref []

  let add w =
    Mutex.protect mutex (fun () -> workers := w :: !workers)

  let remove w =
    Mutex.protect mutex (fun () ->
        workers := List.filter (fun x -> not (x == w)) !workers)

  let snapshot () = Mutex.protect mutex (fun () -> !workers)
end

let is_alive w =
  Mutex.protect w.mutex (fun () -> w.status = Alive && w.proc <> None)

let kill w =
  let target =
    Mutex.protect w.mutex (fun () ->
        if w.status = Killed then None
        else (
          w.status <- Killed;
          let failed = fail_all_pending w Worker_killed in
          Registry.remove w;
          match w.proc with
          | Some p -> Some (p.pid, failed)
          | None -> None))
  in
  match target with
  | Some (pid_, failed) ->
      emit w ~name:"worker_killed"
        [ ("pid", `Int pid_); ("pending_failed", `Int failed) ];
      terminate pid_;
      (match w.resource with
       | Some r -> Webui_resource.release r
       | None -> ())
  | None -> ()

let spawn ~name ~argv ?(restart = Never)
    ?(on_notification = fun _ -> ()) ?trace ?(scope = Webui_resource.App) () =
  match argv with
  | [] -> Error (Spawn_failed "empty argv")
  | prog :: _ -> (
      let w =
        {
          name;
          prog;
          argv = Array.of_list argv;
          restart;
          on_notification;
          trace;
          mutex = Mutex.create ();
          pending = Hashtbl.create 8;
          proc = None;
          status = Alive;
          restart_count = 0;
          next_id = 1;
          resource = None;
        }
      in
      match spawn_proc w with
      | Error e -> Error e
      | Ok p ->
          w.proc <- Some p;
          emit w ~name:"worker_spawned" [ ("pid", `Int p.pid) ];
          w.resource <-
            Some
              (Webui_resource.register ~kind:"worker" ~name ~scope
                 ~release:(fun () -> if is_alive w then kill w)
                 ());
          Registry.add w;
          let (_ : unit Domain.t) = Domain.spawn (fun () -> reader_loop w p) in
          Ok w)

let status w = Mutex.protect w.mutex (fun () -> w.status)

let pid w =
  Mutex.protect w.mutex (fun () ->
      match w.proc with Some p -> Some p.pid | None -> None)

let restart_count w = w.restart_count

let pending_count w =
  Mutex.protect w.mutex (fun () -> Hashtbl.length w.pending)

let request w ?(trace_id = "") ?timeout_ms ?token ~method_ params =
  let acquired =
    Mutex.protect w.mutex (fun () ->
        match w.proc, w.status with
        | Some p, Alive ->
            let id = w.next_id in
            w.next_id <- id + 1;
            let pended =
              {
                result = None;
                trace_id;
                started_at = Unix.gettimeofday ();
              }
            in
            Hashtbl.replace w.pending id pended;
            `Acquired (p, id, pended)
        | _, Killed -> `Refused Worker_killed
        | _ -> `Refused Worker_dead)
  in
  match acquired with
  | `Refused e -> Error e
  | `Acquired (p, id, pended) ->
      let msg =
        Yojson.Safe.to_string
          (`Assoc
            [
              ("jsonrpc", `String "2.0");
              ("id", `Int id);
              ("method", `String method_);
              ("params", params);
            ])
      in
      let write_ok =
        match
          (try
             output_string p.oc msg;
             output_char p.oc '\n';
             flush p.oc;
             true
           with _ -> false)
      with
      | false ->
          Mutex.protect w.mutex (fun () ->
              Hashtbl.remove w.pending id;
              pended.result <- Some (Error Worker_exited));
          false
      | ok -> ok
      in
      if not write_ok then Error Worker_exited
      else
        let () =
          emit w ~trace_id ~request_id:(string_of_int id)
            ~name:"worker_request"
            [ ("method", `String method_); ("request_id", `Int id) ]
        in
        let deadline =
          match timeout_ms with
          | Some ms -> Unix.gettimeofday () +. (float_of_int ms /. 1000.)
          | None -> Float.max_float
        in
        let token_cancelled () =
          match token with
          | Some t -> Webui_async.is_cancelled t
          | None -> false
        in
        let rec poll () =
          match
            Mutex.protect w.mutex (fun () ->
                match pended.result with
                | Some r -> `Done r
                | None ->
                    if token_cancelled () then (
                      Hashtbl.remove w.pending id;
                      `Cancelled_tok)
                    else if Unix.gettimeofday () >= deadline then (
                      Hashtbl.remove w.pending id;
                      `Timed_out)
                    else `Wait)
          with
          | `Done r -> r
          | `Cancelled_tok ->
              emit w ~trace_id ~request_id:(string_of_int id)
                ~name:"worker_request_cancelled"
                [ ("method", `String method_); ("request_id", `Int id) ];
              Error Cancelled
          | `Timed_out ->
              emit w ~trace_id ~request_id:(string_of_int id)
                ~name:"worker_timeout"
                [
                  ("method", `String method_);
                  ("request_id", `Int id);
                  ("timeout_ms",
                    (match timeout_ms with
                     | Some ms -> `Int ms
                     | None -> `Null));
                ];
              Error Timeout
          | `Wait ->
              Unix.sleepf 0.005;
              poll ()
        in
        poll ()

(* Kills every live worker (any scope), then revokes the App scope so
   non-worker app resources registered via Webui_resource are released
   too. This is the compatibility path for the resource layer: callers
   wanting finer control use Webui_resource.revoke_scope directly. *)
let shutdown_all () =
  List.iter kill (Registry.snapshot ());
  ignore (Webui_resource.revoke_scope Webui_resource.App)
