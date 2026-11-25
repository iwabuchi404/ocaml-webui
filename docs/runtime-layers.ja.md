# Runtimeレイヤー: trace / async / exec / worker / resource

bridgeの外側にある4層の利用ガイド。これらは組み合わさる: bridgeは
全handlerへ`context`（`trace_id`/`request_id`）と`cancellation_token`
（async Command）を渡し、`exec`/`worker`はその両方を受け取れるため
外部処理が同一trace・同一cancelへ合流する。workerは`resource` scopeへ
自動登録されるため teardown も自動になる。

```
JS invoke ──> bridge ──context(trace_id, request_id)──> handler
                     │                                   ├─ Webui_exec.run  (one-shot CLI)
                     ├─ cancellation_token ──────────────┤
                     │                                   └─ Webui_worker.request (常駐worker)
                     └─ trace sink <── exec_*/worker_*/resource_* イベント
```

## 1. Trace（`ocaml-webui.trace`）

1イベント = 1件のflat `event` record。spanは意図的にモデル化しない
（cancel/timeout/close経路ではend eventが来ないことがあるため、
durationは完了イベントのfieldとして運ぶ）。

```ocaml
let sink, snapshot = Webui_trace.ring_buffer ~capacity:512
(* Bridge.install ~trace:sink window ... — bridgeイベントが流れ込む *)

(* 独自イベントもhandler contextを引き継げば同一traceに合流する: *)
let handler (context : Bridge.context) request responder =
  sink
    (Webui_trace.make ~name:"provider_completed"
       ~trace_id:context.trace_id ~request_id:context.request_id
       ~command:context.command
       ~data:[ "ms", `Float elapsed; "provider", `String name ])
```

- `Webui_trace.stderr_sink` — stderrへ1行1 JSON。
- `ring_buffer ~capacity` — 上限付き・thread-safe。`snapshot ()`は
  古い順で返す。`raw_json` debug Command（`examples/typed-hello`の
  `trace.recent`）で公開すればJS側からtraceを覗ける。
- runtimeがemitするイベント名: bridgeイベントに加え `exec_*`、
  `worker_*`、`resource_*`（各`.mli`に一覧あり）。

## 2. Async（`ocaml-webui.async`）

async Commandのhandlerはworker domain上で動き、`cancellation_token`
を受け取る:

```ocaml
let handler _context (request : Schema.work_request) responder token =
  (* checkpointでtokenをpollする *)
  if Webui_async.is_cancelled token then () (* 応答せずreturn:
                                               bridgeが"cancelled"でreject *)
  else ...
```

- 宣言の`~timeout_ms`はwatchdog — tokenをcancelするだけでdomainは
  killしないので、checkpointでのpollが必須。
- `Webui_async.cancel_reason`は `` `Js_cancel | `Timeout | `Window_close ``。
- `spawn`/`await`、`parallel`、`sleep_ms`もあり、handler内での
  fan-out（複数provider並列照会など — `ai-usage-monitor`参照）に使える。

## 3. Exec（`ocaml-webui.exec`）

one-shotの`spawn → communicate → reap`。CLI起動用。常駐プロセスは
`worker`を使う。

```ocaml
match
  Webui_exec.run
    ~argv:[ cli_path; "--output-format"; "json" ]
    ~stdin:"/usage\n" ~timeout_ms:20_000 ?token
    ~trace:sink ~trace_id:context.trace_id ()
with
| Ok { Webui_exec.status = Webui_exec.Exited 0; stdout; _ } -> parse stdout
| Ok c -> (* 非0終了はerrorではない — 意味はアプリ側が決める *) ...
| Error (Webui_exec.Timeout p) -> (* kill+reap済み。p.stdoutに部分出力 *)
```

- argvはOSへ直接渡す — **shellを経由しない**ので引用・escapeの
  バグもPATH文字列加工も不要。
- timeout/cancel/output超過時は`run`が返る前に子をkill+reapし、
  それまでの部分出力をerror payloadとして返す。
- `~max_output_bytes`はstdout+stderrの上限（既定16 MiB）。
- `~trace`/`~trace_id`で`exec_*`イベントを親traceへ合流させる。

## 4. Worker（`ocaml-webui.worker`）

stdin/stdout上でline-delimited JSON-RPCを話す常駐子プロセス。
requestは数値idで多重化され、reader domainが応答を振り分け、
notificationも転送する。

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

- `request`は`(Yojson.Safe.t, error) result`。`Remote_error`は
  JSON-RPCのerrorオブジェクト。
- `?token`は**待機の放棄** — workerをkillしない。共有の常駐workerでは
  1呼び出しのcancelでプロセスを落とさないための正しい意味づけ。
  強制終了は`kill`。
- `?timeout_ms`はそのrequestだけを失敗させる — workerは生き続け、
  遅れて届いた応答は破棄される（`worker_late_response`イベント）。
- `~restart:(On_crash n)`で予期せぬ終了後に再起動。プロトコルに
  handshake状態がある場合（`initialize`交換等）は`restart_count`の
  変化を監視して再実行する。
- `~scope`でresourceへ登録（既定`App`）— `revoke_scope`やwindow
  teardownで配線不要にkillされる。
- アプリ終了時の`shutdown_all ()`は全live workerをkillし`App` scope
  をrevokeする。

## 5. Resource（`ocaml-webui.resource`）

明示的lifecycleを持つもの全般のregistry — worker、handle、
subscription、一時ファイル。

```ocaml
let conn =
  Webui_resource.register ~kind:"socket" ~name:"metrics"
    ~scope:(Webui_resource.Window window)
    ~release:(fun () -> close fd) ()

Webui_resource.release conn            (* 冪等、1回だけ実行 *)
ignore (Webui_resource.revoke_scope (Webui_resource.Window window))
```

- `App` — 明示的revoke / `Worker.shutdown_all`で解放。
- `Named s` — アプリ定義のグループ（feature単位のteardown、test用）。
- `Window w` — `Webui_raw.Window.on_destroy`経由でwindow destroy時に
  自動解放。`revoke_scope`は**登録の逆順**に解放（依存関係の
  teardown順と一致）。
- `snapshot ()`/`leak_count ()`でリーク診断。`set_trace`で
  `resource_registered`/`resource_released`/`resource_revoked`
  イベントをsinkへ。

## 6. 組み合わせ（実例パターン）

dogfoodingアプリ（AI Usage Monitor）が4層を繋いでいる形:

1. `ring_buffer ~capacity:512`のsink → `Bridge.install ~trace`。
2. `usage.refresh`のasync handlerが`token`を受け取り、provider毎に
   `Webui_exec.run`/`Webui_worker.request`へ渡す — JS cancel、
   watchdog timeout、window closeが外部プロセスまで伝播する。
3. provider workerは`~scope:(Webui_resource.Window window)`でspawnし、
   window closeでkillされる。
4. `provider_completed`独自イベントが`context.trace_id`を引き継ぐため、
   JS `invoke` → handler → providerプロセスまでが`trace.recent`
   debug Commandで1本のtraceとして読める。
