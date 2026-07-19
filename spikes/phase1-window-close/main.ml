module Webview = struct
  let fail_error error = failwith (Webui_raw.Error.to_string error)
  let require = function Ok value -> value | Error error -> fail_error error
  let create debug = require (Webui_raw.Window.create { debug })
  let destroy window = require (Webui_raw.Window.destroy window)
  let run window = require (Webui_raw.Window.run window)
  let set_title window title = require (Webui_raw.Window.set_title window title)

  let set_size window width height _hint =
    require (Webui_raw.Window.set_size window ~width ~height Initial)

  let set_html window html = require (Webui_raw.Window.set_html window html)

  let bind window name handler =
    ignore
      (require
         (Webui_raw.Binding.create window ~name (fun call ->
              handler call (Webui_raw.Call.request_json call))))

  let dispatch window callback =
    require (Webui_raw.Window.dispatch window (fun () -> callback window))

  let return _window call status payload =
    let submission =
      if status = 0 then Webui_raw.Call.resolve_json call payload
      else Webui_raw.Call.reject_json call payload
    in
    match submission with
    | `Queued | `Already_completed -> ()
    | `Window_closing -> failwith "response rejected while Window is closing"
    | `Enqueue_failed error -> fail_error error

  let post_window_close = Webui_raw.For_testing.Win32.post_wm_close
  let diagnostics = Webui_raw.Diagnostics.snapshot
end

let current_thread_id = Webui_raw.For_testing.Win32.current_thread_id
type lifecycle = Running | Closing | Destroyed

let string_of_lifecycle = function
  | Running -> "running"
  | Closing -> "closing"
  | Destroyed -> "destroyed"

let started_at = Unix.gettimeofday ()
let log_mutex = Mutex.create ()
let lifecycle = Atomic.make Running
let work_started = Atomic.make false
let work_cancelled = Atomic.make false
let domain_handle : unit Domain.t option ref = ref None
let close_thread : Thread.t option ref = ref None

let elapsed_ms () = (Unix.gettimeofday () -. started_at) *. 1_000.

let log event fields =
  Mutex.protect log_mutex (fun () ->
      Printf.printf
        "{\"at_ms\":%.3f,\"event\":\"%s\",\"thread_id\":%d%s}\n%!"
        (elapsed_ms ()) event (current_thread_id ()) fields)

let root_fields webview =
  let snapshot = Webview.diagnostics webview in
  Printf.sprintf ",\"binding_roots\":%d,\"dispatch_roots\":%d"
    snapshot.binding_roots snapshot.dispatch_roots

let html =
  {html|<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Phase 1 pending close probe</title>
  <style>
    :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center;
      background: #0b1020; color: #e8ecf6; }
    main { width: min(680px, calc(100% - 40px)); padding: 28px; border-radius: 16px;
      border: 1px solid #35405f; background: #151c31; }
    h1 { margin-top: 0; font-size: 24px; }
    p { color: #b7c1d9; line-height: 1.6; }
    .spinner { width: 72px; height: 72px; margin: 24px auto; border-radius: 50%;
      border: 9px solid #2a3451; border-top-color: #ed8f84; animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    button { display: block; margin: 0 auto; border: 0; border-radius: 10px;
      padding: 11px 16px; background: #ed8f84; color: #260b08; font-weight: 700; }
    #status { font-family: ui-monospace, monospace; color: #f1c779; text-align: center; }
  </style>
</head>
<body>
<main>
  <h1>Pending callback → native window close</h1>
  <p>A three-second Domain task starts, then the native window receives
    <code>WM_CLOSE</code> after 500 ms. Native logs verify cancellation, join,
    destruction order, and FFI root counts.</p>
  <div class="spinner"></div>
  <p id="status">Starting automatically…</p>
  <button id="run" type="button">Run close lifecycle probe</button>
</main>
<script>
  let started = false;
  async function run() {
    if (started) return;
    started = true;
    document.getElementById("run").disabled = true;
    document.getElementById("status").textContent = "Domain pending; window closes in 500 ms";
    try {
      await window.runLongTask();
      document.getElementById("status").textContent = "Unexpected response before close";
    } catch (error) {
      document.getElementById("status").textContent = String(error);
    }
  }
  document.getElementById("run").addEventListener("click", run);
  setTimeout(run, 400);
</script>
</body>
</html>|html}

let start_pending_work webview call_id =
  if Atomic.exchange work_started true then
    log "probe.duplicate_start" ""
  else (
    let responder_claimed = Atomic.make false in
    log "probe.started" (root_fields webview);

    let domain =
      Domain.spawn (fun () ->
          let work_start = Unix.gettimeofday () in
          log "domain.start" ",\"blocking_ms\":3000";
          Unix.sleepf 3.;
          let work_duration_ms =
            (Unix.gettimeofday () -. work_start) *. 1_000.
          in
          log "domain.work.completed"
            (Printf.sprintf ",\"duration_ms\":%.3f" work_duration_ms);
          match Atomic.get lifecycle with
          | Running ->
              if Atomic.compare_and_set responder_claimed false true then (
                log "response.dispatch.requested"
                  ",\"unexpected_running_state\":true";
                Webview.dispatch webview (fun _ ->
                    log "response.dispatch.executed" "";
                    Webview.return webview call_id 0
                      "{\"ok\":true,\"unexpected\":true}"))
          | (Closing | Destroyed) as state ->
              if Atomic.compare_and_set responder_claimed false true then (
                Atomic.set work_cancelled true;
                log "response.cancelled"
                  (Printf.sprintf ",\"lifecycle\":%S%s"
                     (string_of_lifecycle state) (root_fields webview))))
    in
    domain_handle := Some domain;

    let closer =
      Thread.create
        (fun () ->
          Unix.sleepf 0.5;
          log "window.close.requested" "";
          match Webview.post_window_close webview with
          | Ok () -> log "window.close.posted" ",\"posted\":true"
          | Error error ->
              log "window.close.posted" ",\"posted\":false";
              failwith (Webui_raw.Error.to_string error))
        ()
    in
    close_thread := Some closer)

let run () =
  let webview = Webview.create true in
  let destroyed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !destroyed then (
        log "webview.destroy.fallback" (root_fields webview);
        Webview.destroy webview))
    (fun () ->
      Webview.set_title webview "OCaml WebView Phase 1 Pending Close Probe";
      Webview.set_size webview 760 560 0;
      Webview.bind webview "runLongTask" (fun call_id _request ->
          let callback_start = Unix.gettimeofday () in
          log "callback.start" "";
          start_pending_work webview call_id;
          log "callback.return"
            (Printf.sprintf ",\"duration_ms\":%.3f"
               ((Unix.gettimeofday () -. callback_start) *. 1_000.)));
      Webview.set_html webview html;
      log "ffi.roots.before_run" (root_fields webview);
      log "webview.run" "";
      Webview.run webview;
      log "webview.run.returned" (root_fields webview);

      let transitioned = Atomic.compare_and_set lifecycle Running Closing in
      log "lifecycle.closing"
        (Printf.sprintf ",\"transitioned\":%s" (string_of_bool transitioned));

      Option.iter Thread.join !close_thread;
      log "window.close.thread_joined" "";
      Option.iter Domain.join !domain_handle;
      log "domain.joined" (root_fields webview);

      if not (Atomic.get work_started) then failwith "long task never started";
      if not (Atomic.get work_cancelled) then
        failwith "pending response was not cancelled";
      if (Webview.diagnostics webview).dispatch_roots <> 0 then
        failwith "dispatch roots remain before destroy";

      log "webview.destroy.start" (root_fields webview);
      Webview.destroy webview;
      destroyed := true;
      Atomic.set lifecycle Destroyed;
      log "webview.destroy.completed" (root_fields webview);

      if (Webview.diagnostics webview).binding_roots <> 0 then
        failwith "binding roots remain after destroy";
      if (Webview.diagnostics webview).dispatch_roots <> 0 then
        failwith "dispatch roots remain after destroy";
      log "probe.passed" "")

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "fatal: %s\n%s\n%!" (Printexc.to_string exn)
      (Printexc.get_backtrace ());
    exit 1
