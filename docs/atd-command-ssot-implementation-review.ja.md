# ATD Command SSOT 実装レビューと次期実行プラン

> **注意: これは初回レビューの記録である。指摘事項は全て修正済み。**
> **最新状態は `docs/atd-command-ssot-results.ja.md` および**
> **`docs/atd-command-ssot-followup-review.ja.md` を参照のこと。**

レビュー日: 2026-07-20

対象:

- `lib/command_schema/`
- `lib/bridge_atd/`
- `spikes/phase3-atd-command/`
- `test/command_schema/`
- `test/bridge_atd/`
- `web/phase3-atd-command/`
- `docs/atd-command-ssot-results.ja.md`

## 1. 結論

今回の実装は、ATD schemaから生成したOCaml型・codecをtyped Command bridgeへ接続し、
Windows WebView2とWSL2/WSLgの実native WebView pathで動作させるところまで到達している。
OCaml/native側の縦切りとしては有効であり、`atdml + atdts`を継続評価できる結果である。

ただし、現時点の判定は**条件付き合格**とする。`docs/atd-command-ssot-results.ja.md`に
記載された「Phase 0〜5の全ゲート通過」「Protocol v1完全互換」「本格採用」は、次の理由で
まだ確定できない。

1. application errorのwire JSONがhandwritten baselineから変わっている。
2. generated TypeScript client、esbuild bundle、WebViewへの実接続が未実装である。
3. OCamlの一部否定テストが退行を検出できない。
4. `node_modules`がGit ignoreされていない。
5. Gate Gで要求した定量比較が完了していない。

したがって、このまま一括コミットしてATD採用を確定するのではなく、wire互換性とテストを
先に修正し、その後TypeScriptからWebViewまでの縦切りを完成させるのがよい。

## 2. 実装できている内容

### 2.1 Schemaと再現可能なOCaml codegen

`lib/command_schema/text_analyze.atd`をpayload schemaの正本として、次の型を定義している。

- `text_analyze_request`
- `text_analyze_result`
- `text_analyze_error_code`
- `text_analyze_error`

`lib/command_schema/dune`から`atdml`と`atdts`を呼び出し、生成物を`_build/`配下へ出力する。
生成されたOCaml libraryは`ocaml-webui.command-schema`としてtyped bridgeから利用できる。

確認した生成物規模は次のとおり。

| 生成物 | 行数 |
|---|---:|
| `text_analyze.ml` | 308 |
| `text_analyze.mli` | 84 |
| `text_analyze.ts` | 485 |

ソース側の`lib/command_schema/`には`.atd`とDune ruleだけがあり、生成された`.ml/.mli/.ts`の
漏出はなかった。

### 2.2 Typed OCaml Command bridge

`Webui_bridge_atd`には次の境界が実装されている。

- input/output/error codecを束ねる型付きcodec record
- input/output/error型を保持するCommand GADT
- 異なるCommandをregistryへ格納するexistential package
- typed `responder_resolve`、`responder_reject`、`responder_cancel`
- ATD decode例外の`invalid_payload`への変換
- handler例外のsanitized `internal_error`への変換
- duplicate Command検出
- raw bindingのone-shot responseとWindow close cancellationの再利用

`spikes/phase3-atd-command/main.ml`のhandlerは、payload fieldを`List.assoc_opt`で読むことなく、
生成された`text_analyze_request`を受け取っている。成功結果とapplication errorも生成型で構築
しているため、OCaml handler内部から手書きpayload JSONを除去する目的は達成している。

### 2.3 Native WebView E2E

Windows WebView2とWSL2/WSLgの両方で次を確認した。

- valid `text.analyze`
- empty text validation
- unknown Command
- handler exception
- malformed payload
- duplicate responseの`Already_completed`
- pending中のWindow closeとlate responseの`Already_completed`
- request ID / trace IDの往復
- destroy後のpending Call / binding root / dispatch root 0
- Windowをsuccess phase、cancel phaseの順に作成・破棄

WSLgでは既知のEGL/Zink fallback warningが出たが、GTK critical、uncaught JavaScript error、
native callback exception、root残留は発生しなかった。

## 3. 再検証結果

### 3.1 Windows

| コマンド | 結果 | 注記 |
|---|---|---|
| `opam exec -- dune build @all` | 成功 | ATD生成とOCaml buildを含む |
| `opam exec -- dune runtest` | 成功 | ただし4.2節の無効な否定テストを含む |
| `opam exec -- dune build @install` | 成功 | OCaml libraryのinstall artifactを確認 |
| `opam exec -- dune exec spikes/phase3-atd-command/main.exe` | 成功 | WebView2 E2E |
| `opam lint ocaml-webui.opam` | 成功 | homepage、bug-reports、licenseの既存warningのみ |

Windows E2Eの最終出力:

```text
atd_bridge: passed success validation unknown handler_error duplicate cancel malformed roots=0
```

### 3.2 WSL2/WSLg

既存の`ocaml-webui-linux` switchには今回のATD依存が未導入だったため、検証用に次を導入した。

- `atd 4.2.0`
- `atdml 4.2.0`
- `atdts 4.2.0`

Windows workspaceから`.git`、`_build`、`_opam`、`node_modules`を除外してWSL ext4上の一時
ディレクトリへ同期し、clean状態から次を実行した。

| 検証 | 結果 |
|---|---|
| `dune build @all` | 成功 |
| `dune runtest` | 成功 |
| `dune build @install` | 成功 |
| Phase 3 WebView E2E | 成功 |

検証用一時ディレクトリは終了後に削除した。

### 3.3 TypeScript generator単体

リポジトリの`web/phase3-atd-command/`から直接`tsc`を実行すると、次のエラーになる。

```text
ts_codec_test.ts(14,8): error TS2307:
Cannot find module './text_analyze.js' or its corresponding type declarations.
```

一方、`_build/default/lib/command_schema/text_analyze.ts`を検証用`_build`ディレクトリへ手動で
接続した場合は、次がすべて成功した。

- TypeScript strict typecheck
- esbuildによるNode向けbundle
- Node上のcodec runtime test

最終出力:

```text
ts_codec_test: passed round-trip decode variant unknown-field
```

この結果から、`atdts`の生成物自体は利用可能だが、生成物をfrontend buildへ渡す再現可能な
pipelineが不足していると判断する。

## 4. レビュー指摘

### 4.1 P1: application errorのwire互換性が失われている

対象: `lib/bridge_atd/webui_bridge_atd.ml`の`responder_reject`

handwritten baselineはapplication validation errorを次の形で返す。

```json
{
  "protocol": 1,
  "ok": false,
  "error": {
    "code": "empty_text",
    "message": "text must not be empty",
    "retryable": false,
    "category": "validation"
  }
}
```

ATD版は生成されたerror全体を`details`へ入れ、top-level codeを固定値へ変更している。

```json
{
  "protocol": 1,
  "ok": false,
  "error": {
    "code": "application_error",
    "message": "application error",
    "retryable": false,
    "category": "application",
    "details": {
      "code": "empty_text",
      "message": "text must not be empty",
      "retryable": false,
      "category": "validation"
    }
  }
}
```

新しいE2Eも`error.code = application_error`と`error.details.code = empty_text`を期待しており、
baselineとのparityを検証せず、変更後の形式を正としている。

影響:

- Protocol v1の既存consumerが`error.code`を読めなくなる。
- planned TypeScript `readTextAnalyzeError`を`response.error`へ直接適用できない。
- 「application errorもATD schemaが正本」という目的がresponse envelope上で成立しない。
- 実装結果レポートの「完全なwire互換性」が事実と一致しない。

修正方針:

1. protocol/internal errorとapplication errorのencoder経路を分ける。
2. typed `responder_reject`では生成されたerror JSONを`error` fieldへ直接置く。
3. baseline error fixtureとATD error fixtureを構造比較する。
4. renderer E2Eの期待値を`error.code = empty_text`へ戻す。

### 4.2 P1: TypeScript typed clientとWebView bundleが未実装

計画では次をGate E/Fの完了条件としていた。

- generic `defineCommand`
- generated request writer / result reader / error reader
- `textAnalyze` descriptor
- wrong inputをcompile時に検出するfixture
- malformed native responseをruntime readerがrejectするtest
- esbuild IIFE bundleのDune target
- 実WebView内でgenerated bundleを使用するE2E

現在の`web/phase3-atd-command/`には`package.json`、lockfile、`tsconfig.json`、codec testしかなく、
generic clientとCommand descriptorは存在しない。Phase 3 spikeはOCaml文字列内の手書き
`ocamlWebui.invoke`を直接使用している。

`spikes/phase3-atd-command/dune`のTypeScript ruleも、生成TSをspikeの`_build`ディレクトリへ
copyするだけで、typecheck、bundle生成、OCamlへの埋め込みを行っていない。

したがって、現状で通っているWebView E2Eは「generated OCaml codecを通るnative bridge」の
E2Eであり、「generated TypeScript clientからnative bridgeまで」のE2Eではない。

### 4.3 P1: OCaml否定テストが退行を検出しない

`test/command_schema/ocaml_codec_test.ml`には次の形式が繰り返されている。

```ocaml
try
  let _ = decode invalid_json in
  fail "input should fail"
with _ -> ()
```

decoderが例外を投げた場合だけでなく、decoderが不正入力を受理して`fail`へ進んだ場合も、
その`Failure`を同じ`with _`が捕捉する。このためtestは常に成功する。

`test/bridge_atd/protocol_test.ml`のduplicate Command testにも同じ問題がある。さらに
`Obj.magic 0`をWindowとして渡し、duplicate未検出時のinvalid accessも成功扱いにするため、
本来の契約を検証できない。

修正方針:

```ocaml
let expect_raises label f =
  match f () with
  | exception _ -> ()
  | _ -> fail (label ^ " — expected exception")
```

duplicate Commandは`install`を呼ぶ前のregistry構築をtest可能にするか、有効なWindowを作成して
結果を直接pattern matchする。少なくともtest自身のassertion exceptionを期待例外として
捕捉してはいけない。

### 4.4 P2: `node_modules`がGit管理候補に入っている

root `.gitignore`には`node_modules`規則がない。レビュー時点で次を確認した。

- untracked `node_modules` file: 685
- 合計サイズ: 45,251,928 bytes
- `git status --short --untracked-files=all`: 706 entries

この状態で`git add web`や`git add .`を実行すると依存物をコミットする可能性がある。

修正方針:

```gitignore
node_modules/
```

必要なら対象を`/web/**/node_modules/`へ限定する。`package-lock.json`は追跡する。

### 4.5 P2: E2Eシナリオが計画を完全には覆っていない

handlerには`delay_ms < 0 || delay_ms > 2000`の検証があるが、renderer E2Eからinvalid delayを
送るケースがない。現在の`validation`表示はempty textだけを指す。

追加すべきcase:

- `{ text: "valid", delayMs: -1 }`
- `error.code = invalid_delay`
- `error.category = validation`
- request ID / trace IDの一致

### 4.6 P2: 実装結果レポートが完了状態を過大評価している

`docs/atd-command-ssot-results.ja.md`は次を記載している。

- Phase 0〜5の全ゲート通過
- TypeScript client integration完了
- baselineと完全なwire互換性
- clean build・全テスト・E2E gate通過
- ATD SSOTを本格採用

しかし4.1〜4.5の理由により、現時点で妥当なのは次の表現である。

> atdml + atdtsは条件付き採用候補。OCaml typed bridgeと両OSのnative E2Eは成立した。
> application error wire parity、否定テスト、generated TypeScript client/bundleを完了後に
> Gate Gの最終採否を行う。

また、Gate Gで予定していたhandwritten行数、同期箇所数、Command名の重複箇所などの実測値を
結果レポートへ追加する必要がある。

## 5. 次の実行プラン

### Step 1: wire error契約を修正する

目的: Protocol v1とhandwritten baselineのapplication error互換性を回復する。

作業:

1. typed application errorをtop-level `error`へ直接encodeするAPIを追加する。
2. protocol/internal error用の`Error.t`経路は維持する。
3. empty textとinvalid delayの期待JSONをfixture化する。
4. baselineとATD版をJSON parse後に構造比較する。
5. WebView E2Eのvalidation assertionをbaseline形式へ戻す。

完了条件:

- `error.code = empty_text`または`invalid_delay`
- `details` wrapperなし
- generated `readTextAnalyzeError(response.error)`が成功
- protocol/internal errorの既存形式は不変

### Step 2: contract testを信頼できる状態にする

目的: codec/registry退行を確実に検出する。

作業:

1. OCamlに共通`expect_raises` helperを追加する。
2. missing field、wrong type、unknown variantのtestを書き換える。
3. duplicate testから広すぎる`with _`と`Obj.magic`を除く。
4. application error envelope testを追加する。
5. 一時的にvalid/invalidを反転させ、testが実際に失敗することを確認して元へ戻す。

完了条件:

- decoderが不正入力を受理すると対象testが非0終了する
- duplicate未検出時にtestが非0終了する
- assertion failureを期待例外として捕捉しない

### Step 3: TypeScript typed clientを実装する

目的: application codeからraw `ocamlWebui.invoke`と手書きpayload型を除去する。

成果物候補:

```text
web/phase3-atd-command/
├─ client.ts
├─ text_analyze_command.ts
├─ probe.ts
├─ ts_codec_test.ts
├─ type_contract_test.ts
├─ package.json
├─ package-lock.json
└─ tsconfig.json
```

作業:

1. `defineCommand<Input, Output, AppError>`を実装する。
2. request送信前にgenerated writerを通す。
3. native successをgenerated result readerへ通す。
4. native application errorをgenerated error readerへ通す。
5. protocol/internal errorとapplication errorをTypeScript側で区別する。
6. `textAnalyze` descriptorにはCommand名とgenerated codec参照だけを置く。
7. `@ts-expect-error`でwrong field/typeのcompile contractを固定する。
8. malformed result/errorのruntime rejection testを追加する。

完了条件:

- probe applicationがraw `ocamlWebui.invoke`を直接呼ばない
- request/result/error interfaceを手書きしない
- input mismatchは`tsc`で検出する
- malformed native responseはgenerated readerがrejectする

### Step 4: codegenからWebView bundleまでをDune target化する

目的: clean checkoutから手動copyなしで同じbundleを生成する。

pipeline:

```text
text_analyze.atd
  -> atdts
  -> generated text_analyze.ts
  -> TypeScript typed client/probe
  -> esbuild IIFE bundle
  -> OCaml spikeがbundleを読み込む
  -> Window.init
```

作業:

1. root `.gitignore`へ`node_modules/`を追加する。
2. `package.json`へ`typecheck`、`test`、`bundle` scriptを追加する。
3. lockfileを使う`npm ci`手順を記録する。
4. Dune ruleから生成TSをfrontend build contextへ渡す。
5. esbuild IIFE bundleを`_build`配下だけに生成する。
6. OCaml spikeからbundle内容を読み込み、`Window.init`へ渡す。
7. hand-written `client_javascript`をATD spikeのruntime pathから外す。

完了条件:

- clean buildでgenerated TSとbundleが再生成される
- source treeへgenerated fileが出ない
- repo上の標準コマンドで`tsc`が成功する
- WebViewが実際に生成bundleを実行する

### Step 5: Windows/WSLgの最終Gate Fを再実行する

両環境で次を実行する。

```text
dune build @all
dune runtest
dune build @install
dune exec spikes/phase3-atd-command/main.exe
```

E2E case:

1. valid request
2. empty text
3. invalid delay
4. malformed payload
5. unknown Command
6. handler exception
7. malformed native result/errorのTypeScript rejection
8. duplicate response
9. pending close cancellation
10. identity往復
11. destroy後root 0
12. Linux sequential Window recreate

WindowsとWSLgの両方でgenerated TypeScript bundleを使用し、全caseがexit 0になった時点で
Gate F通過とする。

### Step 6: Gate G、ドキュメント、コミット

実測する項目:

| 指標 | baseline | ATD版 |
|---|---:|---:|
| handwritten reusable bridge行数 | 実測 | 実測 |
| handwritten mini-app/client行数 | 実測 | 実測 |
| protocol/codec test行数 | 実測 | 実測 |
| generated OCaml行数 | 0 | 実測、参考値 |
| generated TypeScript行数 | 0 | 実測、参考値 |
| 1 Command追加時の手動同期箇所 | 実測 | 実測 |
| Command名の手書き出現箇所 | 実測 | 実測 |
| 型不一致の検出時点 | runtime中心 | compile/codegen/runtime |

判定:

- Gate B〜Fがすべて通ればATD payload SSOTを採用する。
- Command名/descriptorの重複だけが残る場合は条件付き採用とし、独自generatorはまだ作らない。
- atdml/atdts間のwire差を手書きadapterで大量補正する必要が出た場合は再評価する。

推奨commit単位:

1. `Restore ATD application error wire parity`
2. `Make ATD contract failures observable`
3. `Bundle generated ATD client for WebView`
4. `Document ATD SSOT acceptance results`

各commit前に対象test、`dune build @all`、`git diff --check`を実行する。最終結果をユーザーが
確認した後、Context Mixerのspec、context、必要なdecisions/notesを連鎖更新する。

## 6. 現在の管理上の注意

今回のATD実装一式はレビュー時点で未コミットであり、HEADは次のままである。

```text
36a803c Add handwritten Command bridge baseline
```

特に`node_modules`をignoreする前に`git add web`または`git add .`を実行しないこと。
既存変更とATD実装を意図したcommit単位へ分け、生成物・依存ディレクトリがstageされていない
ことを毎回確認する。
