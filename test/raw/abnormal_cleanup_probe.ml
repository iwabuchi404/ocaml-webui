open Webui_raw.Window

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let wait_until ~timeout predicate =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if predicate () then true
    else if Unix.gettimeofday () >= deadline then false
    else (
      Unix.sleepf 0.005;
      loop ())
  in
  loop ()

let expect_unspecified operation = function
  | Error { Webui_raw.Error.operation = actual; code = Unspecified; _ }
    when actual = operation ->
      ()
  | Error error -> fail_error error
  | Ok () -> failwith "injected native operation unexpectedly succeeded"

let expect_zero_work window stage =
  let snapshot = Webui_raw.Diagnostics.snapshot window in
  if
    snapshot.pending_calls <> 0 || snapshot.dispatch_roots <> 0
    || snapshot.queued_dispatches <> 0
  then failwith (stage ^ " retained Call or dispatch work")
  else if snapshot.callback_exceptions <> 0 then
    failwith (stage ^ " unexpectedly recorded a callback exception")

let protect_thread window outcome callback =
  try
    callback ();
    Atomic.set outcome (Some (Ok ()))
  with exn ->
    Atomic.set outcome (Some (Error exn));
    ignore (Webui_raw.Window.request_close window)

let join_thread thread outcome =
  Thread.join thread;
  match Atomic.get outcome with
  | Some (Ok ()) -> ()
  | Some (Error exn) -> raise exn
  | None -> failwith "worker Thread did not publish its outcome"

let expect_destroyed_without_roots window stage =
  let snapshot = Webui_raw.Diagnostics.snapshot window in
  if snapshot.window_state <> Destroyed then
    failwith (stage ^ " did not destroy its Window");
  if
    snapshot.binding_roots <> 0 || snapshot.pending_calls <> 0
    || snapshot.dispatch_roots <> 0 || snapshot.queued_dispatches <> 0
  then failwith (stage ^ " retained roots after destroy")

let test_abnormal_run () =
  let window = require (Webui_raw.Window.create { debug = false }) in
  ignore
    (require
       (Webui_raw.Binding.create window ~name:"unused" (fun call ->
            ignore (Webui_raw.Call.cancel call))));
  Webui_raw.For_testing.fail_next_run window;
  expect_unspecified Webui_raw.Error.Run (Webui_raw.Window.run window);
  if Webui_raw.Window.state window <> Stopped then
    failwith "abnormal run did not transition to Stopped";
  expect_zero_work window "abnormal run";
  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.binding_roots <> 1 then
    failwith "abnormal run lost its binding root before destroy";
  require (Webui_raw.Window.destroy window);
  expect_destroyed_without_roots window "abnormal run"

let test_response_failure () =
  let window = require (Webui_raw.Window.create { debug = false }) in
  let captured_call = Atomic.make None in
  let first_completion = Atomic.make None in
  let duplicate_completion = Atomic.make None in
  let closer_outcome = Atomic.make None in
  ignore
    (require
       (Webui_raw.Binding.create window ~name:"fail_response" (fun call ->
            Atomic.set captured_call (Some call);
            Webui_raw.For_testing.fail_next_response window;
            Atomic.set first_completion
              (Some (Webui_raw.Call.resolve_json call "null"));
            Atomic.set duplicate_completion
              (Some (Webui_raw.Call.reject_json call "null")))));
  require
    (Webui_raw.Window.set_html window
       "<!doctype html><script>window.fail_response().catch(() => {})</script>");
  let closer =
    Thread.create
      (fun () ->
        protect_thread window closer_outcome (fun () ->
            let response_finished =
              wait_until ~timeout:15.0 (fun () ->
                  match Atomic.get captured_call with
                  | Some call ->
                      Webui_raw.For_testing.call_state call = Failed
                      &&
                      (Webui_raw.Diagnostics.snapshot window).pending_calls = 0
                  | None -> false)
            in
            if response_finished then
              require (Webui_raw.Window.request_close window)
            else failwith "native response failure did not finish its Call"))
      ()
  in
  require (Webui_raw.Window.run window);
  join_thread closer closer_outcome;
  (match Atomic.get first_completion with
  | Some `Queued -> ()
  | _ -> failwith "response failure was not accepted into dispatch");
  (match Atomic.get duplicate_completion with
  | Some `Already_completed -> ()
  | _ -> failwith "duplicate response after native failure was not rejected");
  (match Atomic.get captured_call with
  | Some call when Webui_raw.For_testing.call_state call = Failed -> ()
  | _ -> failwith "native response failure did not leave Call in Failed");
  expect_zero_work window "native response failure";
  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.response_failures <> 1 then
    failwith "native response failure was not recorded exactly once";
  require (Webui_raw.Window.destroy window);
  expect_destroyed_without_roots window "native response failure"

let test_close_dispatch_failure () =
  let window = require (Webui_raw.Window.create { debug = false }) in
  let captured_call = Atomic.make None in
  let first_close = Atomic.make None in
  let state_after_failure = Atomic.make None in
  let call_state_after_failure = Atomic.make None in
  let pending_after_failure = Atomic.make None in
  let queued_after_failure = Atomic.make None in
  let cancelled_before_failure = Atomic.make None in
  let cancelled_after_failure = Atomic.make None in
  let blocker_started = Atomic.make false in
  let release_blocker = Atomic.make false in
  let preserved_dispatch_executed = Atomic.make false in
  let closer_outcome = Atomic.make None in
  ignore
    (require
       (Webui_raw.Binding.create window ~name:"hold" (fun call ->
            Atomic.set captured_call (Some call))));
  require
    (Webui_raw.Window.set_html window
       "<!doctype html><script>window.hold().catch(() => {})</script>");
  let closer =
    Thread.create
      (fun () ->
        protect_thread window closer_outcome (fun () ->
            let call_registered =
              wait_until ~timeout:15.0 (fun () ->
                  match Atomic.get captured_call with
                  | Some _ -> true
                  | None -> false)
            in
            if not call_registered then
              failwith "pending Call was not registered";
            Fun.protect
              ~finally:(fun () -> Atomic.set release_blocker true)
              (fun () ->
                require
                  (Webui_raw.Window.dispatch window (fun () ->
                       Atomic.set blocker_started true;
                       while not (Atomic.get release_blocker) do
                         Unix.sleepf 0.002
                       done));
                if
                  not
                    (wait_until ~timeout:10.0 (fun () ->
                         Atomic.get blocker_started))
                then failwith "dispatch blocker did not start";
                require
                  (Webui_raw.Window.dispatch window (fun () ->
                       Atomic.set preserved_dispatch_executed true));
                Atomic.set cancelled_before_failure
                  (Some
                     (Webui_raw.Diagnostics.snapshot window)
                       .dispatch_cancelled);
                Webui_raw.For_testing.fail_next_close_dispatch window;
                Atomic.set first_close
                  (Some (Webui_raw.Window.request_close window));
                Atomic.set state_after_failure
                  (Some (Webui_raw.Window.state window));
                (match Atomic.get captured_call with
                | Some call ->
                    Atomic.set call_state_after_failure
                      (Some (Webui_raw.For_testing.call_state call))
                | None ->
                    failwith "pending Call disappeared during close failure");
                let snapshot = Webui_raw.Diagnostics.snapshot window in
                Atomic.set pending_after_failure (Some snapshot.pending_calls);
                Atomic.set queued_after_failure
                  (Some snapshot.queued_dispatches);
                Atomic.set cancelled_after_failure
                  (Some snapshot.dispatch_cancelled));
            if
              not
                (wait_until ~timeout:10.0 (fun () ->
                     Atomic.get preserved_dispatch_executed))
            then failwith "failed close did not preserve its queued dispatch";
            require (Webui_raw.Window.request_close window)))
      ()
  in
  require (Webui_raw.Window.run window);
  join_thread closer closer_outcome;
  (match Atomic.get first_close with
  | Some result -> expect_unspecified Webui_raw.Error.Request_close result
  | None -> failwith "first close did not publish its result");
  (match Atomic.get state_after_failure with
  | Some Running -> ()
  | _ -> failwith "failed close did not roll back to Running");
  (match Atomic.get call_state_after_failure with
  | Some Pending -> ()
  | _ -> failwith "failed close did not preserve its pending Call state");
  (match Atomic.get pending_after_failure with
  | Some 1 -> ()
  | _ -> failwith "failed close did not preserve its native pending Call");
  (match Atomic.get queued_after_failure with
  | Some 1 -> ()
  | _ -> failwith "failed close did not preserve its native dispatch queue");
  if Atomic.get cancelled_after_failure <> Atomic.get cancelled_before_failure
  then failwith "failed close changed dispatch cancellation diagnostics";
  if not (Atomic.get preserved_dispatch_executed) then
    failwith "preserved dispatch did not execute after close rollback";
  (match Atomic.get captured_call with
  | Some call when Webui_raw.For_testing.call_state call = Cancelled ->
      if Webui_raw.Call.resolve_json call "null" <> `Already_completed then
        failwith "cancelled Call accepted a late response"
  | _ -> failwith "failed close did not cancel its pending Call");
  expect_zero_work window "close dispatch failure";
  require (Webui_raw.Window.destroy window);
  expect_destroyed_without_roots window "close dispatch failure"

let run () =
  test_abnormal_run ();
  test_response_failure ();
  test_close_dispatch_failure ();
  Printf.printf
    "abnormal_cleanup_probe: passed run_failure response_failure close_failure\n%!"

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "abnormal_cleanup_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
