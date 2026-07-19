# Results

Date: 2026-07-19

Outcome: **confirmed — the OCaml binding callback blocks the native WebView UI event loop.**

## Environment

- Windows NT 10.0.26200.0
- Microsoft Edge WebView2 Runtime 150.0.4078.65
- OCaml 5.4.1
- dune 3.24.0
- MinGW-w64 GCC/G++ 14.4.0
- webview 0.12.0 via the `owebview` submodule
- Microsoft WebView2 SDK headers 1.0.1150.38

## Command

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
```

## Measurements

| Measurement | Result |
|---|---:|
| Callback duration | 3010.808 ms |
| UI callback thread | 11488 |
| Dispatch requester thread | 20896 |
| Dispatch queue delay | 2733.868 ms |
| Browser Promise duration | 3028.5 ms |
| Largest renderer frame gap | 23.1 ms |
| Renderer frame loop stalled | false |

The background thread requested UI dispatch about 277 ms after the callback
started. The dispatch closure did not run until immediately after the callback
ended, leaving it queued for about 2734 ms.

```json
{"at_ms":2434.440,"event":"callback.start","thread_id":11488,"blocking_ms":3000}
{"at_ms":2711.887,"event":"dispatch.requested","thread_id":20896}
{"at_ms":5445.248,"event":"callback.end","thread_id":11488,"duration_ms":3010.808}
{"at_ms":5445.755,"event":"dispatch.executed","thread_id":11488,"queue_delay_ms":2733.868}
{"at_ms":5457.382,"event":"browser.metrics","thread_id":11488,"args":"[{\"promiseDurationMs\":3028.5,\"maxFrameGapMs\":23.100000000000364,\"rendererStalled\":false,\"nativeResult\":{\"nativeDurationMs\":3010.808,\"callbackThreadId\":11488}}]"}
```

## Interpretation

The WebView callback, the event loop, and the queued dispatch closure all use
the same native UI thread. A blocking handler therefore prevents native UI work
and queued dispatches from progressing.

WebView2's renderer continued producing animation frames because it runs out of
process. A smooth CSS animation is not evidence that the host UI event loop is
responsive. This is why the dispatch queue delay is the decisive measurement.

Window move/resize responsiveness was not measured by the automatic run and
remains an optional manual observation.

## Design consequence

Command handlers must not perform blocking work on the binding callback. The
next spike should run the three-second operation on a separate OCaml Domain and
return the result through `Webview.dispatch`, while verifying thread identity,
exception propagation, and shutdown behavior.