# examples/typed-hello

The reference app for the declaration-driven Command pipeline — the
intended way to build on ocaml-webui.

```
bin/commands.ml ──command-gen --decl──> hello.atd ──atdml/atdts──> OCaml + TS codecs
                                  └──> commands_gen.ml + commands_gen.ts
                └──--emit-client──> client.ts (canonical protocol v1 client)
web/main.ts + generated files ──esbuild──> main.bundle.js ──embed──> main.exe
```

| Command        | Shows                                                          |
|----------------|----------------------------------------------------------------|
| `hello.ping`   | sync ATD Command; typed validation error (`empty_message`/`too_long`) |
| `work.count`   | async Command on a worker domain; `cancellation_token` checkpoints, JS cancel, 30 s watchdog |
| `trace.recent` | `raw_json` Command reading the unified trace ring buffer        |

You write `commands.ml` (payload types + command declarations), handler
bodies, and the TS UI — everything else is generated. `commands.ml` is
parsed by `command-gen` only; it is not compiled into the app.

## Run

```bash
cd web && npm ci && cd ..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

To smoke-test headlessly, `OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS=<ms>` closes
the window after the given delay.

## Files

- `bin/commands.ml` — payload types + command declarations (SSOT).
- `bin/main.ml` — window + the `handlers` record you implement.
- `bin/dune` — codegen + bundle + embed rules, mirrors what an app needs.
- `schema/dune` — copies the generated `hello.atd` and runs atdml/atdts.
- `web/main.ts` — imports the emitted client + generated descriptors.
- `web/esbuild-wrapper.mjs` — esbuild JS-API wrapper (cross-platform).
