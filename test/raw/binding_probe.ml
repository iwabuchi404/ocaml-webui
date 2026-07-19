open Webui_raw.Window

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let trace message =
  if Sys.getenv_opt "WEBUI_RAW_TRACE" = Some "1" then
    Printf.printf "stage=%s\n%!" message

let run () =
  trace "create_start";
  let window = require (Webui_raw.Window.create { debug = true }) in
  trace "create_done";
  let workers_mutex = Mutex.create () in
  let workers = ref [] in
  let add_worker worker =
    Mutex.lock workers_mutex;
    workers := worker :: !workers;
    Mutex.unlock workers_mutex
  in
  let echo_first = Atomic.make None in
  let echo_second = Atomic.make None in
  let slow_completion = Atomic.make None in
  let report_request = Atomic.make None in
  let self_removed = Atomic.make false in
  let pending_remove_rejected = Atomic.make false in
  let fault_completion = Atomic.make None in
  let finished = Atomic.make false in

  let temporary =
    require
      (Webui_raw.Binding.create window ~name:"temporary" (fun call ->
           ignore (Webui_raw.Call.resolve_json call "null")))
  in
  require (Webui_raw.Binding.remove temporary);
  require (Webui_raw.Binding.remove temporary);
  trace "temporary_removed";

  let self_binding = ref None in
  let self_remove =
    require
      (Webui_raw.Binding.create window ~name:"self_remove" (fun call ->
           trace "self_remove_handler";
           let binding = Option.get !self_binding in
           (match Webui_raw.Binding.remove binding with
           | Error { code = Webui_raw.Error.Invalid_state; _ } -> ()
           | Ok () -> failwith "active binding unexpectedly removed reentrantly"
           | Error error -> fail_error error);
           require
             (Webui_raw.Window.dispatch window (fun () ->
                  match Webui_raw.Binding.remove binding with
                  | Error { code = Webui_raw.Error.Invalid_state; _ } ->
                      Atomic.set pending_remove_rejected true
                  | Ok () ->
                      failwith "binding with a pending Call was removed"
                  | Error error -> fail_error error));
           trace "self_remove_resolve_start";
           ignore (Webui_raw.Call.resolve_json call "null");
           trace "self_remove_resolve_done";
           require
             (Webui_raw.Window.dispatch window (fun () ->
                  require (Webui_raw.Binding.remove binding);
                  Atomic.set self_removed true));
           trace "self_remove_dispatch_done"))
  in
  self_binding := Some self_remove;

  let echo =
    require
      (Webui_raw.Binding.create window ~name:"echo" (fun call ->
           trace "echo_handler";
           add_worker
             (Domain.spawn (fun () ->
                  Unix.sleepf 0.05;
                  trace "echo_domain_respond_start";
                  Atomic.set echo_first
                    (Some (Webui_raw.Call.resolve_json call "\"ok\""));
                  Atomic.set echo_second
                    (Some (Webui_raw.Call.resolve_json call "\"duplicate\""));
                  trace "echo_domain_respond_done"))))
  in
  let slow =
    require
      (Webui_raw.Binding.create window ~name:"slow" (fun call ->
           trace "slow_handler";
           add_worker
             (Domain.spawn (fun () ->
                  Unix.sleepf 0.75;
                  Atomic.set slow_completion
                    (Some (Webui_raw.Call.resolve_json call "\"too late\""))))))
  in
  let boom =
    require
      (Webui_raw.Binding.create window ~name:"boom" (fun _ ->
           trace "boom_handler";
           failwith "intentional binding handler failure"))
  in
  let fault =
    require
      (Webui_raw.Binding.create window ~name:"fault" (fun call ->
           trace "fault_handler";
           Webui_raw.For_testing.fail_next_dispatch window;
           Atomic.set fault_completion
             (Some (Webui_raw.Call.resolve_json call "null"))))
  in
  let report =
    require
      (Webui_raw.Binding.create window ~name:"report" (fun call ->
           trace "report_handler";
           Atomic.set report_request (Some (Webui_raw.Call.request_json call));
           ignore (Webui_raw.Call.resolve_json call "null");
           Atomic.set finished true;
           require (Webui_raw.Window.request_close window)))
  in
  trace "bindings_ready";

  require
    (Webui_raw.Window.set_html window
       {html|<!doctype html>
<html><head><meta charset="utf-8"><title>binding probe</title></head>
<body><h1>binding probe</h1><script>
window.fault().catch(() => {});
Promise.all([
  window.echo({value: 42}),
  window.slow(),
  window.self_remove()
]).catch(() => {});
window.echo({value: 7})
  .then(value => window.boom(value))
  .then(() => window.report("boom unexpectedly resolved"))
  .catch(() => window.report("ok"));
</script></body></html>|html});
  trace "html_ready";

  let watchdog =
    Thread.create
      (fun () ->
        let deadline = Unix.gettimeofday () +. 8.0 in
        while
          (not (Atomic.get finished)) && Unix.gettimeofday () < deadline
        do
          Unix.sleepf 0.05
        done;
        if not (Atomic.get finished) then
          (trace "watchdog_close";
           ignore (Webui_raw.Window.request_close window)))
      ()
  in
  trace "run_start";
  require (Webui_raw.Window.run window);
  trace "run_done";
  Thread.join watchdog;

  Mutex.lock workers_mutex;
  let spawned = !workers in
  Mutex.unlock workers_mutex;
  List.iter Domain.join spawned;

  if not (Atomic.get finished) then failwith "renderer did not report success";
  if not (Atomic.get self_removed) then
    failwith "binding did not remove itself from its callback";
  if not (Atomic.get pending_remove_rejected) then
    failwith "binding removal did not reject its pending Call";
  (match Atomic.get report_request with
  | Some "[\"ok\"]" -> ()
  | Some request -> failwith ("unexpected report request: " ^ request)
  | None -> failwith "report binding was not called");
  (match Atomic.get echo_first with
  | Some `Sent -> ()
  | _ -> failwith "first echo response was not accepted");
  (match Atomic.get echo_second with
  | Some `Already_completed -> ()
  | _ -> failwith "duplicate echo response was not rejected");
  (match Atomic.get slow_completion with
  | Some `Already_completed -> ()
  | _ -> failwith "slow response was not cancelled during close");
  (match Atomic.get fault_completion with
  | Some `Window_closing -> ()
  | _ -> failwith "dispatch enqueue failure did not roll back the Call");

  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.pending_calls <> 0 then
    failwith "pending calls remained after run";
  if before_destroy.dispatch_roots <> 0 then
    failwith "dispatch roots remained after run";
  if before_destroy.callback_exceptions <> 1 then
    failwith "binding exception was not recorded exactly once";
  if before_destroy.binding_roots <> 5 then
    failwith "unexpected active binding root count";

  require (Webui_raw.Window.destroy window);
  let after_destroy = Webui_raw.Diagnostics.snapshot window in
  if after_destroy.binding_roots <> 0 || after_destroy.pending_calls <> 0 then
    failwith "binding or call roots remained after destroy";
  List.iter
    (fun binding -> require (Webui_raw.Binding.remove binding))
    [ self_remove; echo; slow; boom; fault; report ];
  Printf.printf
    "binding_probe: passed bindings=%d pending=%d dispatch_roots=%d exceptions=%d\n%!"
    after_destroy.binding_roots after_destroy.pending_calls
    after_destroy.dispatch_roots after_destroy.callback_exceptions

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "binding_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
