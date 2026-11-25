# docs索引

現行仕様・利用ガイドと、設計計画・履歴資料の分類。ファイル内の日付は
計画時点のもので、実装時点ではない。

## 現行リファレンス

| Doc | 内容 |
|---|---|
| [getting-started.ja.md](getting-started.ja.md) / [en](getting-started.md) | ocaml-webuiの利用: `commands.ml` → 生成bridge |
| [commands-manifest.ja.md](commands-manifest.ja.md) / [en](commands-manifest.md) | JSON manifestフィールド（`--manifest`入力、共通の中間表現） |
| [command-ssot-phase2-comparison.ja.md](command-ssot-phase2-comparison.ja.md) | 入力形式3案比較 + 実装された`commands.ml`宣言構文 |
| [command-decl-compile-consideration.ja.md](command-decl-compile-consideration.ja.md) | ペンディング: `commands.ml`のcompile可能化（Merlin/型check）— 問題・選択肢・トレードオフ |
| [dependencies.md](dependencies.md) | 各依存の出所 |
| [webui-raw-binding-design.ja.md](webui-raw-binding-design.ja.md) / [en](webui-raw-binding-design.md) | `Webui_raw`のlifecycle/state machine設計 |

## 計画書・履歴資料

設計判断の記録として残す。現行仕様ではない。

| Doc | 内容 |
|---|---|
| [webui-raw-binding-design.ja.md](webui-raw-binding-design.ja.md) | raw binding設計ドラフト |
| [webui-raw-implementation-status.ja.md](webui-raw-implementation-status.ja.md) | 2026-07-20時点のraw binding状況 — async/trace/worker/resource/exec各層より前 |
| [handwritten-bridge-baseline.ja.md](handwritten-bridge-baseline.ja.md) | 手書きbridgeベースライン（生成経路に置き換え済み） |
| [phase0-packaging.ja.md](phase0-packaging.ja.md) / [phase0-results.ja.md](phase0-results.ja.md) | opamパッケージング計画 + 結果 |
| [command-ssot-phase0-inventory.ja.md](command-ssot-phase0-inventory.ja.md) | 生成前の重複実装ベースライン |
| [async-timeout-cancel-plan.ja.md](async-timeout-cancel-plan.ja.md) | async/cancel/timeout設計 |
| [trace-layer-plan.ja.md](trace-layer-plan.ja.md) | 統一trace設計 |
| [worker-layer-plan.ja.md](worker-layer-plan.ja.md) | Worker層設計 |
| [resource-layer-plan.ja.md](resource-layer-plan.ja.md) | Resource層設計 |
| [exec-layer-plan.ja.md](exec-layer-plan.ja.md) | one-shotプロセス実行設計 |
| [review-scope-phase5-6.ja.md](review-scope-phase5-6.ja.md) | Worker+Resourceレビュースコープ |
| [atd-command-ssot-execution-plan.ja.md](atd-command-ssot-execution-plan.ja.md) | ATD SSOT実行計画 |
| [atd-command-ssot-finalization-plan.ja.md](atd-command-ssot-finalization-plan.ja.md) | ATD SSOT最終化計画 |
| [atd-command-ssot-implementation-review.ja.md](atd-command-ssot-implementation-review.ja.md) | 初回レビュー（指摘修正済み） |
| [atd-command-ssot-followup-review.ja.md](atd-command-ssot-followup-review.ja.md) | フォローアップレビュー（指摘修正済み） |
| [atd-command-ssot-results.ja.md](atd-command-ssot-results.ja.md) | ATD SSOT結果 |
