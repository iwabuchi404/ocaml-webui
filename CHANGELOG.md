# Changelog

## v0.1 — documented prototype (2026-11-22)

First article-reader-facing state. Prototype status: APIs are not frozen.

### Command generation

- `ocaml-webui.command-gen`: generates OCaml handler contracts +
  registration (`commands_gen.ml`) and TypeScript descriptors
  (`commands_gen.ts`) from a single input.
- Two inputs, one IR: `--decl commands.ml` (restricted-OCaml-syntax
  declarations — types + `command` applications, recommended for new
  apps) and `--manifest commands.json` (the underlying IR).
- `--emit-client`: emits the canonical `client.ts` protocol v1 client.
- Missing handlers are compile errors; forgetting a `pack` is
  structurally impossible.

### Runtime libraries

- `ocaml-webui.raw` — owned WebView binding (WebView2 / WebKitGTK),
  lifecycle state machine.
- `ocaml-webui.bridge-atd` — protocol v1 envelope, ATD payload codecs,
  structured errors.
- `ocaml-webui.async` — domain-based async Commands, cooperative
  cancellation, watchdog timeouts.
- `ocaml-webui.trace` — unified trace across JS → OCaml → Worker.
- `ocaml-webui.exec` — one-shot external process execution.
- `ocaml-webui.worker` / `ocaml-webui.resource` — explicit Worker
  separation and resource scoping.

### Examples

- `examples/minimal` — raw protocol v1 envelope, no npm, no codegen.
- `examples/typed-hello` — `commands.ml` → full generated pipeline:
  sync ATD Command, async Command with cancel/timeout, `raw_json`
  trace Command.

### Known limits

- `commands.ml` is parsed, not compiled (no Merlin typecheck yet).
- No JS→OCaml event push; JS-side events are not recorded in the trace.
- Linux backend: one live Window at a time.
