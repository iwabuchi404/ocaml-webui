# Results

Date: 2026-07-19

Outcome: **A native window can close while a Domain-backed binding response is
pending, provided the lifecycle cancels the response, joins the Domain, and
only then destroys the WebView. All instrumented FFI roots were released.**

## Environment

- Windows NT 10.0.26200.0
- Microsoft Edge WebView2 Runtime 150.0.4078.65
- OCaml 5.4.1
- dune 3.24.0
- MinGW-w64 GCC/G++ 14.4.0
- webview 0.12.0 via the `owebview` submodule

## Command

```powershell
opam exec -- dune exec spikes/phase1-window-close/main.exe
```

## First-run measurements

| Measurement | Result |
|---|---:|
| Binding callback duration | 1.050 ms |
| Close request after Domain start | 505.531 ms |
| `Webview.run` return after close post | 47.682 ms |
| Domain work duration | 3008.388 ms |
| Wait from `Webview.run` return to Domain completion | 2455.175 ms |
| `Webview.destroy` duration | 7.698 ms |

The callback ran on native UI thread 18920, the Domain on thread 122016, and
the close requester on thread 109748. `PostMessageW(WM_CLOSE)` returned true.

## Observed lifecycle

1. The binding registered one binding root and started a three-second Domain.
2. The callback returned in 1.050 ms.
3. A separate native thread posted `WM_CLOSE` while the Domain was pending.
4. `Webview.run` returned and lifecycle changed atomically to `Closing`.
5. The Domain finished, observed `Closing`, and claimed its response as
   cancelled without calling `Webview.dispatch`.
6. The main Domain joined the worker before calling `Webview.destroy`.
7. Binding roots changed from one to zero; dispatch roots remained zero.

The full logged run exited with code 0 and emitted `probe.passed`. Three
additional consecutive runs each produced exactly one cancellation, one
zero-root destruction record, and one pass record, also with code 0.

## FFI instrumentation

The build-generated `webview_stubs.cpp` adds counters for registered binding
and dispatch roots. It also applies the `CAMLdrop`-before-runtime-release fix
found by the Domain dispatch spike. Exact replacement counts make the build
fail if the upstream source no longer matches the reviewed shape. The
`owebview` submodule itself remains unchanged.

## Conclusion

- A pending JavaScript Promise does not require a native response after its
  owning window begins closing.
- Lifecycle state must be checked before scheduling UI dispatch.
- Workers must be joined before WebView destruction so they cannot reference a
  destroyed handle.
- Binding cleanup belongs to `Webview.destroy`; dispatch closures need one-shot
root ownership and must be absent at destruction time.

## Webui_raw migration rerun (2026-07-19)

The probe was rerun using the owned binding and its real Win32 `WM_CLOSE` hook.

- `WM_CLOSE` post to `Window.run` return: 55.682 ms
- Domain work duration: 3006.576 ms
- pending response: cancelled after the native close
- binding roots: 1 before destroy, 0 after destroy
- dispatch roots: 0 before and after destroy
- worker joined before explicit destroy
- exit code: 0

This reproduces the original native-close result without patching owebview.
