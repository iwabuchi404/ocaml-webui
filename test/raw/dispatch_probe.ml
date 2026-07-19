open Webui_raw.Window

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let wait_until ~timeout predicate =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if predicate () then true
    else if Unix.gettimeofday () >= deadline then false
    else (
      Unix.sleepf 0.01;
      loop ())
  in
  loop ()

let run () =
  let window = require (Webui_raw.Window.create { debug = true }) in
  require
    (Webui_raw.Window.set_html window
       "<!doctype html><title>dispatch probe</title><h1>dispatch probe</h1>");

  let callback_count = Atomic.make 0 in
  let blocker_started = Atomic.make false in
  let release_blocker = Atomic.make false in
  let cancelled_callback_count = Atomic.make 0 in
  let worker_error = Atomic.make None in
  let worker =
    Thread.create
      (fun () ->
        try
          if not (wait_until ~timeout:5.0 (fun () -> state window = Running))
          then failwith "window did not enter Running";
          for index = 1 to 100 do
            require
              (Webui_raw.Window.dispatch window (fun () ->
                   ignore (Atomic.fetch_and_add callback_count 1);
                   if index = 50 then failwith "intentional dispatch failure"))
          done;
          if
            not
              (wait_until ~timeout:5.0 (fun () ->
                   Atomic.get callback_count = 100))
          then failwith "not all dispatch callbacks executed";

          require
            (Webui_raw.Window.dispatch window (fun () ->
                 Atomic.set blocker_started true;
                 while not (Atomic.get release_blocker) do
                   Unix.sleepf 0.01
                 done));
          if
            not
              (wait_until ~timeout:5.0 (fun () ->
                   Atomic.get blocker_started))
          then failwith "blocking dispatch did not start";
          for _ = 1 to 25 do
            require
              (Webui_raw.Window.dispatch window (fun () ->
                   ignore (Atomic.fetch_and_add cancelled_callback_count 1)))
          done;
          require (Webui_raw.Window.request_close window);
          Atomic.set release_blocker true;
          (match Webui_raw.Window.dispatch window ignore with
          | Error { code = Webui_raw.Error.Invalid_state; _ } -> ()
          | Ok () -> failwith "dispatch unexpectedly succeeded while closing"
          | Error error -> fail_error error)
        with exn ->
          Atomic.set release_blocker true;
          Atomic.set worker_error (Some exn))
      ()
  in

  require (Webui_raw.Window.run window);
  Thread.join worker;
  (match Atomic.get worker_error with None -> () | Some exn -> raise exn);

  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.dispatch_roots <> 0 then
    failwith "dispatch roots remained after run";
  if before_destroy.queued_dispatches <> 0 then
    failwith "dispatch queue remained after run";
  if Atomic.get cancelled_callback_count <> 0 then
    failwith "a dispatch queued during close unexpectedly executed";
  if before_destroy.dispatch_enqueued <> 126 then
    failwith "unexpected dispatch enqueue count";
  if before_destroy.dispatch_executed <> 101 then
    failwith "unexpected dispatch execution count";
  if before_destroy.dispatch_cancelled <> 25 then
    failwith "unexpected dispatch cancellation count";
  if before_destroy.callback_exceptions <> 1 then
    failwith "callback exception was not recorded exactly once";

  require (Webui_raw.Window.destroy window);
  let after_destroy = Webui_raw.Diagnostics.snapshot window in
  if after_destroy.window_state <> Destroyed then
    failwith "window was not destroyed";
  if after_destroy.dispatch_roots <> 0 then
    failwith "dispatch roots remained after destroy";
  Printf.printf
    "dispatch_probe: passed enqueued=%d executed=%d cancelled=%d exceptions=%d\n%!"
    after_destroy.dispatch_enqueued after_destroy.dispatch_executed
    after_destroy.dispatch_cancelled after_destroy.callback_exceptions

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "dispatch_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
