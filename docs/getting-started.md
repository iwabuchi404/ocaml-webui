# Getting started — consuming ocaml-webui as a library

This walks through the intended path for a new app: ATD schema + command
manifest → generated OCaml registration + generated TypeScript client.
It mirrors `examples/typed-hello`, which you can read alongside this.

> Prototype status: this is the v0.1 manifest-driven path. The long-term
> SSOT is OCaml-declaration-driven generation (Phase 2, undecided); the
> manifest format below is an intermediate step and may be replaced.

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
    dune               # atdml + atdts rules, schema library
    myapp.atd          # SSOT for Command payload types
  bin/
    dune               # command-gen + emit-client + esbuild + embed rules
    commands.json      # Command manifest (see docs/commands-manifest.md)
    main.ml            # window + handlers record (the only code you write)
    gen_bundle_embed.ml
  web/
    package.json       # esbuild + typescript
    esbuild-wrapper.mjs
    main.ts            # imports generated client + descriptors
```

## 3. Schema (`schema/myapp.atd`)

```atd
type ping_request = { message: string; }
type ping_response = { echoed: string; length: int; }
type ping_error = {
  code: string;
  message: string;
  retryable: bool;
  category: string;
}
```

`atdml` produces `ping_request_of_yojson` / `yojson_of_ping_response` /
`yojson_of_ping_error`; `atdts` produces the TypeScript counterparts.
Field names are OCaml `snake_case` on both language sides; wire JSON is
whatever `<json name="...">` says.

## 4. Manifest (`bin/commands.json`)

```json
{
  "commands": [
    {
      "name": "app.ping",
      "schemaModule": "Myapp_schema.Myapp",
      "input": "ping_request",
      "output": "ping_response",
      "error": "ping_error",
      "mode": "sync",
      "tsModule": "./myapp.js"
    }
  ]
}
```

Full reference: [commands-manifest.md](commands-manifest.md).

## 5. Dune rules (`bin/dune`)

```lisp
;; TS codec from the schema library
(rule (targets myapp.ts)
  (deps ../schema/myapp.ts)
  (action (copy ../schema/myapp.ts myapp.ts)))

;; canonical runtime client (do not edit the emitted file)
(rule (targets client.ts)
  (action (run ocaml-webui.command-gen --emit-client client.ts)))

;; OCaml registration + TS descriptors from the manifest
(rule (targets commands_gen.ml commands_gen.ts)
  (deps commands.json)
  (action
    (run ocaml-webui.command-gen --manifest commands.json
     --ocaml commands_gen.ml --ts commands_gen.ts)))

;; copy web sources, bundle with esbuild, embed as an OCaml string
;; (see examples/typed-hello/bin/dune for the full file)
```

All generated files live under `_build/` — do not emit into your source
tree, and run `dune build` before opening the project in a TS editor so
the generated imports resolve.

## 6. Handlers (`bin/main.ml`)

`commands_gen.ml` exposes a `handlers` record — every manifest Command is
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

- sync (`mode:"sync"`) handler: `context -> input -> responder -> unit`
- async (`mode:"async"`) handler: `context -> input -> responder ->
  cancellation_token -> unit` — runs on a worker domain; poll the token
  at checkpoints; return without responding to let the bridge reject with
  `cancelled`. `~timeout_ms` from the manifest acts as a watchdog.

## 7. TypeScript (`web/main.ts`)

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

## 8. What is still manual / known limits

- `.atd` + `commands.json` are two files to keep in sync by hand
  (Phase 2 removes this).
- No JS→OCaml event push yet — Commands only.
- Linux backend: one live Window at a time, create on the initial thread.
- `commands_gen.ts` imports `./client.js` — keep the emitted client named
  `client.ts` in the same output directory.
- Generated `commands_gen.ml` module name is `Commands_gen`; make sure it
  is in your executable's `modules`.
