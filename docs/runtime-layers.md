# Runtime layers: trace / async / exec / worker / resource

Usage guide for the four layers beyond the bridge. These compose: the
bridge hands every handler a `context` (`trace_id`/`request_id`) and a
`cancellation_token` (async Commands); `exec` and `worker` accept both
so external work joins the same trace and honours the same cancellation;
workers register themselves into a `resource` scope so teardown is
automatic.

```
JS invoke ──> bridge ──context(trace_id, request_id)──> handler
                     │                                   ├─ Webui_exec.run  (one-shot CLI)
                     ├─ cancellation_token ──────────────┤
                     │                                   └─ Webui_worker.request (persistent worker)
                     └─ trace sink <── exec_*/worker_*/resource_* events
```

## 1. Trace (`ocaml-webui.trace`)

One flat `event` record per occurrence — spans are deliberately not
modelled because cancel/timeout/close paths may never produce an end
event (durations live on completion events instead).

```ocaml
let sink, snapshot = Webui_trace.ring_buffer ~capacity:512
(* Bridge.install ~trace:sink window ... — bridge events flow in. *)

(* Custom events join the same trace by reusing the handler context: *)
let handler (context : Bridge.context) request responder =
  sink
    (Webui_trace.make ~name:"provider_completed"
       ~trace_id:context.trace_id ~request_id:context.request_id
       ~command:context.command
       ~data:[ "ms", `Float elapsed; "provider", `String name ])
```

- `Webui_trace.stderr_sink` — one JSON object per line on stderr.
- `ring_buffer ~capacity` — bounded, thread-safe; `snapshot ()` returns
  oldest-first. Expose it via your own `raw_json` debug Command (see
  `trace.recent` in `examples/typed-hello`) to inspect the trace from JS.
- Event names emitted by the runtime: bridge events plus `exec_*`,
  `worker_*`, `resource_*` (listed in each `.mli`).

## 2. Async (`ocaml-webui.async`)

Async Command handlers run on a worker domain and receive a
`cancellation_token`:

```ocaml
let handler _context (request : Schema.work_request) responder token =
  (* poll the token at your checkpoints *)
  if Webui_async.is_cancelled token then () (* return w/o responding:
                                               bridge rejects "cancelled" *)
  else ...
```

- `~timeout_ms` on the Command declaration acts as a watchdog — it cancels
  the token; it does not kill your domain, so checkpoints are required.
- `Webui_async.cancel_reason` returns `` `Js_cancel | `Timeout | `Window_close ``.
- Also provides `spawn`/`await`, `parallel`, `sleep_ms` for fan-out inside
  a handler (e.g. querying several providers concurrently — see
  `ai-usage-monitor`).

## 3. Exec (`ocaml-webui.exec`)

One-shot `spawn → communicate → reap`. Use for CLI invocations; for a
persistent process use `worker` instead.

```ocaml
match
  Webui_exec.run
    ~argv:[ cli_path; "--output-format"; "json" ]
    ~stdin:"/usage\n" ~timeout_ms:20_000 ?token
    ~trace:sink ~trace_id:context.trace_id ()
with
| Ok { Webui_exec.status = Webui_exec.Exited 0; stdout; _ } -> parse stdout
| Ok c -> (* non-zero exit is NOT an error — app decides *) ...
| Error (Webui_exec.Timeout p) -> (* killed + reaped; p.stdout is partial *)
```

- argv goes to the OS directly — **no shell**, so no quoting/escaping bugs
  and no PATH string munging.
- Timeout/cancel/output-limit kill and reap the child before `run`
  returns; partial output is returned in the error payload.
- `~max_output_bytes` caps stdout+stderr (default 16 MiB).
- Emits `exec_*` events into `~trace`, joined to `~trace_id`.

## 4. Worker (`ocaml-webui.worker`)

A persistent child process speaking line-delimited JSON-RPC over
stdin/stdout. Requests are multiplexed by numeric id; a reader domain
demultiplexes responses and forwards notifications.

```ocaml
let worker =
  match
    Webui_worker.spawn ~name:"codex"
      ~argv:[ "codex"; "app-server"; "--stdio" ]
      ~restart:(Webui_worker.On_crash 1)
      ~scope:(Webui_resource.Window window) ()
  with Ok w -> w | Error _ -> unavailable ()

let result =
  Webui_worker.request worker ?token ~timeout_ms:5000
    ~trace_id:context.trace_id
    ~method_:"initialize" (`Assoc [ "clientInfo", `Assoc [...] ])
```

- `request` returns `(Yojson.Safe.t, error) result`; `Remote_error` is the
  JSON-RPC error object.
- `?token` **abandons the wait** — it does not kill the worker. That is
  the right semantics for a shared persistent worker: one caller's
  cancellation must not take the process down. Use `kill` for forceful
  termination.
- `?timeout_ms` fails only that request; the worker stays alive and a
  late response is discarded (`worker_late_response` event).
- `~restart:(On_crash n)` respawns after unexpected exit. Watch
  `restart_count`: if your protocol needs handshake state (e.g. an
  `initialize` exchange), re-run it whenever the count changes.
- `~scope` registers the worker as a resource (default `App`), so
  `Webui_resource.revoke_scope` or window teardown kills it with no
  extra wiring.
- `shutdown_all ()` at app exit kills every live worker and revokes the
  `App` scope.

## 5. Resource (`ocaml-webui.resource`)

A registry for anything with an explicit lifecycle — workers, handles,
subscriptions, temp files.

```ocaml
let conn =
  Webui_resource.register ~kind:"socket" ~name:"metrics"
    ~scope:(Webui_resource.Window window)
    ~release:(fun () -> close fd) ()

Webui_resource.release conn            (* idempotent, runs once *)
ignore (Webui_resource.revoke_scope (Webui_resource.Window window))
```

- `App` — released at explicit revoke / `Worker.shutdown_all`.
- `Named s` — your own grouping (per-feature teardown, tests).
- `Window w` — released automatically at window destroy via
  `Webui_raw.Window.on_destroy`. `revoke_scope` releases in **reverse
  registration order**, matching dependency teardown.
- `snapshot ()` / `leak_count ()` for leak diagnostics; `set_trace` wires
  `resource_registered`/`resource_released`/`resource_revoked` events.

## 6. Composing them (real pattern)

The AI Usage Monitor dogfooding app threads all four:

1. `ring_buffer ~capacity:512` sink → `Bridge.install ~trace`.
2. `usage.refresh` async handler gets `token`; passes it to
   `Webui_exec.run` / `Webui_worker.request` per provider — JS cancel,
   watchdog timeout, and window close propagate into external processes.
3. Provider workers are spawned `~scope:(Webui_resource.Window window)`
   so closing the window kills them.
4. `provider_completed` custom events reuse `context.trace_id`, so the
   JS `invoke` → handler → provider process spans read as one trace in
   the `trace.recent` debug Command.
