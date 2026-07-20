# Phase 2 handwritten bridge baseline

This mini-application is the deliberately manual comparison baseline for the
later ATD-generated Typed Command bridge.

It registers one application Command, `text.analyze`, through the single native
binding `__ocaml_webui_invoke`. Its handwritten JavaScript client and OCaml
Yojson codecs verify:

- request ID and trace ID propagation;
- asynchronous Domain completion on the UI dispatch path;
- structured validation and unknown-command errors;
- sanitized handler-exception errors with the original exception kept in the
  native log;
- one-shot duplicate response rejection;
- pending Call cancellation when the Window closes;
- zero pending Call and callback roots after destroy.

Run the automated two-Window probe with:

```powershell
opam exec -- dune exec spikes/phase2-handwritten-bridge/main.exe
```

On Linux the two Windows run sequentially to respect the current
single-live-Window contract.
