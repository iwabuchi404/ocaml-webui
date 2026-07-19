module Webview = struct
  type t = Webui_raw.Window.t
  type call = Webui_raw.Call.t

  let fail_error error = failwith (Webui_raw.Error.to_string error)
  let require = function Ok value -> value | Error error -> fail_error error
  let create debug = require (Webui_raw.Window.create { debug })
  let destroy window = require (Webui_raw.Window.destroy window)
  let run window = require (Webui_raw.Window.run window)
  let terminate window = require (Webui_raw.Window.request_close window)
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
end

let current_thread_id = Webui_raw.For_testing.current_thread_id

let started_at = Unix.gettimeofday ()
let log_mutex = Mutex.create ()
let domains : unit Domain.t list ref = ref []

let elapsed_ms () = (Unix.gettimeofday () -. started_at) *. 1_000.

let log event fields =
  Mutex.protect log_mutex (fun () ->
      Printf.printf
        "{\"at_ms\":%.3f,\"event\":\"%s\",\"thread_id\":%d%s}\n%!"
        (elapsed_ms ()) event (current_thread_id ()) fields)

type responder = {
  webview : Webview.t;
  call_id : Webview.call;
  label : string;
  claimed : bool Atomic.t;
}

let make_responder webview call_id label =
  { webview; call_id; label; claimed = Atomic.make false }

let respond_once responder ~status ~payload ~reason =
  if Atomic.compare_and_set responder.claimed false true then (
    let requested_at = Unix.gettimeofday () in
    log "response.claimed"
      (Printf.sprintf ",\"case\":%S,\"reason\":%S,\"status\":%d"
         responder.label reason status);
    try
      Webview.dispatch responder.webview (fun _ ->
          let queue_delay_ms =
            (Unix.gettimeofday () -. requested_at) *. 1_000.
          in
          log "response.dispatch.executed"
            (Printf.sprintf
               ",\"case\":%S,\"queue_delay_ms\":%.3f,\"status\":%d"
               responder.label queue_delay_ms status);
          try Webview.return responder.webview responder.call_id status payload
          with exn ->
            log "response.return.failed"
              (Printf.sprintf ",\"case\":%S,\"exception\":%S"
                 responder.label (Printexc.to_string exn)))
    with exn ->
      log "response.dispatch.failed"
        (Printf.sprintf ",\"case\":%S,\"exception\":%S" responder.label
           (Printexc.to_string exn)))
  else
    log "response.duplicate_suppressed"
      (Printf.sprintf ",\"case\":%S,\"reason\":%S" responder.label reason)

let spawn_tracked work =
  let domain = Domain.spawn work in
  domains := domain :: !domains

let join_domains () =
  List.rev !domains
  |> List.iteri (fun index domain ->
         try
           Domain.join domain;
           log "domain.joined" (Printf.sprintf ",\"index\":%d" index)
         with exn ->
           log "domain.join.failed"
             (Printf.sprintf ",\"index\":%d,\"exception\":%S" index
                (Printexc.to_string exn)))

let html ~auto_run =
  Printf.sprintf
    {html|<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Phase 1 Domain dispatch probe</title>
  <style>
    :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: #0a1020; color: #e8ecf6; }
    main { width: min(920px, calc(100%% - 40px)); margin: 30px auto; }
    h1 { font-size: 24px; margin: 0 0 8px; }
    .lede { color: #aeb8d0; line-height: 1.55; margin: 0 0 20px; }
    .grid { display: grid; grid-template-columns: 180px 1fr; gap: 18px; }
    .card { background: #151c31; border: 1px solid #2b3553; border-radius: 14px; padding: 18px; }
    .spinner-wrap { display: grid; place-items: center; min-height: 180px; }
    .spinner { width: 88px; height: 88px; border-radius: 50%%; border: 10px solid #29324d;
      border-top-color: #67d5a2; animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    dl { display: grid; grid-template-columns: 190px 1fr; gap: 9px 16px; margin: 0; }
    dt { color: #9aa7c3; } dd { margin: 0; font-variant-numeric: tabular-nums; }
    .actions { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 18px; }
    button { border: 0; border-radius: 10px; padding: 11px 16px; background: #67d5a2;
      color: #071a13; font-weight: 700; cursor: pointer; }
    button.secondary { background: #f0b76c; color: #231506; }
    button:disabled { opacity: .55; cursor: wait; }
    pre { min-height: 180px; max-height: 340px; overflow: auto; white-space: pre-wrap;
      color: #bdd0ff; margin: 0; }
    .pass { color: #65d6a0; } .warn { color: #f1c779; }
    @media (max-width: 660px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<main>
  <h1>Phase 1: Domain → UI dispatch</h1>
  <p class="lede">Blocking work runs on a separate OCaml Domain. Promise success
    and failure both return through a guarded UI-thread dispatch.</p>
  <section class="grid">
    <div class="card spinner-wrap"><div class="spinner" aria-label="animation probe"></div></div>
    <div class="card">
      <dl>
        <dt>Status</dt><dd id="status">ready</dd>
        <dt>Animation frames</dt><dd id="frames">0</dd>
        <dt>Current max frame gap</dt><dd id="gap">0 ms</dd>
      </dl>
      <div class="actions">
        <button id="success" type="button">Run 3-second Domain work</button>
        <button id="failure" class="secondary" type="button">Run failure path</button>
      </div>
    </div>
  </section>
  <section class="card" style="margin-top:18px"><pre id="log">Waiting.</pre></section>
</main>
<script>
  const autoRun = %b;
  const $ = (id) => document.getElementById(id);
  const buttons = [$("success"), $("failure")];
  let frames = 0;
  let lastFrame = performance.now();
  let maxGap = 0;
  let measuring = false;

  function animationFrame(now) {
    if (measuring) maxGap = Math.max(maxGap, now - lastFrame);
    lastFrame = now;
    frames += 1;
    $("frames").textContent = String(frames);
    $("gap").textContent = `${maxGap.toFixed(1)} ms`;
    requestAnimationFrame(animationFrame);
  }
  requestAnimationFrame(animationFrame);

  function setBusy(busy) { buttons.forEach((button) => button.disabled = busy); }
  function errorText(error) {
    if (typeof error === "string") return error;
    try { return JSON.stringify(error); } catch { return String(error); }
  }

  async function measure(label, operation, expectRejection) {
    setBusy(true);
    maxGap = 0;
    lastFrame = performance.now();
    measuring = true;
    const frameStart = frames;
    const started = performance.now();
    $("status").textContent = `${label} running`;
    try {
      const value = await operation();
      if (expectRejection) throw new Error("failure case unexpectedly resolved");
      await new Promise(requestAnimationFrame);
      return {
        label,
        resolved: true,
        durationMs: performance.now() - started,
        maxFrameGapMs: maxGap,
        framesDuringOperation: frames - frameStart,
        value
      };
    } catch (error) {
      await new Promise(requestAnimationFrame);
      if (!expectRejection) throw error;
      return {
        label,
        rejected: true,
        durationMs: performance.now() - started,
        maxFrameGapMs: maxGap,
        framesDuringOperation: frames - frameStart,
        error: errorText(error)
      };
    } finally {
      measuring = false;
      setBusy(false);
    }
  }

  async function runSuccess() {
    const result = await measure("success", () => window.runInDomain(), false);
    $("status").textContent = "success returned through UI dispatch";
    $("status").className = "pass";
    $("log").textContent = JSON.stringify(result, null, 2);
    return result;
  }

  async function runFailure() {
    const result = await measure("failure", () => window.failInDomain(), true);
    $("status").textContent = "Domain exception became Promise rejection";
    $("status").className = "pass";
    $("log").textContent = JSON.stringify(result, null, 2);
    return result;
  }

  $("success").addEventListener("click", runSuccess);
  $("failure").addEventListener("click", runFailure);

  if (autoRun) setTimeout(async () => {
    try {
      const success = await runSuccess();
      await new Promise((resolve) => setTimeout(resolve, 150));
      const failure = await runFailure();
      const report = { success, failure };
      $("log").textContent = JSON.stringify(report, null, 2);
      await window.reportProbe(report);
    } catch (error) {
      $("status").textContent = "automatic probe failed";
      $("status").className = "warn";
      $("log").textContent = errorText(error);
    }
  }, 750);
</script>
</body>
</html>|html}
    auto_run

let bind_success webview =
  Webview.bind webview "runInDomain" (fun call_id _request ->
      let callback_started = Unix.gettimeofday () in
      log "callback.start" ",\"case\":\"success\"";
      let responder = make_responder webview call_id "success" in
      spawn_tracked (fun () ->
          log "domain.start" ",\"case\":\"success\",\"blocking_ms\":3000";
          Unix.sleepf 3.;
          log "domain.work.completed" ",\"case\":\"success\"";
          let payload =
            Printf.sprintf
              "{\"ok\":true,\"workerThreadId\":%d,\"workDurationMs\":3000}"
              (current_thread_id ())
          in
          respond_once responder ~status:0 ~payload ~reason:"work_completed";
          respond_once responder ~status:0 ~payload ~reason:"duplicate_probe";
          log "domain.end" ",\"case\":\"success\"");
      let callback_duration_ms =
        (Unix.gettimeofday () -. callback_started) *. 1_000.
      in
      log "callback.return"
        (Printf.sprintf ",\"case\":\"success\",\"duration_ms\":%.3f"
           callback_duration_ms))

let bind_failure webview =
  Webview.bind webview "failInDomain" (fun call_id _request ->
      let callback_started = Unix.gettimeofday () in
      log "callback.start" ",\"case\":\"failure\"";
      let responder = make_responder webview call_id "failure" in
      spawn_tracked (fun () ->
          log "domain.start" ",\"case\":\"failure\",\"blocking_ms\":350";
          (try
             Unix.sleepf 0.35;
             failwith "simulated domain failure"
           with exn ->
             log "domain.exception"
               (Printf.sprintf ",\"case\":\"failure\",\"exception\":%S"
                  (Printexc.to_string exn));
             let payload =
               "{\"code\":\"domain_failure\",\"message\":\"simulated domain failure\"}"
             in
             respond_once responder ~status:1 ~payload ~reason:"exception";
             respond_once responder ~status:1 ~payload ~reason:"cleanup_duplicate");
          log "domain.end" ",\"case\":\"failure\"");
      let callback_duration_ms =
        (Unix.gettimeofday () -. callback_started) *. 1_000.
      in
      log "callback.return"
        (Printf.sprintf ",\"case\":\"failure\",\"duration_ms\":%.3f"
           callback_duration_ms))

let run () =
  let auto_run = Array.exists (( = ) "--auto") Sys.argv in
  let webview = Webview.create true in
  Fun.protect
    ~finally:(fun () ->
      log "webview.destroy" "";
      Webview.destroy webview)
    (fun () ->
      Webview.set_title webview "OCaml WebView Phase 1 Domain Dispatch Probe";
      Webview.set_size webview 940 650 0;
      bind_success webview;
      bind_failure webview;
      Webview.bind webview "reportProbe" (fun call_id request ->
          log "browser.metrics" (Printf.sprintf ",\"args\":%S" request);
          Webview.return webview call_id 0 "null";
          if auto_run then Webview.terminate webview);
      Webview.set_html webview (html ~auto_run);
      log "webview.run" "";
      Webview.run webview;
      log "webview.run.returned" "";
      join_domains ())

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "fatal: %s\n%s\n%!" (Printexc.to_string exn)
      (Printexc.get_backtrace ());
    exit 1
