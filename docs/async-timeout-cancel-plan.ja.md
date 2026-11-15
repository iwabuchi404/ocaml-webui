# 非同期実行・timeout・cancel 設計検討（計画書）

日付: 2026-11-15
状態: ユーザー確認済み（2026-11-15）→ 実装中
関連: `docs/phase0-results.ja.md`、Command SSOT仕様（Context Mixer `spec/`）

## 1. 目的

`Webui_bridge_atd` の Command handler は現在 UI thread 上で同期的に実行される。
長時間処理を行いたいアプリ（Usage Monitor の6 Provider取得など）は、
handler 内で `Thread.create` を自前で行い、responder をワーカーから resolve する
回避策を取っている。

本計画は以下を runtime 側の機能として提供する:

- handler のワーカー実行（UI thread を塞がない）
- cooperative cancel（JS → OCaml、window close → OCaml の伝搬）
- per-command timeout（無限 pending の防止）
- 並列実行の補助（provider fan-out 相当）

ロードマップ上の正式 Worker/Resource レイヤーは別フェーズであり、
本計画はその前段の最小APIとして設計する。

## 2. 現行モデルと制約

### 2.1 実行モデル（現状）

```text
JS: ocamlWebui.invoke(command, payload)
  -> __ocaml_webui_invoke (native binding)
  -> UI thread: Bridge.invoke
       decode_request_json -> registry lookup -> input_of_yojson
       -> handler ctx input responder        ← ここが同期・UI thread
  -> responder_resolve/reject (Call.resolve_json: thread-safe,
       任意スレッドから呼べる。owner thread へ dispatch 配送)
```

- `Call.resolve_json` / `reject_json` / `cancel` は thread-safe で one-shot
  （Atomic CAS。重複応答・close後の late response は `Already_completed`）
- responder は値として保持できるため、handler が spawn した worker から
  resolve する手順は既に可能。欠けているのは「runtime が面倒を見る」層のみ

### 2.2 制約

- **raw 意味論凍結**: `Webui_raw` の公開契約変更はユーザー判断が先。
  本計画で raw 側に必要な追加は §6.2 に列挙し、未実装のまま提示する
- **Eio/Lwt 統合は対象外**: スレッド/Domain + Atomic の最小構成で実装する
- `category=protocol/internal` は application decode より先に判定する規則を維持
- handler 例外は sanitized `internal_error`（WebView へ内部情報を漏らさない）
- Command SSOT: 新しい wire フィールドは protocol v1 拡張として後方互換にする

### 2.3 Usage Monitor 由来の要件（実測需要）

| 要件 | 現状の問題 |
|---|---|
| 並列 provider 取得 | 1 worker thread 内で順次実行 → 3〜5秒 |
| per-provider timeout | provider が固まると refresh 全体が無限 pending |
| refresh の cancel | 再クリックや close で実行中処理が残る |
| worker lifecycle | `Thread.create` detach、shutdown 時に join しない |
| 部分失敗 | schema 側で吸収済み（runtime 対応不要） |

## 3. 設計案

### 3.1 `define_async` — ワーカー実行 Command

```ocaml
val define_async :
  ('input, 'output, 'error) codec ->
  name:string ->
  ?timeout_ms:int ->
  (context -> 'input -> ('output, 'error) responder ->
   cancellation_token -> unit) ->
  ('input, 'output, 'error) command
```

- `define` は変更せず（同期 handler、後方互換）
- `define_async` の handler は runtime が spawn した worker thread で実行
- `cancellation_token` を handler へ渡し、協調 cancel を可能にする
- handler が responder へ書く前に戻っても pending のまま残る現行セマンティクスは
  維持するが、async handler では「return しても応答なし」を silent hang にしない:
  worker 終了時に未応答なら `internal_error` で自動 reject（検討事項 D1）

### 3.2 cancellation token（協調 cancel）

```ocaml
type cancellation_token   (* Atomic.t ラップ + 原因 *)

val token_is_cancelled : cancellation_token -> bool
val token_reason       : cancellation_token -> [ `Js_cancel | `Timeout | `Window_close ] option
```

- cancel は「処理の中断」を強制しない（OCaml thread には強制中断手段がない）
- handler は checkpoint で `token_is_cancelled` を確認し、自分で後始末して return
- cancel 後の responder_resolve/reject は one-shot により `Already_completed`
  になるため安全

### 3.3 wire protocol 拡張: cancel メッセージ

request envelope と同じ `__ocaml_webui_invoke` binding 経路に
`kind:"cancel"` を追加（後方互換: `kind` 省略時は `"invoke"` 扱い）:

```json
[{"protocol":1,"kind":"cancel","requestId":"req-...","traceId":"tr-..."}]
```

- OCaml 側で pending call registry（`requestId -> (responder, token)`）を
  bridge が保持し、cancel メッセージで token を set + call を reject
- cancel メッセージ自体には即時 ack を返す:

```json
{"protocol":1,"requestId":"cancel-...","ok":true,"value":{"cancelled":true}}
```

  （既に完了済みなら `{"cancelled":false}`。エラーにはしない）

### 3.4 cancel された call の応答

JS の元 promise は reject:

```json
{"ok":false,"error":{"code":"cancelled","message":"request cancelled","retryable":false,"category":"cancelled"}}
```

- `category` は新値 `"cancelled"`（protocol/internal/application の第4分類）
- 検討事項 D2（`category:"cancelled"` vs `"protocol"`）

### 3.5 timeout

- `?timeout_ms` 指定時、call 単位の watchdog thread を spawn:
  `Unix.sleepf` 後、未完了なら token に `` `Timeout `` を set し reject:

```json
{"ok":false,"error":{"code":"timeout","message":"command timed out","retryable":true,"category":"internal"}}
```

- one-shot により worker の遅延完了は安全に捨てられる
- 実装コスト: call あたり最大2 thread（worker + watchdog）。
  Command 実行はユーザー操作粒度であり許容範囲と判断。
  高頻度化するなら共有 scheduler thread（heap 管理）へ Worker レイヤーで置換
- `category` 候補: `"internal"` 推奨（timeout は infra 側の打ち切り）。
  検討事項 D3

### 3.6 JS client API

`invoke` は互換維持。cancel 可能な呼び出しは新エントリ:

```javascript
const handle = ocamlWebui.invokeHandle("usage.refresh", {});
// handle.promise: Promise<result>   （cancel/timeout で reject）
// handle.cancel(): Promise<{cancelled: boolean}>  （ack を await 可能）
```

内部実装:

```javascript
invokeHandle(command, payload, options = {}) {
  const requestId = options.requestId || nextId("request");
  const traceId = options.traceId || nextId("trace");
  const promise = globalThis.__ocaml_webui_invoke(
    { protocol: 1, requestId, traceId, command, payload });
  const cancel = () => globalThis.__ocaml_webui_invoke(
    { protocol: 1, kind: "cancel", requestId, traceId });
  return { promise, cancel };
}
```

### 3.7 `Webui_async` 補助モジュール（アプリ向け汎用プリミティブ）

provider fan-out などアプリ側の並列処理用:

```ocaml
module Webui_async : sig
  type 'a task
  val spawn    : (unit -> 'a) -> 'a task
  val await    : 'a task -> 'a                 (* join + 例外再送出 *)
  val parallel : (unit -> 'a) list -> 'a list  (* fan-out + join-all *)
  val parallel_results : (unit -> 'a) list -> ('a, exn) result list
    (* 部分失敗を result 列として返す *)
end
```

- `parallel_results` は Usage Monitor の「1 provider 失敗でも他は返す」を直接支える
- task は `Domain.spawn`（または `Thread.create`）ベース。`threads.posix` 依存は
  raw が既に持つため追加依存なし
- bridge 内部実装にもこのモジュールを使う（SSOT）

### 3.8 window close → cancel 伝搬

- raw 層は pending Call を close 時に既に cancel する
- bridge は pending registry を持つため、close 検出後に token へ `` `Window_close ``
  を set したい。ただし **raw 側に cancel 通知/状態照会がない**ため、
  現状では JS cancel と timeout のみ token 化し、window close 時の token 伝搬は
  raw API 追加（§6.2）待ちとする案を提示する
- token 未伝搬でも worker の resolve は `Already_completed` で安全に捨てられる
  （worker が走り続けるだけであり正確性には影響しない）

## 4. スコープ外

- 強制中断（thread kill、domain 強制停止）
- Worker pool / 同時実行数制限 / backpressure → Worker レイヤー
- OCaml → JS Event（push 通知）→ 別検討（cancel は JS→OCaml 方向のみ）
- Eio/Lwt への抽象化レイヤー
- capability/scope（凍結中）

## 5. 検証計画

- headless test（runtest 対象、Window 不要）:
  - cancel メッセージ decode（kind 省略時の後方互換含む）
  - timeout envelope（code/category/retryable）
  - token の set/チェック、`Already_completed` 遷移
  - `parallel_results` の部分失敗
- 手動 probe（`dune exec`、実 Window）:
  - async handler が UI thread を塞がないこと（blocking 中に別 Command 可）
  - JS cancel → worker checkpoint 停止 + `Already_completed`
  - timeout 発火 → worker 継続・応答破棄・UI に timeout error
  - window close → pending async worker の残留なし（Diagnostics roots=0）

## 6. ユーザー確認結果（2026-11-15 確定）

### 6.1 決定事項

| # | 論点 | 決定 |
|---|---|---|
| D1 | async handler が未応答で return した場合 | **`internal_error` で自動 reject**（silent hang 防止） |
| D2 | cancel の category | **`"cancelled"` を新設**（第4分類） |
| D3 | timeout の category | **`"timeout"` を新設**（第5分類） |
| D4 | JS timeout | **`invokeHandle` に `timeoutMs` option を提供**（client-side reject + cancel 送信） |
| R1 | `Call.is_cancelled : t -> bool` | **追加を許可**（凍結契約に1関数追加。close 由来 cancel の token 伝搬に使用） |
| R2 | call-cancel 通知 hook | 不採用（R1 の状態照会で十分） |
| P1 | `Webui_async` の置き場 | **新 library `ocaml-webui.async`**（bridge 依存を増やさずアプリから直接利用可） |
| P2 | pending call registry | **bridge_atd 内部**（install 時生成） |

## 7. 実施順序（案）

1. `Webui_async`（spawn/await/parallel_results）+ headless test
2. `define_async` + worker spawn + 未応答 reject（D1 結果で確定）
3. wire `kind:"cancel"` decode + pending registry + JS `invokeHandle` + token 伝搬
4. `?timeout_ms` watchdog + cancel/timeout envelope test
5. spike で E2E（blocking 中の別 Command、cancel、timeout、close cleanup）
6. Usage Monitor へ適用（並列 provider + timeout + cancel）で dogfooding 検証
