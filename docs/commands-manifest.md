# commands.json — Command manifest reference

Input to `ocaml-webui.command-gen`. One manifest entry per Command; the
generator emits OCaml registration (`--ocaml`), TypeScript descriptors
(`--ts`), and the canonical runtime client (`--emit-client`).

```
ocaml-webui.command-gen --manifest <json> --ocaml <out.ml> --ts <out.ts> [--emit-client <out.ts>]
ocaml-webui.command-gen --emit-client <out.ts>
```

Schema: `tool/command_gen/command_manifest.atd`.

## Top level

```json
{ "commands": [ <command>, ... ] }
```

## Command fields

| Field          | Type   | Required      | Meaning |
|----------------|--------|---------------|---------|
| `name`         | string | yes           | Wire command name, e.g. `"app.ping"`. Converted mechanically to an OCaml record field and TS export (`app.ping` → `app_ping` / `appPing`). |
| `kind`         | string | default `"atd"` | `"atd"` — typed command backed by atdml/atdts codecs. `"raw_json"` — passthrough: input `unit`, output `Yojson.Safe.t`, error `string` (for debug commands like `trace.recent`). |
| `schemaModule` | string | kind=atd      | OCaml module path containing the atdml-generated codecs, e.g. `"Usage_schema.Usage_refresh"`. |
| `input`        | string | kind=atd      | ATD input type name. Codec functions are derived by the atdml convention: `<input>_of_yojson`, `yojson_of_<output>`, `yojson_of_<error>`. |
| `output`       | string | kind=atd      | ATD result type name. |
| `error`        | string | kind=atd      | ATD typed-error type name. |
| `mode`         | string | default `"sync"` | `"sync"` → `Bridge.define` (handler runs on the dispatch thread). `"async"` → `Bridge.define_async` (handler runs on a worker domain and receives a `cancellation_token`). |
| `timeoutMs`    | int    | async only    | Watchdog deadline in ms. After it the call is rejected `timeout` (retryable); the worker keeps running but its response is discarded. |
| `tsModule`     | string | kind=atd      | Import path for the atdts-generated module in emitted TS, e.g. `"./usage_refresh.js"`. |
| `tsOutputType` | string | kind=raw_json | Name of the TS result type used as the descriptor's `O` parameter. |
| `tsTypeDecls`  | string | kind=raw_json | Raw TS declarations emitted verbatim into `commands_gen.ts` before the descriptor (define `tsOutputType` here). |

## Generated OCaml — what you must provide

`commands_gen.ml` exports:

```ocaml
type handlers = {
  app_ping : Bridge.context -> Schema.ping_request ->
    (Schema.ping_response, Schema.ping_error) Bridge.responder -> unit;
  (* async commands take Bridge.cancellation_token as the last arg *)
  (* raw_json commands take unit input and a (Yojson.Safe.t, string) responder *)
}

val commands : handlers -> Bridge.packed_command list
```

- Every manifest command is a **required record field** — missing a handler
  fails compilation with `Some record fields are undefined: <field>`.
- `commands h` contains every manifest entry — forgetting a `pack` is
  structurally impossible.
- Wire `name`, codecs, `define`/`define_async`, and `timeout_ms` come from
  the manifest; you only write handler bodies.

## Generated TypeScript

`commands_gen.ts` exports one `CommandDescriptor<I, O, E>` const per
command plus `tsTypeDecls` for raw_json entries. It imports codec
functions from `tsModule` and `defineCommand` from `./client.js` — emit
the client (`--emit-client client.ts`) into the same directory.

raw_json descriptors have type `CommandDescriptor<null, tsOutputType, never>`
— invoke with `invokeCommand(descriptor, null)`.

## Protocol version

Emitted clients and generated descriptors speak **protocol v1**:

```json
invoke:   { "protocol":1, "requestId":"..", "traceId":"..",
            "command":"app.ping", "payload":{...} }
response: { "protocol":1, "requestId":"..", "traceId":"..",
            "command":"app.ping", "ok":true, "value":{...} }
          | { ..., "ok":false, "error":{"code","message","retryable","category"} }
cancel:   { "protocol":1, "kind":"cancel", "requestId":"..",
            "traceId":"..", "targetRequestId":".." }
```

`client.js` throws `ProtocolError` on `protocol` mismatch — pinning the
OCaml package and the emitted client together keeps the two in sync.

## Notes / limits

- `kind:"atd"` requires `schemaModule`, `input`, `output`, `error`,
  `tsModule`; `kind:"raw_json"` ignores them and uses `tsOutputType` +
  `tsTypeDecls`.
- Field names in TS types stay snake_case (atdts convention); wire names
  come from `<json name>` annotations in the `.atd`.
- No duplicate detection across `name`s — keep wire names unique.
- Phase 2 (OCaml-declaration SSOT) is future work; the manifest is the
  documented v0.1 path and the intermediate form the next input format
  will generate into.
