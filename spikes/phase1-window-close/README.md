# Phase 1 pending callback window-close spike

This spike starts a three-second Domain task from a JavaScript binding and
requests a real platform-native close while the Promise is pending (`WM_CLOSE`
on Windows, `gtk_window_close` on Linux).

The lifecycle policy under test is:

1. The native window closes and `Webview.run` returns.
2. The OCaml lifecycle atomically changes from `Running` to `Closing`.
3. The Domain sees `Closing` and claims its response as cancelled without
   scheduling UI dispatch.
4. The main Domain joins the worker.
5. `Webview.destroy` releases binding roots.
6. Instrumented binding and dispatch root counts must both be zero.

## Run

```powershell
opam exec -- dune exec spikes/phase1-window-close/main.exe
```

The WebView starts automatically and closes about 900 ms after launch. The
process remains alive until the pending Domain finishes, validates cleanup, and
then exits.

## Success criteria

- A platform-native close is requested while a Domain task is pending.
- No response dispatch is scheduled after the lifecycle enters `Closing`.
- The Domain is joined before `Webview.destroy`.
- Binding roots change from one before destroy to zero after destroy.
- Dispatch roots remain zero.
- The process exits with code 0 without access violation or use-after-destroy.

The root counters and the `CAMLdrop` cleanup-order correction exist only in the
generated build copy. The upstream `owebview` submodule remains unchanged.

## Webui_raw migration (2026-07-19)

The probe now requests the real native close path through
`Webui_raw.For_testing.Native_window.request_close` (a Win32 `WM_CLOSE` on
Windows and `gtk_window_close` on Linux) and reads per-Window diagnostics
from `Webui_raw.Diagnostics`. The generated owebview stub, patch script, and
local native-close stub were removed. The paragraph above records the original
Phase 1 implementation.
