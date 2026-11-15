# Trace レイヤー設計計画（非同期Command拡張の次工程）

日付: 2026-11-15
状態: 計画 — ユーザー確認待ち

## 背景

`traceId` は protocol v1 envelope に存在し、JS→OCaml で正しく伝播する
（`observed_trace_id` で実証済み）。しかし「記録」の層がない:

- 現状の trace 関連出力は `log_handler_exception` / `log_decode_exception`
  の stderr JSON 2種のみ。成功経路・cancel・timeout・dispatch のイベントは
  どこにも残らない。
- ロードマップの独自性「JS・OCaml・Workerをまたぐ処理を一つのtraceとして
  追跡する」は、伝播(traceId)まで実装済みで、**記録・集約・照会が未実装**。
- baseline 文書も「trace eventの手動出力」を残存定型処理として挙げ、
  「full trace store/debug viewer」を当時の対象外としていた。
- Usage Monitor のdogfoodingで、非同期Commandの内部で何が起きたか
  （いつhandlerが始まり、cancelはいつ観測され、どのProviderが遅いか）
  を追いたい実需要がある。

## 目的

`traceId` をキーに、request のライフサイクルイベントを統一形式で記録する。
v1は OCaml 側イベントのみ。JS 側イベント取り込みと Worker イベントは
後続フェーズ（Worker レイヤー未実装のため）。

## 検討案

### A. Event model

**推奨: flat event log（span を作らない）**

```json
{"event":"invoke_received","traceId":"...","requestId":"...","command":"usage.refresh","ts":1731700000.123}
{"event":"handler_completed","traceId":"...","requestId":"...","durationMs":1840.2,"outcome":"resolved"}
```

- 各イベントは `{event, traceId, requestId, command, ts, ...}` の flat record。
  既存の `log_handler_exception` と同形。
- span（start/end 対）にしない: cancel/timeout/window close では end が
  発火しない経路があり、対応付け管理が複雑になる。duration は完了イベントの
  フィールドとして持たせる。

イベント種別（v1）:

| event | 発火点 |
|---|---|
| `invoke_received` | binding callback で decode 直後 |
| `invoke_decode_failed` | envelope/payload decode 失敗 |
| `handler_started` | async worker 開始時（同期commandは省略可） |
| `handler_completed` | resolve/reject/無応答return 時、outcome 付き |
| `request_cancelled` | JS cancel受理時（targetRequestId を記録） |
| `request_timeout` | watchdog 発火時 |
| `response_submitted` | raw Call への応答提出時（Queued/Already_completed） |

### B. Storage / sink

**推奨: sink callback + 内蔵 ring buffer**

```ocaml
(* Webui_trace *)
type event = { ... }  (* または Yojson.Safe.t 直渡し *)
type sink = event -> unit
val ring_buffer : capacity:int -> sink * (unit -> event list)
```

- `Bridge.install ?trace:sink`（既定: なし＝イベント生成自体をスキップ、
  オーバーヘッド零）。
- ring buffer は `Webui_trace` が提供する便利実装。アプリはこれを使っても、
  独自 sink（stderr JSON、ファイル、metrics）を差してもよい。
- 現行の `log_handler_exception`/`log_decode_exception` も trace event
  経由へ統合し、stderr 出力は「既定 sink なし時の fallback」か削除かは
  実装時に決める（破壊的変更なら plan 承認時に確認）。

### C. 照会 API

**推奨: v1では debug Command を追加しない**

- ring buffer は OCaml API から読める（アプリが自前の debug Command を
  定義して JS へ返せる）。
- `webui.trace` のような内蔵 Command は v2 検討。Command 名空間の予約と
  アプリ側との衝突回避設計が要るため。

### D. JS 側イベント取り込み

**推奨: v1では対象外**

- renderer での invoke 発行・response 受信時刻は JS 側が持つ情報。
  取り込むには別 report binding（`__ocaml_webui_trace`）が必要で、
  wire surface が増える。request/response envelope 自体に
  requestId/traceId/結果が載るため v1 では OCaml 側だけで
  request 全体像を再構成可能。

### E. 配置

**推奨: 新 library `ocaml-webui.trace`（`lib/trace/`）**

- `Webui_async` と同じ粒度。bridge_atd は `?trace` 引数で sink を受け取る
  だけで、event 型定義と ring buffer は trace lib 側。
- bridge_baseline への backport はしない（baselineは比較基準として凍結）。

### F. traceId の発生源

現状は JS 側 `nextId("trace")` が生成。v1では変えない。
OCaml 側で traceId が欠落/空の場合の扱い（イベントから落とすか
`"unknown"` で記録するか）は実装時に決める。

## スコープ外（v1）

- Worker プロセス/domain をまたぐ trace 継承（Worker レイヤーで対応）
- OpenTelemetry 等外部フォーマット export
- 内蔵 debug Command / trace viewer UI
- JS 側イベント取り込み
- ring buffer の永続化・ファイル吐き出し

## ユーザー確認点

| # | 論点 | 推奨 |
|---|---|---|
| T1 | event model | flat event log（span なし） |
| T2 | sink 方式 | `?trace:sink` opt-in + `Webui_trace.ring_buffer` 提供 |
| T3 | stderr の既存ログ | trace event へ統合して sink 経由にするか、既存 stderr を残すか |
| T4 | 内蔵 debug Command | v1 では作らない（アプリ側が ring buffer を読む形） |
| T5 | 配置 | `lib/trace` 新 library |

## 実装タスク（承認後）

1. `lib/trace` — event 型、sink、ring buffer、（必要なら filter）
2. `webui_bridge_atd` — `install ?trace`、上記イベント発火点へ emit 追加
3. `pending_entry` に invoke 受信時刻を保持し handler_completed の
   durationMs を計算
4. `test/trace` — ring buffer、イベント発火順序、cancel/timeout 経路の
   イベント列を headless 検証
5. async probe への trace sink 組み込みで実機イベント列を確認
6. docs/trace-layer-results.ja.md にゲート証拠
