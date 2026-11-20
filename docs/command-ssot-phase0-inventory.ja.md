# Command SSOT 生成 — Phase 0 棚卸し（2026-11-20）

Context Mixer「OCaml型付きCommand SSOT・bridgeコード自動生成 実装計画」（`doc_1795012068880_6yymbkf3g`）の Phase 0。既存の手書き箇所・重複・ビルド時に検出できない不整合の記録と計測ベースライン。

## 対象コード（計測時点）

- ocaml-webui `3c4cf58`（`lib/bridge_atd`, `lib/command_schema`, `spikes/phase3-atd-command`, `spikes/async-command`）
- ai-usage-monitor `2e0b978`（`usage_refresh.atd`, `bin/main.ml`, `web/client.ts`）

## 1 Command追加で人が触る場所（実測）

例: Usage Monitor `usage.refresh`

| # | 場所 | 手書き内容 | 自動化可能か |
|---|---|---|---|
| 1 | `lib/usage_schema/usage_refresh.atd` | 型定義（schema SSOT — **これ自体は正本として残すか要決定**） | 入力 |
| 2 | `lib/usage_schema/dune` | atdml/atdts rule（`.atd` 1つにつき rule 2本） | 生成 or glob化 |
| 3 | `bin/main.ml` `make_codec` | `input_of_yojson`/`output_to_yojson`/`error_to_yojson` の3関数名をATD生成モジュールから手配線（usage_refresh: L20-24、trace.recent: L113-124） | 型名の命名規則があれば生成可 |
| 4 | `bin/main.ml` `define`/`define_async` | `~name:"usage.refresh"` リテラル + `~timeout_ms` + handler本体（handler本体はアプリ固有 → 生成対象外） | name/mode/timeoutはメタデータから生成可 |
| 5 | `bin/main.ml` `pack` + install list | `[Bridge.pack usage_refresh_command; Bridge.pack trace_recent_command]` | 全Command既知なら生成可 |
| 6 | `bin/dune` copy rule | 生成 `.ts` を web build dir へコピー（`usage_refresh.ts`） | 生成 or glob化 |
| 7 | `web/client.ts` import | `writeUsageRefreshRequest`/`readUsageRefreshResult`/`readUsageRefreshError` を生成モジュールから手 import | 命名規則があれば生成可 |
| 8 | `web/client.ts` `defineCommand` | `"usage.refresh"` リテラル + codec参照 → `usageRefresh` descriptor | 生成可 |
| 9 | `web/App.ts` 等 呼出し側 | `invokeCommand(usageRefresh, ...)`（descriptor参照 — 既に集約済み） | 生成対象外 |

**合計: 1 Command ≈ 8箇所の手書き接点（handler本体・呼出し側を除く）**。

spike（phase3-atd-command）は埋め込みJSがHTML literal内でCommand名を使うため `Printf.sprintf %S` 注入が必要 — 生成側で「埋め込みJSへnameを供給する経路」も考慮対象（実アプリではbundle化されているため低優先）。

## ビルド時に検出できない不整合（現状）

| 不整合 | 検出タイミング | 深刻度 |
|---|---|---|
| OCaml `~name` と TS descriptor `name` の不一致 | 実行時（unknown command） | 高 |
| `pack` を install list に入れ忘れ | 実行時（JS invoke が unknown command で reject） | 高 |
| `define`/`define_async` と TS `invokeCommand` の型不一致（ATD型を別バージョンから import 等） | TS/OCaml 各側は型検査するが、**両側の name 一致だけは実行時** | 中 |
| `timeout_ms` を OCaml 側のみ変更 — TS 側は無関係だが Command の実行モード(sync/async)と JS 側の await 期待は暗黙の一致 | 実行時 | 低 |
| `trace.recent` のような **ATD schema を持たない passthrough Command** — 型なしのためどこにも整合保証がない | 実行時 | 低（debug用途） |

すでに解消済み: Command名リテラルの多重化（descriptor集約 `736c6e4` / `be1aed0`）— name は言語あたり1箇所だが「2言語にまたがる一致」は依然実行時依存。

## wire互換の固定点（生成器が壊してはいけないもの）

- protocol v1 envelope（`{protocol, requestId, traceId, command, payload}` + cancel envelope）— `Webui_bridge_atd.Protocol`
- ATD wire表現: `<json name="camelCase">` field rename、variantの `[tag, payload]` 表現、`option` = `["Some",v] | "None"` — 生成物は atdml/atdts とbit互換必須
- `Error` envelope: `code/message/retryable/category/details`
- category `"protocol"|"internal"|"cancelled"|"timeout"` は application error decode より先に判定（notes #6）

## 現行 ATD パイプライン（Phase 1 の生成器が乗る土台）

```
.atd ──atdml──> *_t.ml/_t.mli (codec + create_* helper)  [dune rule per file]
    └─atdts──> *.ts (write*/read* + types)               [dune rule per file]
                  └─bin/dune copy rule──> web build dir──> esbuild bundle
```

OCaml側 `make_codec` は generated 関数を**名前で**参照する（`usage_refresh_request_of_yojson` 等）。型名→関数名の変換規則は atdml が固定しているため、**型名が分かれば全配線は機械的に生成可能**。

## ベースライン計測（Phase 1 PoCの比較軸）

「`usage.refresh` + `trace.recent` の2 Command」を対象に:

- 手書き接点: OCaml側 3箇所/Command（codec・define・pack）+ TS側 2箇所/Command（import・descriptor）+ dune 1箇所/schema
- `usage.refresh` は ATD型あり、`trace.recent` は passthrough — **passthrough Commandも生成対象に含めるか**は Phase 1 の論点
- 追加で検出したい失敗: name不一致・pack忘れを**ビルドエラー化**できるかが PoC 評価の中核

## Phase 1 への申し送り

1. **Commandメタデータ中間表現**: name / input型 / output型 / error型 / mode(sync|async) / timeout_ms / traceの有無 — ATD or 別manifest から集約
2. **生成対象の確定**: OCaml登録コード（codec+define+pack list）、TS descriptor+import、dune rule
3. **passthrough Commandの扱い**: `unit`入力・raw JSON出力の Command を type-safe に扱えるか（trace.recentが事例）
4. **評価**: 上記ベースラインの8接点→何接点になるか、name不一致/pack忘れがビルド時エラーになるか
5. **Phase 2への接続**: 入力形式は後で差し替える前提。PoCでは「ATD + 小さなmanifest」で進め、PPX/DSL/OCaml→ATD生成の3案比較は別ゲートとする
