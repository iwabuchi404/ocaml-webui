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

let run () =
  let window = require (Webui_raw.Window.create { debug = false }) in
  let captured_call = Atomic.make None in
  let close_outcome = Atomic.make None in
  ignore
    (require
       (Webui_raw.Binding.create window ~name:"hold" (fun call ->
            Atomic.set captured_call (Some call))));
  require
    (Webui_raw.Window.set_html window
       "<!doctype html><title>native close probe</title><script>window.hold()</script>");
  let closer =
    Thread.create
      (fun () ->
        try
          let registered =
            wait_until ~timeout:15.0 (fun () ->
                match Atomic.get captured_call with
                | Some _ -> true
                | None -> false)
          in
          if not registered then failwith "pending Call was not registered";
          require (Webui_raw.For_testing.Native_window.request_close window);
          Atomic.set close_outcome (Some (Ok ()))
        with exn ->
          Atomic.set close_outcome (Some (Error exn));
          ignore (Webui_raw.Window.request_close window))
      ()
  in
  require (Webui_raw.Window.run window);
  Thread.join closer;
  (match Atomic.get close_outcome with
  | Some (Ok ()) -> ()
  | Some (Error exn) -> raise exn
  | None -> failwith "native close Thread did not publish its outcome");
  if Webui_raw.Window.state window <> Stopped then
    failwith "native close did not stop the Window";
  (match Atomic.get captured_call with
  | Some call when Webui_raw.For_testing.call_state call = Cancelled -> ()
  | _ -> failwith "native close did not cancel the pending Call");
  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if
    before_destroy.pending_calls <> 0 || before_destroy.dispatch_roots <> 0
    || before_destroy.queued_dispatches <> 0
  then failwith "native close retained pending work";
  require (Webui_raw.Window.destroy window);
  let after_destroy = Webui_raw.Diagnostics.snapshot window in
  if
    after_destroy.binding_roots <> 0 || after_destroy.pending_calls <> 0
    || after_destroy.dispatch_roots <> 0
  then failwith "native close retained roots after destroy";
  Printf.printf "native_close_probe: passed native_close pending_cancel roots=0\n%!"

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "native_close_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
