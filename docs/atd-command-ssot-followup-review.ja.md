# ATD Command SSOT 実装フォローアップレビュー

> **注意: このレビューで指摘されたP1×4/P2×2は全て修正済みである。**
> **最新状態は `docs/atd-command-ssot-results.ja.md` を参照のこと。**

レビュー日: 2026-07-20

関連文書:

- `docs/atd-command-ssot-execution-plan.ja.md`
- `docs/atd-command-ssot-implementation-review.ja.md`
- `docs/atd-command-ssot-results.ja.md`

## 1. 結論

前回レビューで指摘したapplication error wire互換性、OCaml否定テスト、typed TypeScript
client、invalid delay E2E、`node_modules`除外には修正が入っている。Windows上ではTypeScript
typecheck/runtime test、Dune build/test/install、WebView2 E2Eがすべて成功した。

一方、clean checkoutとWSL2/WSLgで再検証した結果、frontend bundle pipelineに新しいP1を
確認した。現時点の判定は次のとおり。

> Windows typed client/native bridgeの縦切りは合格。cross-platform build、clean checkout
> 再現性、error分類のGateは未通過。コミットおよびGate F/G完了扱いは保留する。

主な未解決事項:

1. LinuxではDuneからesbuildを起動できない。
2. `node_modules`なしのclean checkoutでは`dune build @all`できない。
3. `dune exec`単独ではruntime bundleが生成されない。
4. protocol `invalid_payload`がtyped clientでapplication errorへ誤分類される。
5. handlerが標準例外`Exit`をraiseするとresponseなしで終了する。
6. 生成TS/bundleがソースツリーに残り、結果レポートと矛盾する。

## 2. 前回指摘への対応確認

| 前回指摘 | 現在の状態 | 確認内容 |
|---|---|---|
| application error wire互換性 | 修正済み | generated errorをtop-level `error`へ出力 |
| TypeScript typed client未実装 | 部分完了 | client/probeは実装済み。build pipelineにP1あり |
| OCaml否定テストが常に成功 | 修正済み | `expect_raises`で正常returnを失敗扱い |
| duplicate testの`Obj.magic` | 修正済み | 有効なWindowを作成して結果をpattern match |
| `node_modules`が未ignore | 修正済み | root `.gitignore`へ`node_modules/`追加 |
| invalid delay E2Eがない | 修正済み | generated probeにinvalid delayを追加 |
| 結果レポートの過大評価 | 再修正が必要 | Windows結果は更新済みだがclean/WSLの記述が不正確 |

### 2.1 Wire互換性

`Webui_bridge_atd.Protocol.failure_json_raw`が追加され、typed `responder_reject`はATD生成error
JSONを`details`へ包まず、Protocol v1 envelopeのtop-level `error`へ直接配置するようになった。

`wire_parity_test`ではhandwritten baselineとATD版のapplication error envelopeをJSON構造で
比較し、次を確認している。

- `error.code = empty_text`
- `error.category = validation`
- `details` wrapperなし
- request ID / trace ID / Command名の一致

Windows/WSLのOCaml contract testはいずれも成功した。

### 2.2 OCaml否定テスト

`test/command_schema/ocaml_codec_test.ml`には次の形式のhelperが導入された。

```ocaml
let expect_raises label f =
  match f () with
  | exception _ -> ()
  | _ -> fail (label ^ " — expected exception")
```

これによりdecoderが不正入力を受理した場合はtestが失敗し、前回のようにtest自身の
`failwith`を期待例外として捕捉しない。

duplicate Command testも`Obj.magic`を除去し、実Windowに対する`Bridge.install`結果を直接
pattern matchする形になった。

### 2.3 Typed TypeScript client

次の成果物が追加された。

- `client.ts`
  - `CommandDescriptor<I, O, E>`
  - `defineCommand`
  - `invokeCommand`
  - `ApplicationError<E>`
  - `ProtocolError`
  - `textAnalyze` descriptor
- `probe.ts`
  - typed success
  - empty text
  - invalid delay
  - unknown Command
  - malformed payload
  - handler exception
- `type_contract_test.ts`
  - wrong field
  - wrong input type
  - missing field
  - extra field
  - typed application error
- `ts_codec_test.ts`
  - codec round-trip
  - malformed result/error rejection

Windows WebView2のsuccess phaseは生成bundleを読み込み、typed `textAnalyze` descriptorからnative
bindingを呼び出している。

## 3. 再検証結果

### 3.1 Windows

| 検証 | 結果 |
|---|---|
| `npm run typecheck` | 成功 |
| `npm test` | 成功 |
| `npm run bundle` | 成功 |
| `opam exec -- dune build @all` | 成功 |
| `opam exec -- dune runtest --force` | 成功 |
| `opam exec -- dune build @install` | 成功 |
| `opam exec -- dune exec spikes/phase3-atd-command/main.exe` | 成功 |

Windows E2E最終出力:

```text
atd_bridge: passed success validation unknown handler_error duplicate cancel malformed roots=0
```

OCaml test出力:

```text
ocaml_codec_test: passed round-trip decode variant unknown-field
state_machine_test: passed (20 window + 20 call transitions)
wire_parity_test: passed baseline vs ATD error envelope
protocol_test: passed request error response contracts
atd_protocol_test: passed request error response identity app-error duplicate
```

### 3.2 Clean checkout相当、`node_modules`なし

Windows workspaceから次を除外してWSL ext4上の一時ディレクトリへ同期した。

- `.git`
- `_build`
- `_opam`
- `node_modules`

その状態で`dune build @all`を実行すると、esbuild moduleが存在しないため失敗した。

```text
Error: Cannot find module
'.../_build/default/web/phase3-atd-command/node_modules/esbuild/bin/esbuild'
```

結論:

- 現在のDune ruleはclean checkoutだけでは再現できない。
- `npm ci`が暗黙の必須手順になっている。
- `docs/atd-command-ssot-results.ja.md`の「clean checkoutから再現可能」は成立していない。

### 3.3 WSL2/WSLg、`npm ci`実行後

WSL一時ディレクトリで次は成功した。

```text
npm ci
npm run typecheck
npm test
```

しかし、その後の`dune build @all`はbundle生成で失敗した。

```text
.../node_modules/esbuild/bin/esbuild:1
ELF binary header

SyntaxError: Invalid or unexpected token
```

原因は、Dune ruleが次の形式でesbuildを起動していることにある。

```dune
(run node ../../web/phase3-atd-command/node_modules/esbuild/bin/esbuild ...)
```

Windows packageの`esbuild/bin/esbuild`はNodeから起動できる形だが、Linuxではnpm install後に
native ELF launcherとなる。これを`node`へ渡すため、JavaScriptとしてparseしようとして失敗する。

結論:

- TypeScript sourceとcodec testはLinuxでも動作する。
- Dune/esbuild launcherだけがcross-platformではない。
- WSLg WebView E2Eには到達していない。

### 3.4 Clean環境での`dune exec`

clean checkout相当から、事前に`dune build @all`を行わず次を実行した。

```text
dune exec spikes/phase3-atd-command/main.exe
```

結果:

```text
Sys_error(".../_build/default/spikes/phase3-atd-command/probe.bundle.js:
No such file or directory")
```

`main.exe`はruntimeに`probe.bundle.js`を読むが、Duneのexecutable targetがbundle targetへ依存
していない。`dune rules main.exe`にも`probe.bundle.js`は現れなかった。

## 4. 新しいレビュー指摘

### 4.1 P1: Linuxでesbuild bundle生成が失敗する

対象:

- `spikes/phase3-atd-command/dune` lines 26–33

現在のruleはplatformによって形式が異なる`esbuild/bin/esbuild`を常に`node`で実行する。

影響:

- WSL/Linux `dune build @all`が失敗する。
- WSLg Gate Fへ進めない。
- Windowsでのみ成功するpipelineになる。
- 結果レポートのcross-platform前提が成立しない。

推奨修正:

Nodeからesbuild JavaScript APIを呼ぶ小さなwrapperを用意する。

```js
import { build } from "esbuild";

await build({
  entryPoints: [process.argv[2]],
  bundle: true,
  format: "iife",
  platform: "browser",
  outfile: process.argv[3],
});
```

DuneはOS別binaryを直接扱わず、このwrapperだけを`node`で起動する。

### 4.2 P1: frontend dependency bootstrapがDune契約に含まれていない

対象:

- `spikes/phase3-atd-command/dune`の`source_tree node_modules`
- `web/phase3-atd-command/package.json`

`node_modules`をGitから除外したこと自体は正しい。しかしDune ruleは除外されたdirectoryを直接
dependencyとして要求し、ない場合の明確なエラーやbootstrap手順を持たない。

選択肢:

1. CI・開発手順を`npm ci` → Dune frontend alias → OCaml E2Eの二段階にする。
2. frontend bundleを通常の`@all`から分離し、専用aliasでのみ構築する。
3. Dune sandbox内にpackage/lockfileをcopyし、明示的なfrontend bootstrap targetを作る。

opam package build中のnetwork installは避ける。まずは1または2が単純である。

完了条件:

- `node_modules`がない場合に必要手順が明確である。
- `npm ci`後はWindows/WSLの同じDune targetが成功する。
- 結果レポートに正確なbootstrap前提が記載される。

### 4.3 P1: `main.exe`からruntime bundleへの依存がない

対象:

- `spikes/phase3-atd-command/dune`
- `spikes/phase3-atd-command/main.ml`の`read_bundle`

`main.ml`は実行時に実行ファイルと同じdirectoryの`probe.bundle.js`を読む。しかしexecutable
stanzaはbundleをdependencyとして宣言していない。

影響:

- clean環境の`dune exec`がmissing fileで終了する。
- `dune build @all`を先に実行した場合だけ偶然成功する。
- 実装計画に記載した単独E2E commandが自己完結しない。

推奨修正:

- executableへ`link_deps probe.bundle.js`相当のdependencyを追加する。
- または`main.exe`とbundleの両方へ依存する専用run aliasを作る。
- clean環境からE2E command一つだけでbundle生成と実行が完了するtestを追加する。

### 4.4 P1: protocol `invalid_payload`がapplication errorへ誤分類される

対象:

- `web/phase3-atd-command/client.ts` lines 107–116
- `lib/command_schema/text_analyze.atd`の`Invalid_payload`
- `lib/bridge_atd/webui_bridge_atd.ml`のprotocol `invalid_payload`

typed clientはerror responseを受けると、まず`descriptor.readError(response.error)`を試す。
一方、次の2つは同じJSON shapeを持つ。

Application error候補:

```json
{
  "code": "invalid_payload",
  "message": "...",
  "retryable": false,
  "category": "validation"
}
```

Protocol error:

```json
{
  "code": "invalid_payload",
  "message": "payload decode failed",
  "retryable": false,
  "category": "protocol"
}
```

ATD error codeにも`invalid_payload`があるため、protocol errorもgenerated readerでdecodeできる。
結果として`ProtocolError`ではなく`ApplicationError<TextAnalyzeError>`が投げられる。

現在のprobeはmalformed payloadだけraw bindingを直接呼んでおり、`invokeCommand`の分類を通さない
ため、この問題を検出しない。

推奨修正:

1. `category = protocol`または`internal`をtyped application decodeより先に判定する。
2. protocol/internal categoryを予約値としてProtocol v1契約へ明記する。
3. rejected native envelopeをmockし、`invokeCommand`が`ProtocolError`を返すruntime testを追加する。
4. application errorはgenerated readerを通り、`ApplicationError<E>`になることも同じtestで固定する。

### 4.5 P2: handlerの`Exit`が握りつぶされる

対象:

- `lib/bridge_atd/webui_bridge_atd.ml` lines 325–340

payload decode失敗後に共通handler処理へ進まないためのsentinelとして、標準例外`Exit`を使って
いる。外側のhandler exception catchにも次がある。

```ocaml
| Exit -> ()
| exn -> reject internal_error
```

handler自身が制御フローとして`Exit`をraiseした場合もdecode失敗と区別されず、responseなしで
終了する。PromiseはWindow closeまでpendingになる。

推奨修正:

decodeとhandlerを別の例外境界にする。

```ocaml
match (try Ok (decode payload) with exn -> Error exn) with
| Error exn -> reject_invalid_payload exn
| Ok input ->
    try handler context input responder with
    | exn -> reject_internal_error exn
```

handlerが`Exit`をraiseするregression caseを追加し、sanitized `internal_error`とpending Call解放を
確認する。

### 4.6 P2: 生成物がソースツリーへ残る

次のファイルが未追跡で、Git ignoreもされていない。

- `web/phase3-atd-command/text_analyze.ts`
- `web/phase3-atd-command/probe.bundle.js`
- `web/phase3-atd-command/ts_codec_test.mjs`

`text_analyze.ts`は`atdts`生成物、残り2つはnpm/esbuild生成物である。`npm test`と
`npm run bundle`がソースdirectoryへ直接出力するため、test実行のたびに生成物が残る。

影響:

- `.atd`とsource tree上のgenerated TSが二重の正本になる。
- schema変更後に古いTSでnpm testだけが成功する可能性がある。
- Dune生成bundleとnpm生成bundleが別path・別条件で作られる。
- 結果レポートの「生成物は`_build/`内のみ」と矛盾する。

推奨修正:

1. source treeの生成TS/bundle/mjsを削除する。
2. npm scriptsの出力先を`_build/frontend/phase3-atd-command/`等へ変更する。
3. typecheck/testもDune生成`text_analyze.ts`を入力にする。
4. generated artifact用ignoreを追加する場合も、正規pipelineの出力先は`_build`へ統一する。

## 5. 推奨する次の実行プラン

### Step 1: bundle pipelineをcross-platform化する

1. esbuild JavaScript API wrapperを追加する。
2. Duneからwrapperを`node`で起動する。
3. WindowsとWSLで同じcommandを実行する。
4. `source_tree node_modules`による全依存file列挙を避け、必要なpackage/lockfile/stampへ絞る。

Gate:

- Windows `dune build`成功
- WSL `dune build`成功
- bundle hashまたはruntime behaviorが両環境で一致

### Step 2: runtime bundle依存を宣言する

1. `main.exe`から`probe.bundle.js`へのdependencyを追加する。
2. `_build`なしの環境から`dune exec`だけを実行する。
3. bundle生成後にWebView E2Eまで進むことを確認する。

Gate:

- 事前`dune build @all`なしでE2E成功
- missing bundleの`Sys_error`が再現しない

### Step 3: frontend生成物を`_build`へ統一する

1. source treeの`text_analyze.ts`、bundle、mjsを削除する。
2. npm scriptsのoutput directoryを変更する。
3. Dune生成TSをnpm typecheck/testへ接続する。
4. `git status --short --untracked-files=all`で生成物漏出0を確認する。

Gate:

- `.atd`がpayload shapeの唯一の正本
- test/bundle後もsource treeがclean

### Step 4: error分類とhandler例外を修正する

1. protocol/internal categoryをapplication decodeより先に判定する。
2. mocked rejected envelope testを追加する。
3. `Exit` sentinelを除去する。
4. handler `Exit` regression testを追加する。

Gate:

- malformed payloadは`ProtocolError`
- empty text/invalid delayは`ApplicationError<TextAnalyzeError>`
- handler `Exit`はsanitized `internal_error`
- pending Call/root残留0

### Step 5: Windows/WSLg最終回帰

前提bootstrapを明示したうえで両環境に同じ順序を適用する。

```text
npm ci
npm run typecheck
npm test
dune build @all
dune runtest --force
dune build @install
dune exec spikes/phase3-atd-command/main.exe
```

追加確認:

- clean checkout
- direct `dune exec`
- typed protocol/application error分類
- generated bundleの実WebView実行
- invalid delay
- duplicate response
- close cancellation
- handler `Exit`
- destroy後root 0
- WSL sequential Window recreate

### Step 6: ドキュメントと採否を更新する

全Gate通過後に次を更新する。

1. `docs/atd-command-ssot-results.ja.md`
   - WSLg実測結果
   - frontend bootstrap前提
   - generated artifact配置
   - error分類規則
2. `docs/atd-command-ssot-implementation-review.ja.md`
   - historical reviewであること、後続文書へのlink
3. Context Mixer
   - spec: ATD payload SSOTの確定仕様
   - context: 現在地と残課題
   - decisions: ユーザー確認後に`atdml + atdts`採用理由
   - notes: esbuild Windows/Linux launcher差

Context Mixerの連鎖更新は、最終結果をユーザーが確認した後に行う。

## 6. 現在の作業ツリー

レビュー時点のHEAD:

```text
36a803c Add handwritten Command bridge baseline
```

ATD実装一式は未コミットである。`.gitignore`と`ocaml-webui.opam`はtracked modification、
schema、bridge、test、spike、TypeScript、documentはuntrackedとして存在する。

コミット前に少なくとも次を満たす必要がある。

- P1をすべて解消
- generated source artifactを除去
- Windows/WSLgの同一Gate成功
- `git diff --check`成功
- stage対象に`node_modules`、generated bundle、generated TS、runtime test outputがない
- 結果レポートと実装の一致
