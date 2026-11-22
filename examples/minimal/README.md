# examples/minimal

The smallest possible ocaml-webui app: no npm, no code generation.

The OCaml side registers a single `"echo"` Command with a passthrough
codec (`Yojson.Safe.t` in, `Yojson.Safe.t` out). The JS side — inline in
the HTML — builds a protocol v1 envelope by hand and calls
`__ocaml_webui_invoke` directly.

Use it to see the wire shape of the protocol. For real apps, use the
generated client + manifest path shown in `../typed-hello`.

## Run

```bash
opam exec -- dune exec examples/minimal/main.exe
```

Click the button to send `{message, seq}` to `echo` and see the raw
request/response envelopes.

## Files

- `main.ml` — everything: window, command, embedded HTML.
- `dune` — just `ocaml-webui.raw` + `ocaml-webui.bridge-atd`.
