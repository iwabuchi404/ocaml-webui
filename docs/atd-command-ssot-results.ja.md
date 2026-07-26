# ATD Command SSOT 実装結果

## 概要

ATD (Abstract Type Definition) を用いた Command Single Source of Truth (SSOT) 実装の結果報告。
初回レビュー指摘 (P1×3, P2×3) およびフォローアップレビュー指摘 (P1×4, P2×2) を修正後の状態で、
baseline (`Webui_bridge_baseline`) との定量比較、および採否判断を記載する。

## 判定

**Windows Gate F通過（finalization後clean checkout）。WSLg/Linuxは未検証。ATD payload SSOTを採用する。**

- wire互換性: application errorがbaselineと構造同一
- 否定テスト: `expect_raises` helperで退行を検出可能
- TypeScript typed client: `defineCommand` + generated codec + `@ts-expect-error` compile contract
- codegen→bundle pipeline: cross-platform esbuild JS API wrapper、Dune target化
- runtime bundle依存: `bundle_embed.ml`生成により`dune exec`単独で成功
- frontend生成物: Dune build context内に集約、source tree汚染なし (`mode promote`廃止、gitignore個別規則なし)
- error分類: `category=protocol/internal`をapplication decodeより先に判定
- handler例外: `Exit`を含む全例外を`internal_error`へsanitized
- Windows E2E: 全シナリオ通過、roots=0
- WSLg: 未検証 (Linux環境必要)

### Bootstrap前提

frontend pipelineは`npm ci`を前提とする:

```text
cd web/phase3-atd-command
npm ci
```

以降のDune build/test/execは`node_modules`が存在する前提で動作する。

## 実装サマリ

| 項目 | 結果 |
|------|------|
| 採用generator | `atdml 4.2.0` (OCaml) + `atdts 4.2.0` (TypeScript) |
| 不採用 | `atdgen 4.2.0` (`atdgen-runtime`外部依存・2組の生成物・polymorphic variant) |
| schema場所 | `lib/command_schema/text_analyze.atd` |
| OCaml生成物 | `text_analyze.ml/mli` (atdml, inlined runtime, Yojson依存のみ) |
| TS生成物 | `text_analyze.ts` (atdts, self-contained) |
| Dune rule | `(rule (targets text_analyze.ml text_analyze.mli) ...)` + `(rule (target text_analyze.ts) ...)` |
| 新規ライブラリ | `ocaml-webui.command-schema`, `ocaml-webui.bridge-atd` |
| TS typed client | `client.ts` (defineCommand, invokeCommand, ApplicationError, ProtocolError) |
| TS probe | `probe.ts` (self-executing IIFE, 6シナリオ) |
| テスト | `ocaml_codec_test`, `atd_protocol_test`, `wire_parity_test`, `ts_codec_test`, `type_contract_test`, Phase 3 spike E2E |

## Phase 0: Generator比較結果

| 項目 | atdml 4.2.0 | atdgen 4.2.0 | atdts 4.2.0 |
|------|-------------|--------------|-------------|
| 生成物 | `text_analyze.ml/mli` (1組) | `_t.ml/mli` + `_j.ml/mli` (2組) | `text_analyze.ts` |
| runtime dependency | Yojsonのみ | `atdgen-runtime`必要 | なし (self-contained) |
| variant型 | plain OCaml variant | polymorphic variant | discriminated union |
| API | `of_yojson`/`to_yojson` | `of_string`/`string_of` (streaming) | `read*`/`write*` |
| inlined runtime | あり | なし(外部runtime) | あり |
| wire JSON | `{delayMs:...,observedTraceId:...}` ✓ | 同じ ✓ | 同じ ✓ |

**決定: `atdml + atdts`を採用。** 理由:
- atdmlはYojsonのみに依存し、`atdgen-runtime`が不要
- 単一の`.ml/.mli`生成でDune ruleが単純
- plain variantがtyped bridgeへ自然に接続できる
- atdtsはself-containedでWebView埋め込みに適する

## Phase 1: Golden Fixture / Wire契約

### Fixture
- `test/command_schema/fixtures/request-valid.json`: `{"text":"hello typed bridge","delayMs":50}`
- `test/command_schema/fixtures/result-valid.json`: `{"bytes":18,"words":3,"observedTraceId":"trace-success"}`
- `test/command_schema/fixtures/error-valid.json`: `{"code":"empty_text","message":"text must not be empty","retryable":false,"category":"validation"}`

### 検証項目
- round-trip (request/result/error): OCaml・TypeScript両方で成功
- decode failures: missing field, wrong type, unknown variant — 両方で例外発生
- variant wire strings: `empty_text`, `invalid_delay`, `invalid_text`, `invalid_payload` — 両方で一致
- unknown field tolerance: 追加フィールドは無視され、既知フィールドは正常抽出
- malformed native result/error rejection: null, wrong type, unknown code — 両方で例外発生

## Phase 2: Reproducible Codegen

### Dune rules
```dune
;; lib/command_schema/dune
(rule
 (targets text_analyze.ml text_analyze.mli)
 (deps text_analyze.atd)
 (action (run atdml text_analyze.atd)))

(rule
 (target text_analyze.ts)
 (deps text_analyze.atd)
 (action (run atdts %{deps})))
```

- `dune clean && dune build @all`: 成功
- 生成物は`_build/`内のみ、ソースツリーに漏出なし
- `opam lint`: 既存warningのみ (homepage/license — ATD追加による新規warningなし)

## Phase 3: Typed OCaml Command Integration

### `Webui_bridge_atd` API

```ocaml
(* codec record — ATD生成関数を直接参照 *)
type ('input, 'output, 'error) codec = {
  input_of_yojson : Yojson.Safe.t -> 'input;
  output_to_yojson : 'output -> Yojson.Safe.t;
  error_to_yojson : 'error -> Yojson.Safe.t;
}

(* typed responder — handlerはJSONを直接構築しない *)
val responder_resolve : ('output, 'error) responder -> 'output -> ...
val responder_reject : ('output, 'error) responder -> 'error -> ...

(* GADT command — 型安全なcommand登録 *)
type ('input, 'output, 'error) command
type packed_command
val define : ... codec -> name:string -> handler -> command
val pack : command -> packed_command
val install : Window.t -> commands:packed_command list -> (t, install_error) result
```

### baselineとの違い
- **payload decode**: baseline = 手書き`List.assoc_opt` → ATD = 生成された`of_yojson`
- **response encode**: baseline = 手書き`Assoc`構築 → ATD = 生成された`to_yojson`
- **型安全性**: baseline = `Yojson.Safe.t`のまま渡す → ATD = `text_analyze_request`等の具象型
- **error型**: baseline = 文字列で`code`を指定 → ATD = `text_analyze_error_code` variantで型安全

### wire互換性 (Step 1修正後)
- `responder_reject`はATD生成error JSONをtop-level `error` fieldへ直接出力
- `Protocol.failure_json_raw`を追加、`details` wrapperなし
- baseline error fixtureとATD error fixtureの構造比較: `wire_parity_test`で検証

### E2Eテスト結果 (Windows / WebView2, generated TypeScript bundle経由)
```
atd_bridge: passed success validation unknown handler_error duplicate cancel malformed roots=0
```

検証シナリオ:
- success: typed resolve → `{bytes:18, words:3, observedTraceId:"trace-success"}`
- validation error (empty text): `error.code = empty_text`, `error.category = validation`
- validation error (invalid delay): `error.code = invalid_delay`, `error.category = validation`
- unknown command: protocol error `unknown_command`
- handler exception (failwith): internal error `internal_error`
- handler exception (Exit): internal error `internal_error` (swallowedされない)
- malformed payload: ATD decode failure → `invalid_payload`, `category = protocol`
- duplicate response: `Already_completed` で拒否
- cancel while pending: `Already_completed` で拒否
- resource cleanup: `roots=0` (binding + report binding = 2 → destroy後 0)

## Phase 4: TypeScript Typed Client Integration

### 成果物
- `client.ts`: `defineCommand<I,O,E>`, `invokeCommand`, `ApplicationError`, `ProtocolError`
- `textAnalyze` descriptor (client.ts内): Command名とgenerated codec参照のみ
- `probe.ts`: self-executing IIFE, 7シナリオ (handler Exit含む)
- `type_contract_test.ts`: `@ts-expect-error` によるcompile-time型契約
- `ts_codec_test.ts`: round-trip, decode failure, variant wire, unknown field, malformed rejection, error classification (mocked ProtocolError/ApplicationError)

### 検証結果
- `tsc --strict --noEmit`: 成功
- `npm test` (esbuild + node): 成功 (error classification test含む)
- `npm run bundle` (esbuild IIFE): 成功 (cross-platform JS API wrapper経由)
- Dune ruleで `probe.bundle.js` を `_build/` に生成
- `bundle_embed.ml`生成によりOCaml spikeがbundleをcompile-time埋め込み (`%S` escape安全化)
- `dune exec`単独でbundle生成からE2E実行まで完了 (事前`dune build @all`不要)
- npm scriptsはDune alias (`@phase3_ts_check`, `@phase3_ts_test`) へ接続
- source treeへの生成物漏出なし (`mode promote`廃止、gitignore個別規則なし、stamp targetでDune action実行)

## Phase 5: Windows E2E Gate

### Bootstrap順序
```text
cd web/phase3-atd-command
npm ci
cd ../..
dune build @all
dune runtest --force
dune build @install
dune exec spikes/phase3-atd-command/main.exe
```

npm scripts (`typecheck`, `test`, `bundle`) はDune alias経由で実行されるため、
上記の`dune build @all` / `dune runtest` と同等の検査をカバーする。

### 結果
- `npm ci`: 成功 (6 packages)
- `npm run typecheck`: 成功
- `npm test`: 成功 (error classification test含む)
- `dune clean && dune build @all`: 成功
- `dune runtest --force`: 5テスト全て成功
- `dune build @install`: 成功
- `dune exec spikes/phase3-atd-command/main.exe`: 全シナリオ成功
- `dune clean && dune exec` (事前buildなし): 成功 (bundle依存解決)
- clean checkout Gate: `dune clean` + `node_modules`削除 → `npm ci` → 全パスライン通過
- source tree汚染: `git status`で生成物検出なし
- WSLg: 未検証 (Linux環境必要)

### テスト一覧
```
ocaml_codec_test: passed round-trip decode variant unknown-field
state_machine_test: passed (20 window + 20 call transitions)
wire_parity_test: passed baseline vs ATD error envelope
atd_protocol_test: passed request error response identity app-error duplicate
protocol_test: passed request error response contracts
```

## Gate G 定量比較

| 指標 | baseline | ATD版 |
|------|-----:|-----:|
| handwritten reusable bridge行数 (.ml + .mli) | 284 | 400 |
| handwritten mini-app行数 (spike main.ml) | 302 | 251 |
| handwritten TS client行数 (client.ts + probe.ts) | 0 | 235 |
| protocol/codec test行数 | 78 | 569 |
| generated OCaml行数 (.ml + .mli) | 0 | 329 |
| generated TypeScript行数 | 0 | 431 |
| 1 Command追加時の手動同期箇所 | 5+ (decode/encode/error/handler/spike) | 3 (schema + descriptor + handler) |
| Command名の手書き出現箇所 | 5 | 14 |
| 型不一致の検出時点 | runtime中心 | compile (tsc) + codegen (atdml) + runtime |

注記:
- ATD版bridge行数が多いのはcodec record型とGADT定義による。Command追加時の増分はbaselineより少ない。
- Command名出現箇所が多いのは、TypeScript descriptorとprobe内のテストケースによる。descriptor 1箇所に集約すれば削減可能。
- test行数が多いのは否定テストの`expect_raises`化、wire parity test、type contract test、malformed rejection testを含むため。

### 定性比較

| 項目 | Webui_bridge_baseline | Webui_bridge_atd |
|------|----------------------|------------------|
| payload decode | 手書き `List.assoc_opt` | ATD生成 `of_yojson` |
| response encode | 手書き `Assoc`構築 | ATD生成 `to_yojson` |
| 型安全性 | `Yojson.Safe.t` (untyped) | 具象型 (typed) |
| error code | 文字列リテラル | variant (exhaustive) |
| ボイラープレート | 高 (手書きdecode/encode) | 低 (schema定義のみ) |
| 外部依存 | yojson | yojson + atd/atdml/atdts |
| 生成ファイル | なし | `.ml/.mli/.ts` (自動生成) |
| wire JSON互換性 | ✓ (protocol v1) | ✓ (protocol v1) |
| 実行時性能 | 手書きなので速い | inlined runtime付き、わずかにオーバーヘッド |
| 保守性 | schema変更時に手書きコードも更新 | schema変更時に再生成のみ |

## レビュー指摘への対応

### 初回レビュー

| 指摘 | 優先度 | 状態 | 修正内容 |
|------|--------|------|----------|
| application error wire互換性 | P1 | 修正済 | `failure_json_raw`追加、`responder_reject`が生成error JSONをtop-levelへ直接出力 |
| TypeScript typed client未実装 | P1 | 修正済 | `client.ts`, `probe.ts`, `type_contract_test.ts`実装、esbuild bundle pipeline構築 |
| 否定テストが退行を検出しない | P1 | 修正済 | `expect_raises` helper導入、`Obj.magic`除去、回帰確認済 |
| `node_modules`がGit管理候補 | P2 | 修正済 | `.gitignore`へ`node_modules/`追加 |
| E2Eシナリオが計画を完全には覆っていない | P2 | 修正済 | invalid delayケース追加 |
| 実装結果レポートが完了状態を過大評価 | P2 | 修正済 | 本ドキュメントで修正 |

### フォローアップレビュー

| 指摘 | 優先度 | 状態 | 修正内容 |
|------|--------|------|----------|
| Linuxでesbuild bundle生成が失敗する | P1 | 修正済 | `esbuild-wrapper.mjs` (JS API) 経由でcross-platform化 |
| frontend dependency bootstrapがDune契約に含まれていない | P1 | 修正済 | bootstrap前提を明記、`package.json`/`package-lock.json`をDune depに追加 |
| `main.exe`からruntime bundleへの依存がない | P1 | 修正済 | `bundle_embed.ml`生成ruleでcompile-time埋め込み、`dune exec`単独で成功 |
| protocol `invalid_payload`がapplication errorへ誤分類される | P1 | 修正済 | `category=protocol/internal`をapplication decodeより先に判定、mocked test追加 |
| handlerの`Exit`が握りつぶされる | P2 | 修正済 | `decode_ok` refでdecode/handler例外境界を分離、handler `Exit`は`internal_error`へ |
| 生成物がソースツリーへ残る | P2 | 修正済 | `mode promote`廃止、Dune build context内にTS集約、npm scriptsをDune alias接続、gitignore個別規則削除 |

## 採否判断

**採用: ATD payload SSOT (`atdml + atdts`) を本格導入する。**

理由:
1. 型安全性が大幅に向上 (payloadが具象型、error codeがvariant、TypeScript compile-time型検査)
2. ボイラープレートが削減 (schema定義のみでOCaml/TS両方のcodecが生成)
3. wire契約が単一ソース (`text_analyze.atd`) に集約
4. baselineとapplication error wire互換性を維持 (protocol v1)
5. クリーンビルド・全テスト・E2Eゲート通過 (Windows)
6. codegen→bundle pipelineがcross-platform Dune target化
7. `dune exec`単独でbundle生成からE2E実行まで完了
8. error分類規則がprotocol/application境界を正しく判定
9. handler例外(Exit含む)がsanitized `internal_error`として処理される
10. frontend生成物がsource treeへ漏出しない (`mode promote`廃止、gitignore個別規則なし)

残課題:
1. Command名/descriptorの重複 (14箇所) — descriptor 1箇所に集約すれば削減可能
2. WSLg/Linux検証が未実施
3. `atdgen`のstreaming APIが必要な場合は再評価

## 次のステップ

- Context Mixerのcontext型と改訂ロードマップは、ユーザー確認後に連鎖更新する
- 追加Command (text.analyze以外) のschema定義
- WSLg/Linux環境でのGate F検証
