# Results

Date: 2026-07-19

Outcome: **Domain → UI dispatch works after correcting an unsafe FFI cleanup
order in the upstream trampoline build copy.**

## Environment

- Windows NT 10.0.26200.0
- Microsoft Edge WebView2 Runtime 150.0.4078.65
- OCaml 5.4.1
- dune 3.24.0
- MinGW-w64 GCC/G++ 14.4.0
- webview 0.12.0 via the `owebview` submodule

## Command

```powershell
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
```

## Measurements

| Measurement | Success case | Failure case |
|---|---:|---:|
| Binding callback duration | 1.012 ms | 0.500 ms |
| Domain worker thread | 63524 | 122820 |
| Native UI thread | 81752 | 81752 |
| UI dispatch queue delay | 0.500 ms | 3.572 ms |
| Browser Promise duration | 3026.9 ms | 367.7 ms |
| Largest renderer frame gap | 18.7 ms | 18.3 ms |
| Frames during operation | 186 | 21 |

The success Promise resolved with a structured value. The simulated Domain
exception rejected the Promise with:

```json
{"code":"domain_failure","message":"simulated domain failure"}
```

Both cases logged `response.duplicate_suppressed`; the Atomic one-shot guard
allowed only the first response attempt to schedule UI dispatch.

The corrected automatic probe completed once with full metrics and then three
additional consecutive runs all exited with code 0.

## FFI failure discovered during the spike

The first Domain run consistently terminated with Windows access violation
`0xC0000005` immediately around the cross-Domain dispatch. The upstream
trampolines performed this sequence:

```text
caml_release_runtime_system();
CAMLdrop;
```

`CAMLdrop` manipulates OCaml local roots and must run while the runtime lock is
held. The spike now generates its build copy with the order reversed:

```text
CAMLdrop;
caml_release_runtime_system();
```

The exact replacement is guarded by an expected match count of two. The
`owebview` submodule remains unchanged. After this correction, the success and
failure dispatches completed and repeated runs remained stable.

## Conclusion

- A binding callback can start a Domain and return to the WebView event loop in
  about one millisecond.
- Blocking work on the Domain does not stall WebView2 renderer frames.
- The worker can schedule a short UI closure that resolves or rejects the
  original JavaScript Promise.
- Response ownership needs an explicit one-shot guard before dispatch is
  scheduled.
- The FFI trampoline cleanup order is part of the runtime's correctness and
  cannot be treated as an unreviewed thin-binding detail.

The next lifecycle spike must close the window while a Domain response is
pending and verify dispatch failure handling, callback roots, Domain joining,
and destruction order.