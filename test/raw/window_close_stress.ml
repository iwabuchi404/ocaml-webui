open Webui_raw.Window

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let wait_for_running window =
  let deadline = Unix.gettimeofday () +. 5.0 in
  let rec loop () =
    match state window with
    | Running -> true
    | Created when Unix.gettimeofday () < deadline ->
        Thread.yield ();
        loop ()
    | _ -> false
  in
  loop ()

let run_iteration random iteration =
  let window = require (Webui_raw.Window.create { debug = false }) in
  require
    (Webui_raw.Window.set_html window
       "<!doctype html><title>close stress</title><h1>close stress</h1>");
  let executed = Atomic.make 0 in
  let rejected = Atomic.make 0 in
  let worker_error = Atomic.make None in
  let dispatcher_ready = Atomic.make false in
  let close_delay = 0.002 +. Random.State.float random 0.025 in
  let dispatch_delays =
    Array.init 40 (fun _ -> Random.State.float random 0.002)
  in

  let dispatcher =
    Thread.create
      (fun () ->
        try
          if not (wait_for_running window) then
            failwith "dispatcher did not observe Running";
          Atomic.set dispatcher_ready true;
          Array.iteri
            (fun index delay ->
              Unix.sleepf delay;
              match
                Webui_raw.Window.dispatch window (fun () ->
                    ignore (Atomic.fetch_and_add executed 1);
                    if index mod 7 = 0 then Unix.sleepf 0.001)
              with
              | Ok () -> ()
              | Error { code = Webui_raw.Error.Invalid_state; _ } ->
                  ignore (Atomic.fetch_and_add rejected 1)
              | Error error -> fail_error error)
            dispatch_delays
        with exn -> Atomic.set worker_error (Some exn))
      ()
  in
  let closer =
    Thread.create
      (fun () ->
        try
          if not (wait_for_running window) then
            failwith "closer did not observe Running";
          let deadline = Unix.gettimeofday () +. 5.0 in
          while
            (not (Atomic.get dispatcher_ready))
            && Unix.gettimeofday () < deadline
          do
            Thread.yield ()
          done;
          if not (Atomic.get dispatcher_ready) then
            failwith "dispatcher did not become ready";
          Unix.sleepf close_delay;
          require (Webui_raw.Window.request_close window)
        with exn -> Atomic.set worker_error (Some exn))
      ()
  in

  require (Webui_raw.Window.run window);
  Thread.join dispatcher;
  Thread.join closer;
  (match Atomic.get worker_error with None -> () | Some exn -> raise exn);
  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.dispatch_roots <> 0 then
    failwith "dispatch roots remained after close";
  if before_destroy.queued_dispatches <> 0 then
    failwith "dispatch queue remained after close";
  if
    before_destroy.dispatch_enqueued
    <> before_destroy.dispatch_executed + before_destroy.dispatch_cancelled
  then failwith "accepted dispatches were neither executed nor cancelled";
  if before_destroy.dispatch_executed <> Atomic.get executed then
    failwith "execution diagnostics did not match callbacks";
  require (Webui_raw.Window.destroy window);
  let after_destroy = Webui_raw.Diagnostics.snapshot window in
  if
    after_destroy.binding_roots <> 0 || after_destroy.dispatch_roots <> 0
    || after_destroy.pending_calls <> 0
  then failwith "roots remained after destroy";
  if iteration mod 10 = 0 then Gc.full_major ();
  ( before_destroy.dispatch_enqueued,
    before_destroy.dispatch_executed,
    before_destroy.dispatch_cancelled,
    Atomic.get rejected )

let run iterations seed =
  let random = Random.State.make [| seed |] in
  let enqueued = ref 0 in
  let executed = ref 0 in
  let cancelled = ref 0 in
  let rejected = ref 0 in
  for iteration = 1 to iterations do
    let a, b, c, d = run_iteration random iteration in
    enqueued := !enqueued + a;
    executed := !executed + b;
    cancelled := !cancelled + c;
    rejected := !rejected + d
  done;
  Printf.printf
    "window_close_stress: passed iterations=%d seed=%d enqueued=%d executed=%d cancelled=%d rejected=%d\n%!"
    iterations seed !enqueued !executed !cancelled !rejected

let () =
  let iterations = ref 20 in
  let seed = ref 0x5eed in
  let options =
    [
      ("--iterations", Arg.Set_int iterations, "number of create/close cycles");
      ("--seed", Arg.Set_int seed, "random seed");
    ]
  in
  Arg.parse options ignore "window_close_stress [options]";
  Printexc.record_backtrace true;
  try run !iterations !seed
  with exn ->
    Printf.eprintf "window_close_stress: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
