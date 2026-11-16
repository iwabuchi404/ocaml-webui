module R = Webui_resource
module W = Webui_worker

let echo_argv =
  [
    Filename.concat (Filename.dirname Sys.argv.(0))
      "../worker/echo_worker.exe";
  ]

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

let cleanup () = ignore (R.revoke_scope R.App)

let test_register_release () =
  cleanup ();
  let base = R.leak_count () in
  let ran = ref 0 in
  let r =
    R.register ~kind:"test" ~name:"r1" ~release:(fun () -> incr ran) ()
  in
  check "leak_count +1" (R.leak_count () = base + 1);
  check "snapshot has entry"
    (List.exists
       (fun (i : R.info) -> i.kind = "test" && i.name = "r1")
       (R.snapshot ()));
  R.release r;
  check "release ran once" (!ran = 1);
  check "leak_count back" (R.leak_count () = base);
  R.release r;
  check "release idempotent" (!ran = 1)

let test_revoke_named () =
  cleanup ();
  let order = ref [] in
  let mk n =
    ignore
      (R.register ~kind:"test" ~name:n ~scope:(R.Named "group")
         ~release:(fun () -> order := n :: !order)
         ())
  in
  mk "a";
  mk "b";
  mk "c";
  ignore
    (R.register ~kind:"test" ~name:"other" ~scope:(R.Named "other-group")
       ~release:(fun () -> order := "other" :: !order)
       ());
  let n = R.revoke_scope (R.Named "group") in
  check "revoke count" (n = 3);
  (* releases push onto the front: c released first leaves [a;b;c] *)
  check "reverse registration order" (!order = [ "a"; "b"; "c" ]);
  check "other scope untouched"
    (List.exists
       (fun (i : R.info) -> i.name = "other")
       (R.snapshot ()));
  ignore (R.revoke_scope (R.Named "other-group"));
  check "revoke again zero" (R.revoke_scope (R.Named "group") = 0)

let test_revoke_app () =
  cleanup ();
  let ran = ref false in
  ignore
    (R.register ~kind:"test" ~name:"appres"
       ~release:(fun () -> ran := true)
       ());
  let n = R.revoke_scope R.App in
  check "app revoke count" (n = 1);
  check "app release ran" !ran

let test_trace_events () =
  cleanup ();
  let sink, to_list = Webui_trace.ring_buffer ~capacity:32 in
  R.set_trace (Some sink);
  let r =
    R.register ~kind:"t" ~name:"tr" ~release:(fun () -> ()) ()
  in
  R.release r;
  R.set_trace None;
  let names =
    List.map (fun (e : Webui_trace.event) -> e.name) (to_list ())
  in
  check "registered event" (List.mem "resource_registered" names);
  check "released event" (List.mem "resource_released" names)

let test_worker_auto_register () =
  cleanup ();
  let w =
    match
      W.spawn ~name:"scoped" ~argv:echo_argv ~scope:(R.Named "wgroup") ()
    with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  check "worker in snapshot"
    (List.exists
       (fun (i : R.info) -> i.kind = "worker" && i.name = "scoped")
       (R.snapshot ()));
  let n = R.revoke_scope (R.Named "wgroup") in
  check "revoke kills worker" (n = 1 && not (W.is_alive w));
  check "status killed" (W.status w = W.Killed)

let test_worker_kill_releases () =
  cleanup ();
  let base = R.leak_count () in
  let w =
    match W.spawn ~name:"killed" ~argv:echo_argv () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  check "registered" (R.leak_count () = base + 1);
  W.kill w;
  check "kill releases resource" (R.leak_count () = base)

let test_worker_death_releases () =
  cleanup ();
  let base = R.leak_count () in
  let w =
    match W.spawn ~name:"dying" ~argv:echo_argv () with
    | Ok w -> w
    | Error _ -> incr failures; failwith "spawn failed"
  in
  ignore (W.request w ~method_:"die" `Null);
  let dead =
    wait_until ~ms:3000 (fun () -> W.status w = W.Dead)
  in
  check "worker dead" dead;
  check "death releases resource"
    (wait_until ~ms:1000 (fun () -> R.leak_count () = base))

let () =
  Printf.printf "resource_test\n";
  test_register_release ();
  test_revoke_named ();
  test_revoke_app ();
  test_trace_events ();
  test_worker_auto_register ();
  test_worker_kill_releases ();
  test_worker_death_releases ();
  cleanup ();
  W.shutdown_all ();
  if !failures > 0 then begin
    Printf.printf "resource_test: %d FAILURES\n" !failures;
    exit 1
  end
  else Printf.printf "resource_test: all checks passed\n"
