# Phase 1 Domain → UI dispatch spike

This spike verifies that blocking work can run on a separate OCaml Domain while
the native UI event loop remains available.

It covers three paths:

1. Three-second work on a Domain, followed by a successful Promise result
   scheduled with `Webview.dispatch`.
2. A Domain exception converted into a Promise rejection on the UI thread.
3. Two response attempts guarded by `Atomic.compare_and_set`, proving that only
   one dispatch is scheduled for each call.

## Run automatically

```powershell
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
```

The window runs the success and failure probes, prints newline-delimited JSON,
and closes automatically.

## Success criteria

- Binding callbacks return in tens of milliseconds rather than waiting for work.
- Domain worker thread IDs differ from the native UI thread ID.
- Response dispatch executes on the UI thread with a short queue delay.
- The renderer frame gap stays small during the three-second operation.
- The failure case rejects the JavaScript Promise with a structured error.
- Each case logs `response.duplicate_suppressed` after its accepted response.

Do not use this spike to judge window-close safety. Closing a window while a
Domain response is pending is the separate Phase 1 lifecycle spike.

## FFI patch under test

The upstream `owebview` trampolines release the OCaml runtime lock before
`CAMLdrop`. With a Domain active this produced Windows access violation
`0xC0000005`. This spike generates its build copy with the two operations
reordered so OCaml local roots are removed while the runtime lock is still held.
The submodule source remains unchanged.
