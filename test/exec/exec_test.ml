(* Headless tests for Webui_exec. These cases double as the
   termination-mechanism spike from the exec-layer plan: they pin down
   that a blocked stdin write, a stderr flood, or a descendant holding
   the pipes cannot make run() unboundedly wait. *)

module E = Webui_exec

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  %s: ok\n" name
  else begin
    incr failures;
    Printf.printf "  %s: FAIL\n" name
  end

let probe_argv extra =
  Filename.concat (Filename.dirname Sys.argv.(0)) "exec_probe.exe" :: extra

let elapsed_ms f =
  let t0 = Unix.gettimeofday () in
  let r = f () in
  (r, (Unix.gettimeofday () -. t0) *. 1000.)

let test_echo () =
  match
    E.run ~argv:(probe_argv []) ~stdin:"hello\n" ()
  with
  | Ok c ->
      check "echo stdout" (c.stdout = "hello\n");
      check "echo stderr empty" (c.stderr = "");
      check "echo exit 0" (c.status = E.Exited 0)
  | Error _ -> check "echo completed" false

let test_no_stdin_sends_eof () =
  (* Without ~stdin, run must still close stdin so a cat-like child
     sees EOF and exits. *)
  match E.run ~argv:(probe_argv []) ~timeout_ms:5000 () with
  | Ok c -> check "no-stdin EOF exit 0" (c.status = E.Exited 0)
  | Error _ -> check "no-stdin completed" false

let test_timeout_kills () =
  let r, ms =
    elapsed_ms (fun () ->
        E.run ~argv:(probe_argv [ "--sleep"; "30000" ]) ~timeout_ms:200 ())
  in
  (match r with
   | Error (E.Timeout _) -> check "timeout error" true
   | _ -> check "timeout error" false);
  check "timeout bounded" (ms < 5000.)

let test_timeout_partial () =
  match
    E.run
      ~argv:(probe_argv [ "--say-stderr"; "CHUNK"; "--sleep"; "30000" ])
      ~timeout_ms:300 ()
  with
  | Error (E.Timeout p) ->
      check "partial stderr kept" (String.length p.stderr > 0)
  | _ -> check "timeout partial" false

let test_cancel_kills () =
  let token = Webui_async.token () in
  let d =
    Domain.spawn (fun () ->
        Unix.sleepf 0.1;
        Webui_async.cancel token `Js_cancel)
  in
  let r, ms =
    elapsed_ms (fun () ->
        E.run ~argv:(probe_argv [ "--sleep"; "30000" ]) ~token ())
  in
  ignore (Domain.join d);
  (match r with
   | Error (E.Cancelled _) -> check "cancel error" true
   | _ -> check "cancel error" false);
  check "cancel bounded" (ms < 5000.)

let test_stdin_blocked_times_out () =
  (* A 1 MiB stdin to a child that never reads leaves the writer
     blocked; timeout must still fire and cleanup must stay bounded. *)
  let big = String.make (1024 * 1024) 'x' in
  let r, ms =
    elapsed_ms (fun () ->
        E.run ~argv:(probe_argv [ "--noread" ]) ~stdin:big ~timeout_ms:300
          ())
  in
  (match r with
   | Error (E.Timeout _) -> check "blocked-stdin timeout" true
   | _ -> check "blocked-stdin timeout" false);
  check "blocked-stdin bounded" (ms < 5000.)

let test_stderr_separation () =
  match
    E.run
      ~argv:
        (probe_argv
           [ "--say-stdout"; "OUT"; "--say-stderr"; "ERR"; "--exit"; "0" ])
      ()
  with
  | Ok c ->
      check "stdout separated" (c.stdout = "OUT");
      check "stderr separated" (c.stderr = "ERR")
  | Error _ -> check "separation completed" false

let test_output_exceeded () =
  let r, ms =
    elapsed_ms (fun () ->
        E.run ~argv:(probe_argv [ "--stdout-flood" ])
          ~max_output_bytes:(2 * 1024 * 1024) ())
  in
  (match r with
   | Error (E.Output_exceeded p) ->
       check "output exceeded" true;
       check "partial within cap"
         (String.length p.stdout + String.length p.stderr
         <= 2 * 1024 * 1024)
   | _ -> check "output exceeded" false);
  check "exceeded bounded" (ms < 10000.)

let test_exit_code () =
  match E.run ~argv:(probe_argv [ "--exit"; "7" ]) () with
  | Ok c -> check "exit 7" (c.status = E.Exited 7)
  | Error _ -> check "exit code completed" false

let test_spawn_failed () =
  match E.run ~argv:[ "nonexistent-exec-probe-xyz-123" ] () with
  | Error (E.Spawn_failed _) -> check "spawn failed" true
  | _ -> check "spawn failed" false

let test_grandchild_pipe_hold () =
  (* The child exits immediately but a grandchild inherits the pipe
     write ends and sleeps 10s. EOF never arrives; run must force-close
     the pipes after its bounded grace and still return promptly. *)
  let r, ms =
    elapsed_ms (fun () ->
        E.run
          ~argv:
            (probe_argv
               [ "--say-stdout"; "BEFORE"; "--grandchild"; "10000" ])
          ~timeout_ms:30000 ())
  in
  (match r with
   | Ok c ->
       check "grandchild completed" true;
       check "grandchild stdout drained" (c.stdout = "BEFORE")
   | Error _ -> check "grandchild completed" false);
  check "grandchild bounded" (ms < 5000.)

let test_trace () =
  let sink, snapshot = Webui_trace.ring_buffer ~capacity:32 in
  (match
     E.run ~argv:(probe_argv [ "--exit"; "0" ]) ~trace:sink
       ~trace_id:"trace-exec" ()
   with
   | Ok _ -> ()
   | Error _ -> incr failures);
  let names = List.map (fun (e : Webui_trace.event) -> e.name) (snapshot ()) in
  check "trace spawned" (List.mem "exec_spawn" names);
  check "trace exit" (List.mem "exec_exit" names);
  let sp =
    List.find_opt
      (fun (e : Webui_trace.event) -> e.name = "exec_spawn")
      (snapshot ())
  in
  check "trace id propagated"
    (match sp with Some e -> e.trace_id = "trace-exec" | None -> false)

let () =
  test_echo ();
  test_no_stdin_sends_eof ();
  test_timeout_kills ();
  test_timeout_partial ();
  test_cancel_kills ();
  test_stdin_blocked_times_out ();
  test_stderr_separation ();
  test_output_exceeded ();
  test_exit_code ();
  test_spawn_failed ();
  test_grandchild_pipe_hold ();
  test_trace ();
  if !failures = 0 then
    print_endline "exec_test: passed (echo eof timeout cancel stdin-sep flood exit spawn grandchild trace)"
  else begin
    Printf.printf "exec_test: %d failures\n" !failures;
    exit 1
  end
