# Phase 1 threading spike

This spike answers one question:

> Does a three-second OCaml callback block the WebView UI event loop on
> Windows/WebView2?

It measures two related effects:

1. JavaScript `requestAnimationFrame` gaps while the callback is running.
2. The queue delay of a UI `dispatch` requested from a background thread after
   the callback has started.

The second measurement is the stronger signal. WebView2 renders in multiple
processes, so browser animation may continue even while the native window's UI
thread is blocked.

## Run interactively

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe
```

Press the button, then try moving or resizing the window during the three-second
callback.

## Run the automatic probe

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
```

The automatic mode starts the probe after 750 ms, prints newline-delimited JSON
events, reports browser metrics, and closes the window.

Expected evidence of a blocked UI event loop:

- `callback.start` and `callback.end` use the same thread ID as
  `dispatch.executed`.
- `dispatch.requested` comes from a different thread about 250 ms after the
  callback starts.
- `dispatch.executed.queue_delay_ms` is about 2750 ms, because it cannot run
  until the callback returns.

## Dependency note

`owebview` currently documents Windows as unsupported by its build skeleton.
Its vendored webview 0.12 header does contain the WebView2 backend. This spike
reuses the upstream OCaml stubs and supplies the documented MinGW Windows
libraries locally without modifying the submodule.

## Webui_raw migration (2026-07-19)

The executable now links `ocaml-webui.raw` directly. It no longer copies the
owebview stub or maintains local WebView2 link rules. The historical dependency
note above describes the original Phase 1 setup and is retained as evidence.
