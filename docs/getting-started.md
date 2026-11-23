# Getting started — consuming ocaml-webui as a library

This walks through the intended path for a new app: an OCaml declaration
file (`commands.ml`) → generated `.atd` schema + codecs + OCaml
registration + generated TypeScript client. It mirrors
`examples/typed-hello`, which you can read alongside this.

> Prototype status: `commands.ml` declarations are the recommended
> input for new apps (implemented as a Phase 2 proof-of-concept). The
> JSON manifest (`--manifest commands.json`, see
> [commands-manifest.md](commands-manifest.md)) remains as the
> underlying intermediate form. Both may change before the API is frozen.

## 1. Install

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam pin add ocaml-webui .
opam install ocaml-webui
```

The plain `git+https` pin does not fetch the `vendor/webview` submodule —
use the local-path pin above.

## 2. Layout

```
myapp/
  schema/
    dune               # copy generated .atd, atdml + atdts rules, schema library
  bin/
    dune               # command-gen + emit-client + esbuild + embed rules
    commands.ml        # Command + payload-type declarations (SSOT, parsed not compiled)
    main.ml            # window + handlers record (the only code you write)
    gen_bundle_embed.ml
  web/
    package.json       # esbuild + typescript
    esbuild-wrapper.mjs
    main.ts            # imports generated client + descriptors
```

## 3. Declarations (`bin/commands.ml`)

Type declarations use a restricted OCaml syntax (records, plain variants,
aliases, `int`/`float`/`string`/`bool`, `list`, `option`, named type
references); `let x = command ...` applications declare Commands. The
file is parsed by `command-gen` — it is *not* compiled by your app.

```ocaml
[@@@schema_module "Myapp_schema.Myapp"]
[@@@ts_module "./myapp.js"]

type ping_request = { message : string }
type ping_response = { echoed : string ; length : int }
type ping_error = {
  code : string;
  message : string;
  retryable : bool;
  category : string;
}

let ping = command "app.ping" ~mode:"sync"
  ~input:ping_request ~output:ping_response ~error:ping_error
```

- `~input`/`~output`/`~error` take **type identifiers**, not strings.
- Wire names are derived automatically: record fields `snake_case` →
  `camelCase`, variant constructors `CamelCase` → `snake_case`. Override
  per field/constructor with `[@json "wireName"]`.
- File-level `[@@@schema_module]`/`[@@@ts_module]` set defaults;
  `~schema_module`/`~ts_module` override per command.
- `~kind:"raw_json"` (with `~ts_output_type`/`~ts_type_decls`) declares a
  schema-free passthrough Command.
- Unsupported syntax (function types, polymorphic variants, GADTs,
  undeclared references, side-effecting expressions…) is rejected with
  `file:line:col: error: reason`.

The generated `.atd` feeds `atdml`/`atdts` as usual — `atdml` produces
`ping_request_of_yojson` / `yojson_of_ping_response` /
`yojson_of_ping_error`; `atdts` produces the TypeScript counterparts.
Field names are OCaml `snake_case` on both language sides; wire JSON is
whatever `<json name="...">` says.

## 4. Dune rules

```lisp
;; bin/dune — generate .atd + registration + descriptors in one pass
(rule
 (targets myapp.atd commands_gen.ml commands_gen.ts)
 (deps commands.ml)
 (action
  (run ocaml-webui.command-gen --decl commands.ml --atd myapp.atd
   --ocaml commands_gen.ml --ts commands_gen.ts)))

;; canonical runtime client (do not edit the emitted file)
(rule (targets client.ts)
  (action (run ocaml-webui.command-gen --emit-client client.ts)))

;; TS codec from the schema library
(rule (targets myapp.ts)
  (deps ../schema/myapp.ts)
  (action (copy ../schema/myapp.ts myapp.ts)))
```

```lisp
;; schema/dune — atdml/atdts write next to their input, so copy the
;; generated .atd into this directory first
(rule (targets myapp.atd)
  (deps ../bin/myapp.atd)
  (action (copy ../bin/myapp.atd myapp.atd)))

(rule (targets myapp.ml myapp.mli)
  (deps myapp.atd)
  (action (run atdml myapp.atd)))

(rule (target myapp.ts)
  (deps myapp.atd)
  (action (run atdts %{deps})))

(library (name myapp_schema) (libraries yojson) (modules myapp))
```

All generated files live under `_build/` — do not emit into your source
tree, and run `dune build` before opening the project in a TS editor so
the generated imports resolve.

## 5. Handlers (`bin/main.ml`)

`commands_gen.ml` exposes a `handlers` record — every declared Command is
a required field, so omitting one is a compile error. Write each handler
and install:

```ocaml
module Bridge = Webui_bridge_atd
module Schema = Myapp_schema.Myapp

let ping_handler _context (request : Schema.ping_request) responder =
  ignore
    (Bridge.responder_resolve responder
       { Schema.echoed = request.message;
         length = String.length request.message })

let trace_sink, _ = Webui_trace.ring_buffer ~capacity:256

let () =
  let window =
    match Webui_raw.Window.create { debug = false } with
    | Ok w -> w | Error e -> failwith (Webui_raw.Error.to_string e)
  in
  (match Bridge.install ~trace:trace_sink window
           ~commands:(Commands_gen.commands { Commands_gen.ping = ping_handler })
   with Ok _ -> () | Error _ -> assert false);
  (* set_html with the esbuild bundle, then Window.run / destroy *)
  ()
```

- sync (`~mode:"sync"`) handler: `context -> input -> responder -> unit`
- async (`~mode:"async"`) handler: `context -> input -> responder ->
  cancellation_token -> unit` — runs on a worker domain; poll the token
  at checkpoints; return without responding to let the bridge reject with
  `cancelled`. `~timeout_ms` acts as a watchdog.

## 6. TypeScript (`web/main.ts`)

```ts
import { invokeCommand, cancelCommand,
         ProtocolError, ApplicationError } from "./client.js";
import { appPing } from "./commands_gen.js";

const result = await invokeCommand(appPing, { message: "hi" });
// typed result: PingResponse
// typed error:  catch ApplicationError -> e.typedError: PingError
// protocol:     catch ProtocolError -> e.code / e.category / e.retryable
```

`cancelCommand(requestId, traceId)` sends the v1 cancel envelope for an
in-flight async request. `traceId`/`requestId` appear unchanged in the
unified trace on the OCaml side — that's the point of the runtime.

## 7. What is still manual / known limits

- `commands.ml` is parsed only — it is not typechecked by the OCaml
  compiler, and there is no editor/Merlin support for the `command`
  form (Phase 2 continuation).
- No JS→OCaml event push yet — Commands only.
- The unified trace records OCaml-side events only: `traceId`/`requestId`
  are minted on the JS side and passed through, but JS-side events are
  not recorded.
- Linux backend: one live Window at a time, create on the initial thread.
- `commands_gen.ts` imports `./client.js` — keep the emitted client named
  `client.ts` in the same output directory.
- Generated `commands_gen.ml` module name is `Commands_gen`; make sure it
  is in your executable's `modules`.
