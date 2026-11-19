# Exec レイヤー設計計画（one-shot プロセス実行）

日付: 2026-11-17
改訂: 2026-11-19（レビューとスコープ見直しを反映）
状態: 計画 — 最小スコープへの修正をユーザー確認済み。内部方式は検証後に決める

## 背景

Worker supervisor v1（常駐 NDJSON/JSON-RPC multiplex）で「長寿命・双方向」の
外部プロセス境界は確立した。しかし Usage Monitor の残り provider は別形態:
**fetch 毎に spawn → stdin/stdout を一括交換 → reap** する one-shot 実行で、
Claude / OpenCode が独自実装を抱えている。

### dogfooding の実需要（実コード計測）

| provider | 現状実装 | 問題 |
|---|---|---|
| claude | `cmd /c "type tmpfile \| claude.exe ..."` を `open_process_in`、temp file 経由で stdin 回避 | **timeout なし**（Command の応答を打ち切っても、裏の取得処理は残る）、cancel なし、stderr を分離取得していない、シェルクォート依存 |
| opencode | `opencode db "..." --format json` を `open_process_in` + `Buffer.add_channel` ループ | 同上。timeout なし、exit status 未確認 |
| codex | `Webui_worker`（常駐・multiplex） | 解決済み |
| antigravity | localhost HTTP | 対象外 |
| devin | ファイル読み | 対象外 |

共通するボイラープレート: spawn → stdin 書込 → EOF → stdout 読み切り →
close_process。これに timeout・cancel・stderr capture・出力上限を全
provider で重複実装するのは Worker 化前の codex（~130行 select loop）と
同じ構造的問題。

## 目的とスコープ

**v1 = Claude / OpenCode の取得が固まっても処理を打ち切れる、小さな
one-shot 実行 API。spawn → communicate → reap を1回の `run` にまとめ、
argv 直接渡し、stdin、stdout/stderr、終了状態、timeout/cancel、出力上限を提供する。**

既存の Async・Worker・Resource・Trace の実アプリ適用を進める工程として扱う。
汎用プロセス基盤の完成や後続ロードマップの順序確定は、この工程の目的に含めない。
trace は既存 sink への少数イベントで対応する。

Worker の request-level cancel は待機解除のみだが、Exec の cancel は
直接起動した子プロセスの終了を伴う。token と trace の仕組みは再利用する。

`Webui_worker`（常駐・多重化・restart）とは別モジュール。重複実装ではなく
「同じ失敗境界モデルの別形態」として位置づける。

```ocaml
(* 検討中の API イメージ *)
type exit_status = Exited of int | Signaled of int | Stopped of int

type completed = {
  status : exit_status;
  stdout : string;
  stderr : string;
  duration_ms : float;
}

type partial = { stdout : string; stderr : string }

type error =
  | Spawn_failed of string
  | Timeout of partial      (* deadline到達→kill。部分出力付き *)
  | Cancelled of partial    (* token発火→kill。部分出力付き *)
  | Output_exceeded of partial  (* max_output_bytes超過→kill *)
  | Io_error of string

val run :
  argv:string list ->
  ?stdin:string ->
  ?timeout_ms:int ->
  ?token:Webui_async.cancellation_token ->
  ?max_output_bytes:int ->   (* stdout + stderr 合計。default 16 MiB *)
  ?trace:Webui_trace.sink -> ?trace_id:string ->
  unit -> (completed, error) result
```

### 終了保証と内部方式の検証

- **保証対象**: 直接起動した子を timeout/cancel/出力超過時に終了・回収し、
  所有する pipe と I/O 処理を後始末して返る。I/O エラーや例外時も同じ後始末経路を使う。
  子孫プロセスの一括終了や、アプリの強制終了後まで含めた「孤児なし」は保証しない。
- **timeout**: `run` 開始を基準に、送信待ち・読み取り・終了待ちを対象にする。
  timeout/cancel 後の I/O 停止・回収待ちが無期限にならない方式を先に確認する。
  deadline 到達時刻と、後始末を終えて返る時刻は区別する。
- **I/O**: stdin の書き込みが詰まっても stdout/stderr の読み取りと
  timeout/cancel の観測が進むこと。stdin 未指定時も子へ EOF を伝える。
  stdout だけを先に読み切るなど、stderr の pipe 詰まりを起こす方式は避ける。
- **終了状態の所有者**: wait/reap を行う主体を一つに定め、取得済みの終了状態を保持する。
  `waitpid WNOHANG` 自体も reap し得るため、単なる生存確認としてコピーしない。
- **最初の小さな検証**: Windows/Linux で stdin 詰まり、大量 stderr、
  timeout/cancel 中の回収、子孫が pipe を保持した場合の I/O 終了を確認する。
  子孫の kill は対象外でも、その EOF 待ちで `run` が戻れなくならないことを確認する。
  成立しなければ、検証結果と対応可能な範囲を整理してから本実装へ進む。
- **内部構成は未確定**: stdin writer / stdout reader / stderr reader の
  3 Domain + poller は候補の一つ。Domain・Thread・polling の選択は検証で決め、
  公開 API の契約にしない。`Unix.open_process_args_full` も実装候補として扱う。
- **SIGPIPE**: 死んだ子への stdin 書き込みで親が終了しないよう扱う。
  Worker の実装を参考にしつつ、signal 設定がプロセス全体へ及ぶことを考慮する。
- **出力上限**: stdout + stderr の保持する生バイト数の合計を既定16 MiBに制限する。
  超過分を蓄積せず、子を終了して `Output_exceeded` を返す。partial も同じ上限内とする。
  上限判定の同期は必要だが、高度なメモリ予算管理は作らない。
- **trace**: 起動・終了・打ち切り理由を既存 sink に記録し、`?trace_id` で
  親 Command へ連結する。イベント名・項目は既存 Trace に合わせて最小限に定める。

### Resource との関係

v1 では公開 `?scope` や resource registry 統合を必須にしない。
`run` 内の後始末を基本とし、Usage Monitor では Command の token を Exec まで渡す。
Window close 由来の cancel も、アプリが実行中で token を観測できる間に処理する。
アプリ終了までに全 Exec の後始末が完了する保証は、今回の完了条件に含めない。

アプリ終了時の待ち合わせや一括 cleanup が実際に必要になった時点で、
既存 Resource の利用も含めて判断する。非登録を将来の制約として固定しない。

## 検討案と推奨

| # | 論点 | 推奨 |
|---|---|---|
| E1 | `ocaml-webui.exec` 独立 library | 推奨。Worker と用途が別。共通 process 基盤の設計・抽出を先行させず、必要な小さな内部重複は許容する |
| E2 | stderr 分離 capture（merge しない） | 推奨。stdout を parse する provider で stderr が混ざると壊れる。診断用に別保持 |
| E3 | nonzero exit は `Ok completed` 側 | 推奨。exit code の解釈は provider 依存（grep 的な exit1=正常もある）。失敗境界は spawn/timeout/cancel/io/output 超過のみ |
| E4 | timeout/cancel 時は直接の子を猶予なし kill + partial 出力を error に同梱 | 推奨。ハングを打ち切る。Worker の request-level cancel（待機解除のみ）とは区別する |
| E5 | stdout + stderr 合計の `max_output_bytes` 既定 16 MiB、超過で kill+`Output_exceeded` | 推奨。実行中の出力蓄積を制限する。partial も上限内に保持 |
| E6 | シェル非経由・argv 直渡しのみ | 推奨。`open_process_in` の cmd 文字列クォート問題と claude temp file ハックを根絶。stdin は `~stdin` で直接供給 |
| E7 | v1 で streaming 出力 callback は作らない | 推奨。one-shot の実需要は一括取得のみ。`?on_stdout_chunk` は需要が出てから |

## 実装タスク（承認後）

1. 上記の小さな終了方式検証を行い、I/O 停止・回収方法を決める。
2. `lib/exec` — `webui_exec.ml` / `.mli`（`ocaml-webui.exec`）。
   argv 直接渡し、stdin、stdout/stderr、終了状態、timeout/cancel、出力上限、最小 trace。
3. `test/exec` — headless helper による echo roundtrip / stdin EOF /
   stdin 詰まり時の timeout・cancel / stderr 分離 / 合計出力上限 /
   nonzero exit / spawn failed / partial / trace と後始末の検証。
   最初の検証で採用方式の成立条件を確認したケースも、必要な回帰テストとして残す。
4. Usage Monitor の Claude / OpenCode を `Webui_exec.run` へ移行。
   temp file を除去し、`fetch_usage ?token` と main の provider 配線を通して
   Command の token を渡す。provider の timeout は Command の30秒より短く設定する。
5. 下記の最小完了条件を確認し、結果と残った制限を本書へ追記する。
   Context Mixer への決定・発見の記録や関連ページの連鎖更新は、
   AGENTS.md に従ってユーザー確認後に行う。実装前の検討案を確定仕様に書かない。

### 最小完了条件と後続の判断

- Claude / OpenCode の正常取得が維持される。
- ハングした provider は timeout で終了し、他 provider の取得結果を返せる。
- token による cancel で直接の子と I/O 処理を後始末し、その後の再取得が正常に動く。
- stdout/stderr の分離、合計出力上限、親 Command との trace ID 連結が機能する。

Window close とアプリ終了の競合を網羅する試験、shutdown 統合は後続候補とする。
今回の結果から必要性を判断し、完了条件を際限なく広げない。
Command 自動生成など他の改善との優先順位も、移行後に残った不便を見て判断する。
Exec の次工程を、この計画で固定しない。

## 明示的に v1 外とするもの

- 常駐・双方向プロトコル（→ `Webui_worker` の領域）
- streaming 出力 callback（E7）
- process group / 子孫プロセスの一括 kill（Windows job object 等は別設計）
- 公開 `?scope` と resource registry 統合、アプリ終了時の全 Exec 待ち合わせ
- 共通 process 基盤の先行設計、pool、同時実行数制限
- shell コマンド文字列 API（必要になった時点で別途設計する）
