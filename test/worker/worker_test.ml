module W = Webui_worker

let echo_argv =
  [ Filename.concat (Filename.dirname Sys.argv.(0)) "echo_worker.exe" ]

let failures = ref 0

let check name cond =
  if cond then Printf.printf "  %s: ok\n" name
  else begin
    incr failures;
    Printf.printf "  %s: FAIL\n" name
  end

let rec wait_until ~ms cond =
  if cond () then true
  else if ms <= 0 then false
  else begin
    Unix.sleepf 0.02;
    wait_until ~ms:(ms - 20) cond
  end

let expect_ok name =
  match W.spawn ~name ~argv:echo_argv () with
  | Ok w -> w
  | Error e ->
      incr failures;
      Printf.printf "  spawn %s: FAIL (%s)\n" name
        (match e with W.Spawn_failed m -> m | _ -> "?");
      failwith "spawn failed"

(* -- scenario tests ---------------------------------------------------- *)

let test_echo () =
  let w = expect_ok "echo" in
  (match W.request w ~method_:"echo" (`Assoc [ ("a", `Int 1) ]) with
   | Ok (`Assoc [ ("a", `Int 1) ]) -> check "echo result" true
   | Ok j ->
       check "echo result" false;
       Printf.printf "    unexpected %s\n" (Yojson.Safe.to_string j)
   | Error _ -> check "echo result" false);
  check "is_alive" (W.is_alive w);
  W.kill w;
  check "status killed" (W.status w = W.Killed)

let test_remote_error () =
  let w = expect_ok "remote-error" in
  let r =
    match W.request w ~method_:"nope" `Null with
    | Error (W.Remote_error (`Assoc f)) -> (
        match List.assoc_opt "code" f with
        | Some (`Int (-32601)) -> true
        | _ -> false)
    | _ -> false
  in
  check "remote error" r;
  W.kill w

let test_timeout_worker_survives () =
  let w = expect_ok "timeout" in
  let r1 =
    W.request w ~timeout_ms:150 ~method_:"sleep"
      (`Assoc [ ("ms", `Int 2000) ])
  in
  check "timeout error" (r1 = Error W.Timeout);
  check "still alive" (W.is_alive w);
  (* late response is discarded; a fresh request still works *)
  let r2 = W.request w ~method_:"echo" `Null in
  check "post-timeout echo" (match r2 with Ok _ -> true | Error _ -> false);
  W.kill w

let test_kill_fails_inflight () =
  let w = expect_ok "kill-inflight" in
  let done_ = ref false in
  let res = ref (Ok `Null) in
  let (_ : unit Domain.t) =
    Domain.spawn (fun () ->
        res :=
          W.request w ~method_:"sleep"
            (`Assoc [ ("ms", `Int 30000) ]);
        done_ := true)
  in
  Unix.sleepf 0.2;
  W.kill w;
  check "inflight completed" (wait_until ~ms:3000 (fun () -> !done_));
  check "inflight failed"
    (match !res with
     | Error W.Worker_killed | Error W.Worker_exited -> true
     | _ -> false);
  check "not alive" (not (W.is_alive w));
  check "status killed" (W.status w = W.Killed)

let test_crash_restart () =
  let w =
    match W.spawn ~name:"restart" ~argv:echo_argv ~restart:(W.On_crash 2) () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  let r = W.request w ~method_:"die" `Null in
  check "die request failed"
    (match r with Error W.Worker_exited -> true | _ -> false);
  check "restart happened" (wait_until ~ms:5000 (fun () -> W.is_alive w));
  check "restart_count 1" (W.restart_count w = 1);
  let r2 = W.request w ~method_:"echo" `Null in
  check "post-restart echo" (match r2 with Ok _ -> true | Error _ -> false);
  W.kill w

let test_restart_limit () =
  let w =
    match W.spawn ~name:"limit" ~argv:echo_argv ~restart:(W.On_crash 1) () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  ignore (W.request w ~method_:"die" `Null);
  check "first restart" (wait_until ~ms:5000 (fun () -> W.is_alive w));
  ignore (W.request w ~method_:"die" `Null);
  check "dead after limit" (wait_until ~ms:5000 (fun () -> W.status w = W.Dead));
  let r = W.request w ~method_:"echo" `Null in
  check "request to dead" (r = Error W.Worker_dead)

let test_notification () =
  let got = ref [] in
  let w =
    match
      W.spawn ~name:"notify" ~argv:echo_argv
        ~on_notification:(fun j -> got := j :: !got)
        ()
    with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  ignore (W.request w ~method_:"spam" `Null);
  let ok =
    wait_until ~ms:1000 (fun () -> !got <> [])
    && List.exists
         (fun j ->
           match j with
           | `Assoc f -> List.assoc_opt "method" f = Some (`String "tick")
           | _ -> false)
         !got
  in
  check "notification delivered" ok;
  W.kill w

let test_shutdown_all () =
  let w1 = expect_ok "sa1" in
  let w2 = expect_ok "sa2" in
  W.shutdown_all ();
  check "shutdown_all w1" (W.status w1 = W.Killed);
  check "shutdown_all w2" (W.status w2 = W.Killed)

let test_trace () =
  let sink, snapshot = Webui_trace.ring_buffer ~capacity:128 in
  let w =
    match W.spawn ~name:"traced" ~argv:echo_argv ~trace:sink () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  ignore
    (W.request w ~trace_id:"trace-abc" ~method_:"echo" `Null);
  W.kill w;
  let events = snapshot () in
  let names = List.map (fun (e : Webui_trace.event) -> e.name) events in
  check "trace spawned" (List.mem "worker_spawned" names);
  check "trace request" (List.mem "worker_request" names);
  check "trace response" (List.mem "worker_response" names);
  check "trace killed" (List.mem "worker_killed" names);
  let req =
    List.find_opt (fun (e : Webui_trace.event) -> e.name = "worker_request")
      events
  in
  check "trace id propagated"
    (match req with Some e -> e.trace_id = "trace-abc" | None -> false)

let () =
  test_echo ();
  test_remote_error ();
  test_timeout_worker_survives ();
  test_kill_fails_inflight ();
  test_crash_restart ();
  test_restart_limit ();
  test_notification ();
  test_shutdown_all ();
  test_trace ();
  if !failures = 0 then
    print_endline "worker_test: passed (echo timeout kill restart limit notify shutdown trace)"
  else begin
    Printf.printf "worker_test: %d failures\n" !failures;
    exit 1
  end
