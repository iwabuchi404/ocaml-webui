# examples/typed-hello

The reference app for the manifest-driven Command pipeline — the intended
way to build on ocaml-webui.

```
schema/hello.atd ──atdml/atdts──> OCaml + TypeScript codecs
bin/commands.json ──command-gen──> commands_gen.ml + commands_gen.ts
                └──--emit-client──> client.ts (canonical protocol v1 client)
web/main.ts + generated files ──esbuild──> main.bundle.js ──embed──> main.exe
```

| Command        | Shows                                                          |
|----------------|----------------------------------------------------------------|
| `hello.ping`   | sync ATD Command; typed validation error (`empty_message`/`too_long`) |
| `work.count`   | async Command on a worker domain; `cancellation_token` checkpoints, JS cancel, 30 s watchdog |
| `trace.recent` | `raw_json` Command reading the unified trace ring buffer        |

You write the `.atd` schema, `commands.json`, handler bodies, and the TS
UI — everything else is generated.

## Run

```bash
cd web && npm ci && cd ..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

To smoke-test headlessly, `OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS=<ms>` closes
the window after the given delay.

## Files

- `schema/hello.atd` — payload types (SSOT for codecs).
- `bin/commands.json` — command manifest (SSOT for wiring).
- `bin/main.ml` — window + the `handlers` record you implement.
- `bin/dune` — codegen + bundle + embed rules, mirrors what an app needs.
- `web/main.ts` — imports the emitted client + generated descriptors.
- `web/esbuild-wrapper.mjs` — esbuild JS-API wrapper (cross-platform).
