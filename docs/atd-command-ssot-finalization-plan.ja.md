# ATD Command SSOT 最終化実行プラン

作成日: 2026-07-21

関連文書:

- `docs/atd-command-ssot-execution-plan.ja.md`
- `docs/atd-command-ssot-implementation-review.ja.md`
- `docs/atd-command-ssot-followup-review.ja.md`
- `docs/atd-command-ssot-results.ja.md`

## 1. 目的

ATD payload SSOT実装は、Windows/WebView2とWSL2/WSLgのruntime pathでは成立している。
application error wire互換、typed TypeScript client、handler例外、duplicate/cancel/root不変条件も
検証済みである。

残っている問題は、frontend生成物とclean checkout手順の不整合である。本プランでは次を完了し、
ATD実装をreview可能なcommitへ分割して、ロードマップ手順3の最終判断へ進める。

1. generated TypeScriptを含む全生成物を`_build/`配下だけに置く。
2. `mode promote`と生成物固有のGit ignoreに依存しない。
3. `npm ci`後、clean checkoutから同じコマンドでtypecheck/test/bundle/E2Eを実行できる。
4. WindowsとWSLgの同一Gateを通す。
5. bundleのOCaml埋め込みを任意のJavaScript文字列に対して安全にする。
6. 実測結果とローカル文書を一致させる。
7. commit後、ユーザー確認を経てContext Mixerを連鎖更新する。

## 2. 現在地

### 完了している内容

- `text_analyze.atd`からOCaml/TypeScript codecを生成
- typed OCaml Command GADTとexistential registry
- application errorのbaseline wire parity
- TypeScript `defineCommand` / `invokeCommand`
- protocol/application error分類
- malformed result/error runtime validation
- handler `Failure` / `Exit`のsanitized `internal_error`
- generated TypeScript bundleのcompile-time OCaml埋め込み
- Windows WebView2 E2E
- WSL2/WSLg E2E
- direct clean `dune exec`からbundle生成と実行
- duplicate response、close cancellation、destroy後root 0

### 未完了

clean checkoutでは`web/phase3-atd-command/text_analyze.ts`が存在しないため、現在の結果レポートに
記載された次の順序は失敗する。

```text
npm ci
npm run typecheck
dune build @all
```

現在は`web/phase3-atd-command/dune`の`mode promote`がDune build後にgenerated TSをsource treeへ
書き出し、`.gitignore`がそれを隠している。したがって、既存作業ツリーではtypecheckが成功するが、
本当のclean checkoutでは最初のtypecheckが失敗する。

また、`gen_bundle_embed.ml`はbundleをOCaml raw string `{|...|}`へ直接入れるため、bundle内に
`|}`が現れた場合に生成コードが壊れる。

## 3. 方針決定

### 3.1 Duneを生成pipelineの正本にする

`.atd`から生成されたTypeScriptを使用するbuild/testは、Dune build context内で実行する。
npm scriptsはDune aliasを呼ぶ薄い入口にし、source treeへgenerated TSをcopyしない。

正規pipeline:

```text
text_analyze.atd
  -> atdts
  -> _build/default/lib/command_schema/text_analyze.ts
  -> _build/default/web/phase3-atd-command/text_analyze.ts
  -> TypeScript typecheck/runtime test
  -> esbuild IIFE
  -> bundle_embed.ml
  -> main.exe
  -> WebView E2E
```

### 3.2 `npm ci`は明示的なbootstrap前提とする

Dune/opam build中にnetwork accessを発生させない。`npm ci`はdeveloper/CI setupとして明示し、
Duneは既にinstallされたlockfile準拠の`node_modules`を使用する。

標準順序:

```text
cd web/phase3-atd-command
npm ci
cd ../..
opam exec -- dune build @phase3_ts_check
opam exec -- dune build @phase3_ts_test
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune build @install
opam exec -- dune exec spikes/phase3-atd-command/main.exe
```

alias名は実装時にDuneの命名規則へ合わせて調整してよい。ただしWindowsとLinuxで同じ名前を使う。

### 3.3 source treeを生成物の置き場所にしない

次のファイルはsource artifactとして扱わない。

- `web/phase3-atd-command/text_analyze.ts`
- `web/phase3-atd-command/probe.bundle.js`
- `web/phase3-atd-command/ts_codec_test.mjs`

既存ファイルを削除し、正規pipelineでは`_build/`にだけ生成する。`.gitignore`で隠すのではなく、
誤ってsource treeへ生成された場合は`git status`で検出できる状態にする。

### 3.4 bundle埋め込みはescaped OCaml stringを使う

固定raw-string delimiterを使わない。generatorはbundle contentをOCaml文字列としてescapeする。

```ocaml
Printf.fprintf oc "let bundle = %S\n" bundle
```

`|}`、quote、backslash、改行を含むfixtureで生成moduleがcompileできることを確認する。

## 4. 実装ステップ

### Step 0: 作業前スナップショット

目的: 現在の未コミット実装とユーザー変更を保護する。

確認:

```powershell
git status --short --untracked-files=all
git diff -- .gitignore ocaml-webui.opam
git log -1 --oneline
```

注意:

- 現在のHEADは`36a803c Add handwritten Command bridge baseline`。
- ATD実装一式は未コミット。
- `git add .`を使わない。
- source generated artifactを除去する前に、schemaから再生成可能であることを確認する。
- unrelated worktree変更には触れない。

Gate 0:

- 対象ファイル一覧が記録されている。
- generated fileとhandwritten sourceを区別できている。
- rollbackにGit destructive commandを必要としない。

### Step 1: `mode promote`とsource generated artifactを除去

対象:

- `web/phase3-atd-command/dune`
- `.gitignore`
- source tree上のgenerated TS/bundle/mjs

作業:

1. `web/phase3-atd-command/dune`から`(mode promote)`を削除する。
2. Dune target `text_analyze.ts`はbuild directory内だけに生成する。
3. source treeの`text_analyze.ts`を削除する。
4. source treeに残っていれば`probe.bundle.js`と`ts_codec_test.mjs`も削除する。
5. `.gitignore`から次の個別規則を削除する。

```gitignore
web/phase3-atd-command/text_analyze.ts
web/phase3-atd-command/probe.bundle.js
web/phase3-atd-command/ts_codec_test.mjs
```

6. `node_modules/`、`/_build/`、`/_opam/`のignoreは維持する。
7. Dune build後に上記3ファイルがsource treeへ現れないことを確認する。

Gate 1:

- generated TSは`_build/default/...`にだけ存在する。
- source treeの個別generated-file ignoreがない。
- 誤生成が起きれば`git status`へ現れる。

### Step 2: Dune内にTypeScript検査workspaceを作る

目的: generated TSとhandwritten client/testを同じbuild contextへ集める。

build directory内に次を揃える。

```text
_build/default/web/phase3-atd-command/
├─ text_analyze.ts       # atdts生成物からcopy
├─ client.ts             # source mirror
├─ probe.ts              # source mirror
├─ ts_codec_test.ts      # source mirror
├─ type_contract_test.ts # source mirror
├─ tsconfig.json         # source mirror
└─ esbuild-wrapper.mjs   # source mirror
```

作業:

1. `text_analyze.ts` targetは`lib/command_schema`のgenerated targetに依存させる。
2. TypeScript source/test/configはDune build contextへ通常のsource mirrorとして配置する。
3. typecheck用aliasを作る。
4. runtime test bundle生成targetと実行aliasを作る。
5. probe bundle targetは同じgenerated TSを使用する。
6. TypeScript compilerはplatform-neutralなJavaScript entrypointを`node`で起動する。
7. esbuildは既存`esbuild-wrapper.mjs`からJavaScript APIを呼ぶ。

概念上のtarget:

```text
@phase3_ts_check
  -> generated text_analyze.ts
  -> tsc --strict --noEmit

@phase3_ts_test
  -> generated text_analyze.ts
  -> ts_codec_test.mjs
  -> node runtime test

probe.bundle.js
  -> generated text_analyze.ts
  -> client.ts + probe.ts
  -> esbuild wrapper
```

Dune syntaxは実装時に現在の3.24系で検証する。aliasはtargetを宣言するだけでなく、実際にNode
processを実行するactionを持たせる。

Gate 2:

- clean checkoutでsource `text_analyze.ts`がなくてもtypecheckできる。
- `@ts-expect-error`が正しく消費される。
- runtime codec/error-classification testが成功する。
- typecheck/test/bundleが同じgenerated TSを使用する。

### Step 3: npm scriptsをDune aliasの入口にする

目的: developerが誤った順序や別のgenerated TSを使わないようにする。

作業:

1. `npm run typecheck`をDune typecheck aliasへ接続する。
2. `npm test`をDune runtime-test aliasへ接続する。
3. `npm run bundle`を正規Dune bundle targetへ接続するか、非公開のdebug用scriptへ限定する。
4. npm scriptからsource directoryへのoutfile指定をなくす。
5. Windows `cmd.exe`とLinux shellの両方で動く引数にする。

候補:

```json
{
  "scripts": {
    "typecheck": "opam exec -- dune build --root ../.. @phase3_ts_check",
    "test": "opam exec -- dune build --root ../.. @phase3_ts_test",
    "bundle": "opam exec -- dune build --root ../.. _build/default/spikes/phase3-atd-command/probe.bundle.js"
  }
}
```

実際のroot指定はWindows/WSLで検証し、必要ならrepository root用PowerShell/Bash scriptを増やさず
Dune側の入口へ統一する。

Gate 3:

- `npm ci`直後の`npm run typecheck`がclean checkoutで成功する。
- npm scriptsがsource treeへ生成物を残さない。
- npm scriptsと直接Dune aliasの結果が同じ。

### Step 4: bundle埋め込みgeneratorを安全化

対象:

- `spikes/phase3-atd-command/gen_bundle_embed.ml`
- 必要なら専用generator test

作業:

1. input read後、`Printf.fprintf oc "let bundle = %S\n" content`で出力する。
2. input/output channelを例外時にもcloseする小さなhelperへ整理する。
3. 次を含むfixtureを生成する。

```text
|}
"quoted"
backslash\value
multiple
lines
```

4. 生成された`.ml`をOCaml compiler/Duneでcompileする。
5. 実際のprobe bundleを埋めた`main.exe`を実行する。

Gate 4:

- `|}`を含む入力でもgenerated OCamlがcompileできる。
- bundle内容が実行時に欠落・変形しない。
- Windows/WSLg WebViewでprobeがpassする。

### Step 5: clean checkout GateをWindowsで実行

目的: 既存のpromoted fileや古い`_build`に依存していないことを確認する。

検証用directoryには次を持ち込まない。

- `.git`
- `_build`
- `_opam`
- `node_modules`
- source generated TS/bundle/mjs

実行順:

```powershell
cd web/phase3-atd-command
npm ci
npm run typecheck
npm test
cd ../..
opam exec -- dune build @all
opam exec -- dune runtest --force
opam exec -- dune build @install
opam exec -- dune exec spikes/phase3-atd-command/main.exe
```

追加確認:

```powershell
git status --short --untracked-files=all
git diff --check
```

Gate 5:

- 全commandがexit 0。
- generated bundleが実WebView2で実行される。
- handler `Failure` / `Exit`が`internal_error`。
- malformed payloadが`ProtocolError`相当。
- empty text / invalid delayがtyped application error。
- duplicate/cancel/root 0。
- source generated artifact 0。

### Step 6: clean checkout GateをWSL2/WSLgで実行

Windowsと同じsource snapshotをWSL ext4上へ配置する。`/mnt/d`上のbuild artifactを再利用しない。

実行順:

```bash
cd web/phase3-atd-command
npm ci
npm run typecheck
npm test
cd ../..
opam exec --switch=ocaml-webui-linux -- dune build @all
opam exec --switch=ocaml-webui-linux -- dune runtest --force
opam exec --switch=ocaml-webui-linux -- dune build @install
opam exec --switch=ocaml-webui-linux -- \
  dune exec spikes/phase3-atd-command/main.exe
```

別途、事前`dune build @all`なしのdirect pathも確認する。

```bash
npm ci
opam exec --switch=ocaml-webui-linux -- \
  dune exec spikes/phase3-atd-command/main.exe
```

許容:

- WSLg固有のEGL/Zink fallback warning

失敗扱い:

- GTK critical
- uncaught JavaScript error
- native callback exception
- missing bundle
- root残留
- non-zero exit
- source generated artifact

Gate 6:

- Windowsと同じcaseがすべてpass。
- cross-platform esbuild wrapperがLinuxでも動く。
- sequential Window create/destroyが成立する。
- WSL一時検証directoryを終了後に削除する。

### Step 7: 結果レポートを実測へ合わせる

対象:

- `docs/atd-command-ssot-results.ja.md`
- 必要に応じて前回review文書へfollow-up link

修正:

1. 判定をWindows/WSLg Gate F通過へ更新する。
2. 「WSLg未検証」を削除する。
3. 正しいbootstrap順を記載する。
4. `mode promote`とsource generated artifactに関する記述を削除する。
5. generated fileが`_build`内だけにあることを記載する。
6. bundle embedのescape方式を記載する。
7. 定量表の行数が「空行を除いた行数」であることを明記する。
8. `probe.ts`のシナリオ数を全箇所で7に統一する。
9. 実行日、OS、OCaml/Dune/Node/ATD versionを記録する。

Gate 7:

- 実装、test、結果レポートに矛盾がない。
- 過去reviewは履歴として残し、最終結果へのlinkがある。
- 検討中事項を確定仕様として書かない。

## 5. 最終検証matrix

| Gate | Windows | WSLg | GUI不要 | 合格条件 |
|---|---|---|---|---|
| npm bootstrap | 必須 | 必須 | はい | lockfileからinstall成功 |
| TS typecheck | 必須 | 必須 | はい | clean sourceで成功 |
| TS runtime test | 必須 | 必須 | はい | codec/error分類成功 |
| Dune clean build | 必須 | 必須 | はい | generated artifactが`_build`のみ |
| OCaml contract test | 必須 | 必須 | はい | wire/negative/duplicate成功 |
| install target | 必須 | 必須 | はい | package artifacts成功 |
| direct `dune exec` | 必須 | 必須 | いいえ | bundle自動生成、E2E成功 |
| lifecycle/root | 必須 | 必須 | いいえ | pending/binding/dispatch root 0 |
| source cleanliness | 必須 | 必須 | はい | generated file漏出0 |

## 6. Commitプラン

ATD実装一式が未コミットのため、次のreview可能な単位へ分ける。各commitは可能な範囲で単独build
可能にする。

### Commit 1: `Generate text analyze codecs from ATD`

対象:

- `ocaml-webui.opam`
- `lib/command_schema/`
- `test/command_schema/`
- fixture

Gate:

- OCaml codec test
- generated OCaml build
- generated TS target build
- `dune build @install`

### Commit 2: `Add typed ATD Command bridge`

対象:

- `lib/bridge_atd/`
- `test/bridge_atd/`

Gate:

- protocol test
- wire parity test
- duplicate Command test
- handler exception boundary test

### Commit 3: `Run generated ATD client in WebView`

対象:

- `web/phase3-atd-command/`
- `spikes/phase3-atd-command/`
- `.gitignore`

Gate:

- Windows/WSLg TS typecheck/test
- Windows/WSLg direct E2E
- generated artifact source漏出0

### Commit 4: `Document ATD payload SSOT acceptance`

対象:

- execution plan
- implementation review
- follow-up review
- finalization plan
- results report

Gate:

- documentと実測の一致
- path/command/versionの再確認
- `git diff --check`

Commit時の注意:

- `git add .`を使わない。
- commitごとに明示pathだけをstageする。
- `git status --short --untracked-files=all`でstage前後を確認する。
- `node_modules`、generated TS、bundle、mjs、`_build`をstageしない。

## 7. Context Mixer連鎖更新プラン

ローカル実装と全Gate通過後、まずユーザーへ次を確認する。

> `atdml + atdts`によるATD payload SSOTをロードマップ手順3の採用結果として確定し、
> Context Mixerのspec/decision/contextへ反映してよいか。

ユーザー確認後のみ次を更新する。

### spec

- payload schemaの正本: `.atd`
- generated OCaml/TypeScript codec
- typed Command/Responder境界
- Protocol v1 application/protocol error分類
- frontend bootstrapとbuild target
- generated artifact配置

### decisions

新規decisionページを作る場合はユーザー確認後とする。記録内容:

- `atdml + atdts`採用
- `atdgen`を今回採用しなかった理由
- 独自generatorをまだ作らない理由
- protocol envelopeは当面手書きで維持する理由

### notes

- esbuild package launcherのWindows/Linux差
- DuneからJavaScript API wrapperを使う理由
- `mode promote`がclean checkoutを隠す問題
- WSLg EGL/Zink warningとGTK criticalの区別

### context

- ロードマップ手順3完了
- Windows/WSLg Gate F結果
- 残課題: Command名/descriptor重複、schema hash、非WSL Linux/macOS
- 次工程候補: Traceレイヤー

連鎖更新後、spec/context/decision/notes間の矛盾がないことを再読する。

## 8. 完了条件

次をすべて満たした時点で本プランを完了とする。

- source treeにgenerated TS/bundle/mjsが存在しない。
- generated-file固有ignoreで問題を隠していない。
- `npm ci`直後の標準typecheck/testが成功する。
- TypeScript検査とWebView bundleが同じgenerated TSを使用する。
- bundle embedが`|}`を含む入力でも安全である。
- Windows clean Gateが成功する。
- WSLg clean Gateが成功する。
- direct `dune exec`が両環境で成功する。
- application/protocol error分類が自動testで固定されている。
- handler `Failure` / `Exit`がsanitizedされる。
- duplicate/cancel/root不変条件が維持される。
- `dune build @install`が成功する。
- `git diff --check`が成功する。
- 結果レポートが実測と一致する。
- 4単位のcommitが作成されている。
- ユーザー確認後にContext Mixerが連鎖更新されている。

## 9. 本プランの次

ATD payload SSOT最終化後は、追加Commandを増やす前に次のどちらかを選ぶ。

1. Traceレイヤーへ進み、1つの`text.analyze`をJS/OCaml/Domain横断で追跡する。
2. 2つ目の小さなCommandを追加し、SSOT追加コストとdescriptor重複を再計測する。

推奨は2を短く実施してから1へ進むこと。1 Commandだけでは「追加時の同期箇所削減」という
ATD採用効果を実証しきれないため、単純な2つ目のCommandでbuild/test/descriptor増分を確認し、
独自generatorが本当に不要かを再評価する。その後Traceレイヤーへ進む。
