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

let test_token_cancel () =
  let sink, snapshot = Webui_trace.ring_buffer ~capacity:64 in
  let w =
    match W.spawn ~name:"tokcancel" ~argv:echo_argv ~trace:sink () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  let token = Webui_async.token () in
  let done_ = ref false in
  let res = ref (Ok `Null) in
  let (_ : unit Domain.t) =
    Domain.spawn (fun () ->
        res :=
          W.request w ~token ~method_:"sleep"
            (`Assoc [ ("ms", `Int 500) ]);
        done_ := true)
  in
  Unix.sleepf 0.1;
  Webui_async.cancel token `Js_cancel;
  check "cancel completed" (wait_until ~ms:2000 (fun () -> !done_));
  check "cancel error" (!res = Error W.Cancelled);
  check "worker survives cancel" (W.is_alive w);
  (* the worker finishes the abandoned request; the late response is
     discarded instead of being delivered *)
  check "late response discarded"
    (wait_until ~ms:2000 (fun () ->
         List.exists
           (fun (e : Webui_trace.event) ->
             e.Webui_trace.name = "worker_late_response")
           (snapshot ())));
  check "cancel event emitted"
    (List.exists
       (fun (e : Webui_trace.event) ->
         e.Webui_trace.name = "worker_request_cancelled")
       (snapshot ()));
  let r2 = W.request w ~method_:"echo" `Null in
  check "post-cancel echo" (match r2 with Ok _ -> true | Error _ -> false);
  W.kill w

let test_concurrent_sends () =
  (* NDJSON integrity: concurrent requesters must not interleave bytes
     on the wire — the writer domain serialises whole frames. *)
  let w = expect_ok "concurrent" in
  let ok = Atomic.make 0 in
  let domains =
    List.init 8 (fun i ->
        Domain.spawn (fun () ->
            for j = 1 to 20 do
              let payload =
                `Assoc
                  [
                    ("i", `Int i);
                    ("j", `Int j);
                    ("pad", `String (String.make 4096 'x'));
                  ]
              in
              match W.request w ~method_:"echo" payload with
              | Ok _ -> Atomic.incr ok
              | Error _ -> ()
            done))
  in
  List.iter Domain.join domains;
  check "concurrent sends all ok" (Atomic.get ok = 160);
  W.kill w

let test_queued_request_times_out () =
  (* A request stuck in the send queue behind a blocked write must still
     observe its timeout: the writer owns the wire, the requester only
     waits on its pending entry. *)
  let w = expect_ok "sendqueue" in
  let a =
    Domain.spawn (fun () ->
        W.request w ~method_:"sleep" (`Assoc [ ("ms", `Int 2000) ]))
  in
  (* Give the sleep frame time to reach the worker so it stops reading
     stdin before the flood below is queued. *)
  Unix.sleepf 0.1;
  let big = `Assoc [ ("pad", `String (String.make (1024 * 1024) 'x')) ] in
  let d =
    Domain.spawn (fun () ->
        W.request w ~method_:"echo" ~timeout_ms:100 big)
  in
  let t0 = Unix.gettimeofday () in
  let r = Domain.join d in
  let elapsed = Unix.gettimeofday () -. t0 in
  check "queued request timed out" (r = Error W.Timeout);
  check "timeout was prompt" (elapsed < 1.0);
  ignore (Domain.join a);
  W.kill w

let test_dead_worker_invariants () =
  (* After a natural exit the proc reference must be cleared: [pid] is
     None, [is_alive] false, and [kill] must not flip Dead to Killed or
     attempt terminate on an exited process. *)
  let w = expect_ok "deadstate" in
  ignore (W.request w ~method_:"die" `Null);
  check "worker dead" (wait_until ~ms:3000 (fun () -> W.status w = W.Dead));
  check "pid cleared" (W.pid w = None);
  check "not alive" (not (W.is_alive w));
  W.kill w;
  check "kill leaves Dead" (W.status w = W.Dead)

let test_timed_out_frames_released () =
  (* Regression: a timed-out request must release its queued frame
     payload. With a worker that never reads stdin the writer stays
     blocked on the first frame; without the shared [frame] ref the
     remaining ~59 MB stayed reachable after GC. *)
  let w =
    match W.spawn ~name:"noread" ~argv:(echo_argv @ [ "--noread" ]) () with
    | Ok w -> w
    | Error _ ->
        incr failures;
        failwith "spawn failed"
  in
  let big () = `Assoc [ ("pad", `String (String.make (1024 * 1024) 'x')) ] in
  Gc.compact ();
  let before = (Gc.stat ()).Gc.live_words in
  let timeouts = ref 0 in
  let other = ref None in
  for _ = 1 to 60 do
    match W.request w ~method_:"echo" ~timeout_ms:50 (big ()) with
    | Error W.Timeout -> incr timeouts
    | r -> other := Some r
  done;
  (match !other with
   | Some (Ok _) -> print_endline "  non-timeout result: ok"
   | Some (Error e) ->
       Printf.printf "  non-timeout error constructor index: %d\n"
         (match e with
          | W.Spawn_failed _ -> 0
          | W.Worker_exited -> 1
          | W.Worker_killed -> 2
          | W.Worker_dead -> 3
          | W.Timeout -> 4
          | W.Cancelled -> 5
          | W.Remote_error _ -> 6
          | W.Protocol_error _ -> 7)
   | None -> ());
  Gc.compact ();
  let grown = (Gc.stat ()).Gc.live_words - before in
  check "all requests timed out" (!timeouts = 60);
  check "pending drained" (W.pending_count w = 0);
  check "queued payloads released" (grown < 1024 * 1024);
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
  test_token_cancel ();
  test_concurrent_sends ();
  test_queued_request_times_out ();
  test_dead_worker_invariants ();
  test_timed_out_frames_released ();
  test_shutdown_all ();
  test_trace ();
  if !failures = 0 then
    print_endline "worker_test: passed (echo timeout kill restart limit notify cancel queue deadstate gc trace)"
  else begin
    Printf.printf "worker_test: %d failures\n" !failures;
    exit 1
  end
