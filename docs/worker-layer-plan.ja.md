# Worker レイヤー設計計画（Phase 5 前半）

日付: 2026-11-16
状態: 計画 — ユーザー確認待ち

## 背景

設計構想 v1 の Phase 5: 「stdin/stdout framed protocol、worker supervisor、
restart、timeout、cancellation、trace propagation」。async/token/trace の
基盤が揃ったため着手可能になった。

### dogfooding の実需要

Usage Monitor の Codex provider は fetch 毎に
`Unix.open_process "codex app-server --stdio"` → initialize handshake →
rateLimits/read → kill を繰り返す。常駐 worker にできれば handshake コストを
償却できる（context にも「Codex app-serverを常駐させたい → resource
lifecycleを検討」と記録済み）。

## 目的とスコープ

**v1 = 外部プロセス Worker の supervisor。** OCaml 側コードを worker
プロセスへ逃がす `~execution:Worker` ルーティングは v2 以降。

```ocaml
(* 検討中の API イメージ *)
type worker

val spawn :
  name:string -> argv:string list -> ?restart:restart_policy ->
  ?trace:Webui_trace.sink -> unit -> (worker, Error.t) result

val request :
  worker -> ?trace_id:string -> method_:string ->
  params:Yojson.Safe.t -> ?timeout_ms:int ->
  (Yojson.Safe.t, worker_error) result

val kill : worker -> unit
val is_alive : worker -> bool
```

- **framing**: NDJSON（行区切り JSON-RPC）。Codex app-server がこの形式。
  LSP 式 Content-Length は後から追加可能な `?framing` 引数にする。
- **多重化**: 読み取り専用の reader domain が stdout を1行ずつ読み、`id`
  一致で pending request へ配送。notification（id 無し）は
  `?on_notification` callback へ（既定: 捨てる）。
- **cancel**: cancel = kill。worker プロセスを殺すのが外部プロセスへの
  唯一の強制手段であり、「協調 cancel が効かない相手」への明確な答え。
  in-flight request は `worker_killed` で reject。
- **restart**: `Never | On_crash of max_restarts:int`（v1は backoff なし）。
  reader domain が EOF/exit を検出 → pending request を全て
  `worker_crashed` で reject → policy に従い再起動。restart 後の request は
  新プロセスへ。
- **trace**: `worker_spawned`, `worker_exited`, `worker_restart`,
  `worker_request`, `worker_response`, `worker_killed` イベント。
  request 呼出側が `?trace_id` を渡せば親 Command の trace に連なる。

### Resource との関係（Phase 6 への橋渡し）

worker instance は「寿命を持つリソース」の最初の実例。v1では
**アプリ scope の registry** のみ: `Webui_worker.shutdown_all`（または
`Registry` 型）が生存 worker を列挙・kill する。設計構想 §15 の
Window/Command scope への紐付けは、Window 側の resource ownership 設計と
合わせて後続フェーズで行う。

## 検討案と推奨

| # | 論点 | 推奨 |
|---|---|---|
| W1 | v1 は外部プロセス supervisor のみ | 推奨。同exe OCaml worker は fault isolation 設計が別途要るため分離 |
| W2 | framing は NDJSON から開始 | 推奨。`?framing` 拡張点を残す |
| W3 | cancel = kill（協調 cancel frame は送らない） | 推奨。外部プロセスへの唯一の強制手段。文書化する |
| W4 | restart = `Never \| On_crash max_restarts` | 推奨。backoff は v1 対象外 |
| W5 | `~execution` Command ルーティングは作らない | 推奨。handler が `Webui_worker.request` を直接呼ぶ形 |
| W6 | pool は1 handle = 1 process | 推奨。pool > 1 は需要が出てから |

## 実装タスク（承認後）

1. `lib/worker` — spawn/reader domain/pending map/kill/restart/shutdown_all
2. `test/worker` — headless テスト用の echo helper（`Unix.open_process` で
   自前 NDJSON echo プロセス、または `ocaml` インタプリタ経由の script）
   で request/response・timeout・kill・restart・exit検出を検証
3. Usage Monitor への適用: codex_provider を `Webui_worker` 常駐化へ移行
   （handler 内で worker request を発行、app 終了時に shutdown_all）
4. `docs/worker-layer-results.ja.md` にゲート証拠

## スコープ外（v1）

- `~execution:Worker` の Command ルーティング・worker 側 codegen
- Window/Command scope の resource 紐付け（Resource レイヤー）
- pool > 1、起動 backoff、LSP framing、stdin/stdout 以外の transport
- worker 内から OCaml → JS への Event（push）
