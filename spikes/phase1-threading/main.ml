module Webview = struct
  type t

  external create : bool -> t = "ocaml_webview_create"
  external destroy : t -> unit = "ocaml_webview_destroy"
  external run : t -> unit = "ocaml_webview_run"
  external terminate : t -> unit = "ocaml_webview_terminate"
  external set_title : t -> string -> unit = "ocaml_webview_set_title"

  external set_size : t -> int -> int -> int -> unit
    = "ocaml_webview_set_size"

  external set_html : t -> string -> unit = "ocaml_webview_set_html"

  external bind : t -> string -> (string -> string -> unit) -> unit
    = "ocaml_webview_bind"

  external dispatch : t -> (t -> unit) -> unit = "ocaml_webview_dispatch"

  external return : t -> string -> int -> string -> unit
    = "ocaml_webview_return"
end

external current_thread_id : unit -> int = "ocaml_current_thread_id"

let started_at = Unix.gettimeofday ()

let elapsed_ms () = (Unix.gettimeofday () -. started_at) *. 1_000.

let log event fields =
  Printf.printf
    "{\"at_ms\":%.3f,\"event\":\"%s\",\"thread_id\":%d%s}\n%!"
    (elapsed_ms ()) event (current_thread_id ()) fields

let html ~auto_run =
  Printf.sprintf
    {html|<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Phase 1 threading probe</title>
  <style>
    :root { color-scheme: dark; font-family: Inter, ui-sans-serif, system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; background: #0b1020; color: #e8ecf6; }
    main { width: min(860px, calc(100%% - 40px)); margin: 32px auto; }
    h1 { font-size: 24px; margin: 0 0 8px; }
    .lede { color: #aeb8d0; line-height: 1.55; margin: 0 0 24px; }
    .grid { display: grid; grid-template-columns: 180px 1fr; gap: 18px; align-items: stretch; }
    .card { background: #151c31; border: 1px solid #2b3553; border-radius: 14px; padding: 18px; }
    .spinner-wrap { display: grid; place-items: center; min-height: 180px; }
    .spinner { width: 88px; height: 88px; border-radius: 50%%; border: 10px solid #29324d;
      border-top-color: #7c9cff; animation: spin .8s linear infinite; }
    @keyframes spin { to { transform: rotate(360deg); } }
    dl { display: grid; grid-template-columns: 170px 1fr; gap: 10px 16px; margin: 0; }
    dt { color: #9aa7c3; } dd { margin: 0; font-variant-numeric: tabular-nums; }
    button { margin-top: 18px; border: 0; border-radius: 10px; padding: 11px 16px;
      background: #7898ff; color: #07102a; font-weight: 700; cursor: pointer; }
    button:disabled { opacity: .55; cursor: wait; }
    pre { min-height: 96px; white-space: pre-wrap; color: #bcd0ff; margin: 0; }
    .hint { color: #f1c779; margin-top: 14px; font-size: 13px; }
    .pass { color: #65d6a0; } .warn { color: #f1c779; }
    @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
<main>
  <h1>Phase 1: blocking callback probe</h1>
  <p class="lede">The native callback blocks for three seconds. The probe records
    JavaScript frame gaps and a background-thread dispatch delay.</p>
  <section class="grid">
    <div class="card spinner-wrap"><div class="spinner" aria-label="animation probe"></div></div>
    <div class="card">
      <dl>
        <dt>Status</dt><dd id="status">ready</dd>
        <dt>Animation frames</dt><dd id="frames">0</dd>
        <dt>Largest frame gap</dt><dd id="gap">0 ms</dd>
        <dt>Promise duration</dt><dd id="duration">-</dd>
      </dl>
      <button id="run" type="button">Block native callback for 3 seconds</button>
      <p class="hint">During the run, also try moving or resizing the window.</p>
    </div>
  </section>
  <section class="card" style="margin-top:18px"><pre id="log">Waiting.</pre></section>
</main>
<script>
  const autoRun = %b;
  const $ = (id) => document.getElementById(id);
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

  async function runProbe() {
    $("run").disabled = true;
    $("status").textContent = "native callback running";
    $("log").textContent = "Calling window.blockForThreeSeconds()...";
    maxGap = 0;
    measuring = true;
    const started = performance.now();

    try {
      const nativeResult = await window.blockForThreeSeconds();
      const promiseDurationMs = performance.now() - started;
      await new Promise(requestAnimationFrame);
      measuring = false;
      const rendererStalled = maxGap > 1_000;
      const metrics = {
        promiseDurationMs,
        maxFrameGapMs: maxGap,
        rendererStalled,
        nativeResult
      };
      $("duration").textContent = `${promiseDurationMs.toFixed(1)} ms`;
      $("status").textContent = rendererStalled
        ? "renderer frame loop stalled"
        : "renderer continued; inspect native dispatch log";
      $("status").className = rendererStalled ? "warn" : "pass";
      $("log").textContent = JSON.stringify(metrics, null, 2);
      await window.reportProbe(metrics);
    } catch (error) {
      measuring = false;
      $("status").textContent = "probe failed";
      $("log").textContent = String(error?.stack ?? error);
    } finally {
      $("run").disabled = false;
    }
  }

  $("run").addEventListener("click", runProbe);
  if (autoRun) setTimeout(runProbe, 750);
</script>
</body>
</html>|html}
    auto_run

let run () =
  let auto_run = Array.exists (( = ) "--auto") Sys.argv in
  let webview = Webview.create true in
  Fun.protect
    ~finally:(fun () ->
      log "webview.destroy" "";
      Webview.destroy webview)
    (fun () ->
      Webview.set_title webview "OCaml WebView Phase 1 Threading Probe";
      Webview.set_size webview 900 620 0;

      Webview.bind webview "blockForThreeSeconds" (fun call_id _request ->
          let callback_started = Unix.gettimeofday () in
          log "callback.start" ",\"blocking_ms\":3000";

          let _dispatch_thread =
            Thread.create
              (fun () ->
                Unix.sleepf 0.25;
                let requested_at = Unix.gettimeofday () in
                log "dispatch.requested" "";
                Webview.dispatch webview (fun _ ->
                    let delay_ms =
                      (Unix.gettimeofday () -. requested_at) *. 1_000.
                    in
                    log "dispatch.executed"
                      (Printf.sprintf ",\"queue_delay_ms\":%.3f" delay_ms)))
              ()
          in

          Unix.sleepf 3.;
          let duration_ms =
            (Unix.gettimeofday () -. callback_started) *. 1_000.
          in
          log "callback.end"
            (Printf.sprintf ",\"duration_ms\":%.3f" duration_ms);
          let result =
            Printf.sprintf
              "{\"nativeDurationMs\":%.3f,\"callbackThreadId\":%d}"
              duration_ms (current_thread_id ())
          in
          Webview.return webview call_id 0 result);

      Webview.bind webview "reportProbe" (fun call_id request ->
          log "browser.metrics" (Printf.sprintf ",\"args\":%S" request);
          Webview.return webview call_id 0 "null";
          if auto_run then Webview.terminate webview);

      Webview.set_html webview (html ~auto_run);
      log "webview.run" "";
      Webview.run webview;
      log "webview.run.returned" "")

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "fatal: %s\n%s\n%!" (Printexc.to_string exn)
      (Printexc.get_backtrace ());
    exit 1

