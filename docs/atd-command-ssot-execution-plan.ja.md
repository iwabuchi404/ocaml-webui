# ATD Command SSOT 詳細実行計画

更新日: 2026-07-20  
状態: Draft / 実装未着手  
対象: 改訂ロードマップ手順3

## 1. 目的

手書きbaselineと同じ `text.analyze` CommandをATD schemaから生成し、Commandのinput、
output、application errorのJSON表現を単一のsource of truthへ移す。

この工程の目的は「ATDを導入すること」自体ではない。次を実測し、手書き版より境界実装が
単純か、型不一致を早く検出できるかを判定する。

1. OCamlとTypeScriptのpayload型・JSON codecを同じ`.atd`から生成できるか
2. 現行Protocol v1のwire JSONを変えずに置換できるか
3. 1 Command追加時に人が同期する箇所を減らせるか
4. WindowsとLinuxでcodegen/buildが再現可能か
5. generated TypeScript clientを実WebViewで利用できるか

## 2. 前提と固定する境界

### 2.1 入力となる既存成果物

- raw binding: `Webui_raw`
- 比較対象: `Webui_bridge_baseline`
- mini-app: `spikes/phase2-handwritten-bridge/`
- baseline計測:
  - reusable bridge `.ml`: 256行
  - public `.mli`: 71行
  - mini-app + embedded JavaScript: 321行
  - pure protocol test: 86行

### 2.2 この工程で固定するもの

- native binding名: `__ocaml_webui_invoke`
- Protocol version: `1`
- request envelope field:
  `protocol`, `requestId`, `traceId`, `command`, `payload`
- response envelope field:
  `protocol`, `requestId`, `traceId`, `command`, `ok`, `value/error`
- `requestId`と`traceId`の意味
- successはPromise resolve、application/protocol errorはPromise reject
- raw `Call.t`によるone-shot responseとWindow close cancellation
- handlerはUI callbackをblockせず、重い処理を別Domainへ移す
- Window lifecycleはapplicationが所有する
- Linuxのprocess-initial-thread / single-live-Window制約

wire互換を維持し、ATD導入とprotocol変更を同時に行わない。

### 2.3 対象外

- Eio/Lwt選定
- AbortSignal、timeout、deadline
- full trace store/debug viewer
- Capability/Scope
- Worker process
- Stream/Resource/Data Plane
- macOS/non-WSL Linux runtime gate
- 独自schema言語または汎用code generatorの自作
- baseline実装の削除

## 3. 事前調査で判明した仕様ドリフト

既存ロードマップは `atdgen + atdts`を既定としている。一方、2026-07時点のATD公式文書は
OCaml JSON生成に`atdml`を推奨し、`atdgen`はminimal maintenanceとしている。

- local opam repositoryの候補version: ATD tool群 `4.2.0`
- `atdml 4.2.0`
  - JSON専用
  - 1つの`.atd`から1組の`.ml/.mli`を生成
  - runtime dependencyは既存のYojsonだけ
  - cross-file import対応
  - 公式推奨だがgenerated interfaceはexperimental
- `atdgen 4.2.0`
  - 成熟しているが今後はminimal maintenance
  - typeとJSON codecが別generator pass
  - `atdgen-runtime` dependencyが必要
  - biniou/open enumerationは今回不要
- `atdts 4.2.0`
  - TypeScript typeとruntime `read*` / `write*`を生成
  - 文書は一部未完成なので、必要な挙動をcontract testで固定する

したがって最初から`atdml`へ確定せず、最小schemaを`atdml`と`atdgen`の両方で生成して
比較する。現時点の推奨候補は`atdml + atdts`だが、採用はGate Aで確定する。

## 4. 目標構成

以下は計画上の候補path。Gate Aの結果でgenerator固有suffixは調整する。

```text
schema/
└─ text_analyze.atd                 # payload SSOT

lib/
├─ bridge_baseline/                 # 比較対象として変更しない
├─ command_schema/
│  ├─ dune                          # ATD -> OCaml codegen rule
│  └─ text_analyze.atd              # schema/から参照するか、こちらを正本にする
└─ bridge_atd/
   ├─ dune
   ├─ webui_bridge_atd.ml
   └─ webui_bridge_atd.mli

web/phase3-atd-command/
├─ package.json
├─ package-lock.json
├─ tsconfig.json
├─ text_analyze_client.ts
└─ probe.ts

spikes/phase3-atd-command/
├─ dune
├─ main.ml
└─ README.md

test/command_schema/
├─ dune
├─ ocaml_codec_test.ml
├─ fixtures/
│  ├─ request-valid.json
│  ├─ result-valid.json
│  └─ error-valid.json
└─ TypeScript側fixture test

docs/
├─ atd-command-ssot-execution-plan.ja.md
└─ atd-command-ssot-results.ja.md   # 実装完了時に作る
```

schemaの正本は1ファイルだけにする。Dune ruleの都合で`lib/command_schema/`へ置く場合、
root `schema/`へcopyを作らない。

generated `.ml/.mli/.ts/.js`は原則 `_build`内に置き、手編集・commitしない。frontendへの
配布形態が確定していない現段階でgenerated sourceをsource treeへ複製しない。
`package-lock.json`はtoolchain再現性のためcommit対象とする。

## 5. ATD schema案

最初のschemaはapplication payloadだけを対象とする。Protocol envelopeまで同時に生成すると
比較変数が増えるため、envelopeのATD化は最後のoptional gateへ分離する。

```atd
type text_analyze_request = {
  text: string;
  delay_ms <json name="delayMs">: int;
}

type text_analyze_result = {
  bytes: int;
  words: int;
  observed_trace_id <json name="observedTraceId">: string;
}

type text_analyze_error_code = [
  | Empty_text <json name="empty_text">
  | Invalid_delay <json name="invalid_delay">
  | Invalid_text <json name="invalid_text">
  | Invalid_payload <json name="invalid_payload">
]

type text_analyze_error = {
  code: text_analyze_error_code;
  message: string;
  retryable: bool;
  category: string;
}
```

`delayMs`の0〜2000という範囲検査は構造codecではなくapplication validationとして残す。
ATD annotation内へ任意OCaml validationを埋めるとTypeScriptとのSSOTが崩れるためである。

## 6. target API案

生成codecを型付きCommandへ接続する最小APIを新しいexperimental library
`Webui_bridge_atd`に置く。baseline APIを破壊的変更しない。

```ocaml
type ('input, 'output, 'error) command

val define :
  name:string ->
  input_of_yojson:(Yojson.Safe.t -> 'input) ->
  output_to_yojson:('output -> Yojson.Safe.t) ->
  error_to_yojson:('error -> Yojson.Safe.t) ->
  (context -> 'input -> ('output, 'error) Responder.t -> unit) ->
  ('input, 'output, 'error) command
```

内部registryはexistential/GADTで異なるCommand型を隠す。

```ocaml
type packed_command =
  | Command : ('input, 'output, 'error) command -> packed_command
```

`Responder.resolve`は生成output encoder、`Responder.reject`は生成error encoderを必ず通す。
ATD decoderがraiseする例外はbinding callback境界より前で捕捉し、Protocol v1の
`invalid_payload`へ変換する。元例外はtrace ID付きnative logへ残す。

TypeScript側はatdts生成物をgeneric clientへ渡す。

```ts
export const textAnalyze = defineCommand({
  name: "text.analyze",
  writeInput: writeTextAnalyzeRequest,
  readOutput: readTextAnalyzeResult,
  readError: readTextAnalyzeError,
});
```

ATD単体ではCommand名や`invoke` wrapperを生成しない。この薄いdescriptorは当面手書きとし、
残る同期箇所として計測する。ここを消すための独自generatorは本工程では作らない。

## 7. 実行フェーズ

### Phase 0: toolchain feasibility spike

目的: repository APIを変更する前にgenerator選定を終える。

作業:

1. Windows project switchとWSL switchへ`atdml 4.2.0`、`atdgen 4.2.0`、
   `atdts 4.2.0`を導入する。
2. root Node toolchainへTypeScriptとesbuildをdev dependencyとしてlockする。
   調査時点の候補はTypeScript `7.0.2`、esbuild `0.28.1`。
3. 上記schemaをtemporary directoryで3 generatorへ入力する。
4. WindowsとWSLでgenerated file名、interface、JSON出力、終了codeを比較する。
5. `atdml`と`atdgen`のgenerated OCaml APIを小さなcompile testから使用する。
6. atdts生成TypeScriptを`tsc --strict --noEmit`で検査する。
7. 未知field、missing field、wrong JSON type、variant名、field renameを実行確認する。

Gate A — generator選定:

- `atdml + atdts`を選ぶ条件
  - Windows/WSL双方でDune rule化できる
  - baseline wire JSONと一致する
  - exception/error位置をtestで安定して捕捉できる
  - generated APIが今回のtyped responderへ無理なく接続できる
- `atdgen + atdts`へfallbackする条件
  - atdmlのexperimental API差またはbuild integrationが実害になる
  - atdml/atdts間で同じATD subsetのwire表現が一致しない
- 中止条件
  - どちらのOCaml generatorもatdtsと同じwire JSONを生成できない
  - OSごとに生成結果または必要annotationが変わる

Gate Aの比較結果をユーザーへ提示し、generatorを確定してからpackage dependencyと正式ruleを
追加する。これは既存ロードマップの`atdgen`指定を変更し得るため、確認なしに決定ページを
作らない。

成果物:

- generator比較ログ
- generated interface要約
- wire parity表
- 採用提案

### Phase 1: golden fixtureでwire契約を固定

目的: codegen移行をprotocol変更から分離する。

作業:

1. baselineが使用するrequest/result/error JSONをfixture化する。
2. field名・型・整数表現・variant文字列を明示する。
3. OCaml generated codecでfixtureをdecodeし、再encodeする。
4. TypeScript generated `read*` / `write*`でも同じfixtureをround-tripする。
5. JSON objectのfield順は比較せず、parse後の構造で比較する。
6. unknown fieldの扱いを両言語で記録する。差がある場合は共通のstrictness policyを
   bridge adapterで明示する。

Gate B — wire parity:

- baselineのvalid fixtureを両言語でdecodeできる
- 両言語のencode結果が構造的に同じ
- missing/wrong-type inputが両方でrejectされる
- JSON errorをFFI境界の外へraiseさせない

成果物:

- `test/command_schema/fixtures/*.json`
- OCaml codec contract test
- TypeScript codec contract test

### Phase 2: reproducible codegen rule

目的: clean checkoutから手動generator実行なしでbuildできる状態にする。

作業:

1. 採用OCaml generatorとatdtsを`ocaml-webui.opam`へ適切なbuild dependencyとして追加する。
2. `.atd`からOCaml targetとTypeScript targetを作るDune ruleを追加する。
3. generator versionはopam constraint、TypeScript/esbuildは`package-lock.json`で固定する。
4. generated fileは `_build`配下だけに作る。
5. source treeへ生成物が漏れないことを`git status --short`で確認する。
6. `dune clean`後の`dune build @all`をWindows/WSLで実行する。
7. `dune build @install`と`opam lint`を再実行する。

Gate C — reproducibility:

- Windows/WSLのclean build成功
- generatorの手動事前実行が不要
- repositoryに未追跡generated fileが残らない
- package install targetが必要schema/runtimeを含む

### Phase 3: typed OCaml Command integration

目的: mini-appから手書きpayload codecを除去する。

作業:

1. `Webui_bridge_atd`のtyped `Command.define`とtyped `Responder`を実装する。
2. generated `Text_analyze` moduleをcodec引数として渡す。
3. handler引数を`Yojson.Safe.t`からgenerated `text_analyze_request`へ変更する。
4. handler result/errorもgenerated型で構築する。
5. `delayMs`範囲とempty textはtyped decode後のapplication validationとして行う。
6. unknown Command、handler例外、Protocol mismatchはbridge共通errorとして維持する。
7. duplicate responseとWindow close cancellationはraw `Call.t`へ委譲する。

Gate D — OCaml typed boundary:

- mini-appにpayload fieldを直接`List.assoc_opt`するコードがない
- output/error JSON objectをhandlerが手組みしない
- malformed payloadはstructured `invalid_payload`
- handler例外はsanitized `internal_error`
- one-shot/cancel/root不変条件がbaselineと同じ

### Phase 4: generated TypeScript client integration

目的: TypeScript側のpayload型とruntime validationをATD生成物へ移す。

作業:

1. rootまたは専用web directoryに`package.json`、lockfile、strict `tsconfig.json`を追加する。
2. atdts生成moduleからrequest/result/error typeと`read*` / `write*`をimportする。
3. generic `defineCommand` clientを実装する。
4. `textAnalyze` descriptorはCommand名とgenerated codec参照だけを手書きする。
5. `@ts-expect-error` compile fixtureでwrong input field/typeを検出する。
6. Node runtime testでmalformed result/errorをgenerated readerがrejectすることを確認する。
7. esbuildでprobe clientをIIFEへbundleし、WebViewへ埋め込める単一JS artifactを作る。
8. bundleはDune targetとして生成し、OCaml spikeがruntimeに読み込む。

Gate E — TypeScript boundary:

- application codeがraw `ocamlWebui.invoke`を直接呼ばない
- request/result/error interfaceを手書きしない
- TypeScript compileでinput mismatchを検出する
- runtime readerでWebViewからの不正responseを検出する
- clean buildでbundleが再生成される

### Phase 5: Windows/WSLg end-to-end gate

目的: generated codec/clientを実native WebView pathで検証する。

baselineと同じケースを新しい`spikes/phase3-atd-command`で実行する。

1. valid `text.analyze`
2. empty text validation error
3. invalid delay
4. unknown Command
5. handler exception -> sanitized `internal_error`
6. duplicate response -> `Already_completed`
7. pending中のWindow close -> late response `Already_completed`
8. request ID / trace IDの往復一致
9. run終了・destroy後のpending Call / binding root / dispatch root 0
10. Linuxでは2 Windowを順次create/destroy

実行順:

```powershell
opam exec -- dune build @all
opam exec -- dune runtest test/command_schema
opam exec -- dune exec spikes/phase3-atd-command/main.exe
```

WSL:

```bash
opam exec --switch=ocaml-webui-linux -- dune build @all
opam exec --switch=ocaml-webui-linux -- dune runtest test/command_schema
opam exec --switch=ocaml-webui-linux -- \
  dune exec spikes/phase3-atd-command/main.exe
```

WSLgの既知EGL/Zink warningは許容する。GTK critical、uncaught JavaScript error、native
callback exception、root残留は失敗とする。

Gate F — runtime acceptance:

- Windows/WSLgの全ケースがexit 0
- baselineと同じwire JSON・error code
- generated TypeScript bundleを実際にWebView内で使用
- raw regressionに新規失敗なし

### Phase 6: baseline比較と判断

同じ測定方法で次を記録する。

| 指標 | baseline | ATD版 |
|---|---:|---:|
| handwritten reusable bridge行数 | 327 | 実測 |
| handwritten mini-app/client行数 | 321 | 実測 |
| protocol/codec test行数 | 86 | 実測 |
| generated OCaml行数 | 0 | 実測（参考） |
| generated TypeScript行数 | 0 | 実測（参考） |
| 1 Command追加時の手動同期箇所 | 4以上 | 実測 |
| Command名の手書き出現箇所 | 複数 | 実測 |
| 型不一致の検出時点 | runtime中心 | compile/codegen/runtime |

評価ではgenerated行数を「削減」として数えず、handwritten行数と同期箇所を主指標にする。

Gate G — 次工程判断:

- 採用:
  - input/output/errorの形が`.atd`だけで決まる
  - OCaml/TypeScript両方の不一致を自動testで検出できる
  - Command追加時の手動同期箇所が明確に減る
- 条件付き採用:
  - payload SSOTは成立するがCommand名/descriptor重複が残る
  - 次工程で既存generator/template手段を調査する
- 見送り:
  - annotationやadapterの手書き量がbaseline codecと同等以上
  - atdml/atdts間のwire差を個別patchで埋める必要がある
  - cross-platform buildが不安定

## 8. protocol envelopeとschema hashの扱い

payload SSOTがGate Gを通るまでProtocol v1 envelopeは手書きのまま維持する。

成功後のoptional Phase 7でのみ次を検討する。

1. `payload: abstract`を使ったrequest/response envelopeのATD化
2. `.atd`正規化結果からschema hashを作る方式
3. OCamlとTypeScriptへ同じhashを供給するbuild rule
4. WebView起動時handshake

schema hashはMVP必須だが、この工程で急いで独自generatorを作らない。payload SSOTの成立と
別のreview gateにする。

## 9. テストマトリクス

| Layer | Windows | WSLg | GUI不要 | 主な失敗条件 |
|---|---:|---:|---:|---|
| generator smoke | 必須 | 必須 | Yes | output/API差 |
| OCaml fixture codec | 必須 | 必須 | Yes | wire drift/例外漏れ |
| TypeScript typecheck | 必須 | 必須 | Yes | 型不一致未検出 |
| TypeScript runtime codec | 必須 | 必須 | Yes | malformed JSON受理 |
| Dune clean build | 必須 | 必須 | Yes | 手動生成依存 |
| WebView E2E | 必須 | 必須 | No | response/cancel/root不変条件 |
| raw regression | 必須 | 必須 | 一部 | 既存API退行 |

macOS/non-WSL Linuxは実機準備後にraw gateと合わせて追加し、ATD schema自体の実装を
待たせない。

## 10. リスクと対処

### atdmlがexperimental

対処: public generated interfaceを直接広範囲へ漏らさず、`command_schema` moduleと
codec adapterの内側へ隔離する。versionを`4.2.x`へ固定し、generated interface snapshotを
contract testに含める。問題が実害になる場合はatdgenへfallbackする。

### atdts文書が未完成

対処: 文書にないstrictness、unknown field、exception形状を推測せず、fixture testを
仕様とする。

### OCamlとTypeScriptのvalidation差

対処: ATDには構造だけを置く。範囲・業務validationはhandlerで行い、同じapplication error
として返す。language-specific validation annotationへ寄せない。

### Node toolchainがOCaml buildへ侵入する

対処: schema/OCaml libraryのbuildとfrontend bundle targetを分離する。GUI E2E targetだけが
Node toolchainを要求する構成を優先し、OCaml codec testをNode不在でも走らせられるか確認する。

### generated sourceの二重管理

対処: source treeへ生成物をcommitしない。例外が必要なら理由とfreshness checkを先に設計し、
ユーザー確認後に変更する。

### baselineとの比較が不公平になる

対処: baselineを削除・refactorせず固定する。ATD版も同じCommand、wire fixture、E2E case、
行数集計方法を使う。

## 11. commit単位

実装時はreview可能な次の単位を基本とする。

1. `Spike ATD OCaml generator compatibility`
   - Phase 0比較だけ。採用決定前のproduction API変更なし。
2. `Generate text analyze codecs from ATD`
   - schema、Dune rule、golden fixture、OCaml/TS codec test。
3. `Add typed ATD Command bridge`
   - typed Command/ResponderとOCaml mini-app移行。
4. `Run generated ATD client in WebView`
   - TypeScript client、bundle、Windows/WSLg E2E。
5. `Document ATD baseline comparison`
   - 実測、採否、次のschema hash gate。

各commit前に`git diff --check`、対象test、`dune build @all`を実行する。native/rawを変更した
場合だけraw実機probe一式を追加する。

## 12. 完了条件

次をすべて満たした時点でロードマップ手順3を完了とする。

- Gate A〜Gの結果が記録されている
- generator選定をユーザーが確認している
- `text.analyze`のinput/output/application errorが1つの`.atd`を正本としている
- OCamlとTypeScriptに手書きpayload型・codecが残っていない
- Protocol v1 wire互換fixtureが両言語で通る
- generated TypeScript clientがWindows/WSLgの実WebViewで動く
- duplicate/cancel/root不変条件がbaselineと同じ
- clean buildとpackage install targetが成功する
- baselineとの定量比較と採否が`docs/atd-command-ssot-results.ja.md`にある
- Context Mixerのcontextと改訂ロードマップは、実装結果をユーザー確認後に連鎖更新する

## 13. 公式参照

- [ATD project / feature support matrix](https://atd.readthedocs.io/en/latest/atd-project.html)
- [atdml reference](https://atd.readthedocs.io/en/latest/atdml.html)
- [atdgen tutorial](https://atd.readthedocs.io/en/latest/atdgen-tutorial.html)
- [atdgen reference](https://atd.readthedocs.io/en/latest/atdgen-reference.html)
- [atdts TypeScript support](https://atd.readthedocs.io/en/latest/atdts.html)
