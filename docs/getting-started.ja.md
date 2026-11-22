# はじめに — ocaml-webuiをライブラリとして使う

新規アプリの想定経路: OCaml宣言ファイル（`commands.ml`）→ 生成
`.atd`スキーマ + codec + OCaml登録コード + 生成TypeScript client。
`examples/typed-hello` と同じ構成なので、並べて読んでください。

> Prototype status: `--decl` 宣言経路は Phase 2 proof-of-concept です。
> JSON manifest（`--manifest commands.json`、
> [commands-manifest.ja.md](commands-manifest.ja.md) 参照）は中間表現の
> 入力として引き続きサポートされます。どちらもAPI freeze前に変更の
> 可能性があります。

## 1. インストール

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam pin add ocaml-webui .
opam install ocaml-webui
```

素の `git+https` pin では `vendor/webview` submodule が取れません —
上記のlocal-path pinを使ってください。

## 2. 構成

```
myapp/
  schema/
    dune               # 生成.atdをコピー、atdml + atdts rule、schema library
  bin/
    dune               # command-gen + emit-client + esbuild + embed rule
    commands.ml        # Command + payload型宣言（SSOT。parseのみ、compileしない）
    main.ml            # window + handlers record（唯一人が書くコード）
    gen_bundle_embed.ml
  web/
    package.json       # esbuild + typescript
    esbuild-wrapper.mjs
    main.ts            # 生成client + descriptorをimport
```

## 3. 宣言（`bin/commands.ml`）

型宣言は制限OCaml構文（record・通常variant・alias・`int`/`float`/
`string`/`bool`・`list`・`option`・名前付き型参照）、Command宣言は
`let x = command ...` 適用式。`command-gen` がparseするだけで、
アプリにはcompileされません。

```ocaml
[@@@schema_module "Myapp_schema.Myapp"]
[@@@ts_module "./myapp.js"]

type ping_request = { message : string }
type ping_response = { echoed : string ; length : int }
type ping_error = {
  code : string;
  message : string;
  retryable : bool;
  category : string;
}

let ping = command "app.ping" ~mode:"sync"
  ~input:ping_request ~output:ping_response ~error:ping_error
```

- `~input`/`~output`/`~error` は文字列ではなく**型識別子**を取る。
- wire名は自動変換: record field `snake_case` → `camelCase`、
  variant constructor `CamelCase` → `snake_case`。field/constructor毎に
  `[@json "wireName"]` で上書き可能。
- file-level `[@@@schema_module]`/`[@@@ts_module]` が既定値。
  `~schema_module`/`~ts_module` でcommand毎に上書き可能。
- `~kind:"raw_json"`（`~ts_output_type`/`~ts_type_decls` 併用）で
  schema無しのpassthrough Commandを宣言。
- 非対応構文（関数型・polymorphic variant・GADT・未宣言型参照・
  副作用式など）は `file:line:col: error: 理由` でreject。

生成 `.atd` は通常通り `atdml`/`atdts` へ — `atdml` は
`ping_request_of_yojson` / `yojson_of_ping_response` /
`yojson_of_ping_error` を、`atdts` はTypeScriptの対応物を生成します。
field名は両言語ともOCaml `snake_case`。wire上のJSONは
`<json name="...">` の通りになります。

## 4. Dune rule

```lisp
;; bin/dune — .atd + 登録コード + descriptorを一括生成
(rule
 (targets myapp.atd commands_gen.ml commands_gen.ts)
 (deps commands.ml)
 (action
  (run ocaml-webui.command-gen --decl commands.ml --atd myapp.atd
   --ocaml commands_gen.ml --ts commands_gen.ts)))

;; canonical runtime client（emitされたファイルは編集しない）
(rule (targets client.ts)
  (action (run ocaml-webui.command-gen --emit-client client.ts)))

;; schema libraryのTS codecをbuild dirへ
(rule (targets myapp.ts)
  (deps ../schema/myapp.ts)
  (action (copy ../schema/myapp.ts myapp.ts)))
```

```lisp
;; schema/dune — atdml/atdtsは入力ファイルの隣に出力するため、
;; 生成.atdを先にこのdirへコピーする
(rule (targets myapp.atd)
  (deps ../bin/myapp.atd)
  (action (copy ../bin/myapp.atd myapp.atd)))

(rule (targets myapp.ml myapp.mli)
  (deps myapp.atd)
  (action (run atdml myapp.atd)))

(rule (target myapp.ts)
  (deps myapp.atd)
  (action (run atdts %{deps})))

(library (name myapp_schema) (libraries yojson) (modules myapp))
```

生成物は全て `_build/` 配下 — source treeへはemitしないでください。
TS editorでimport解決させるには先に `dune build` が必要です。

## 5. Handler（`bin/main.ml`）

`commands_gen.ml` は `handlers` recordを公開 — 宣言した全Commandが
必須fieldなので、書き忘れるとcompile errorになります。各handlerを
書いてinstallします:

```ocaml
module Bridge = Webui_bridge_atd
module Schema = Myapp_schema.Myapp

let ping_handler _context (request : Schema.ping_request) responder =
  ignore
    (Bridge.responder_resolve responder
       { Schema.echoed = request.message;
         length = String.length request.message })

let trace_sink, _ = Webui_trace.ring_buffer ~capacity:256

let () =
  let window =
    match Webui_raw.Window.create { debug = false } with
    | Ok w -> w | Error e -> failwith (Webui_raw.Error.to_string e)
  in
  (match Bridge.install ~trace:trace_sink window
           ~commands:(Commands_gen.commands { Commands_gen.ping = ping_handler })
   with Ok _ -> () | Error _ -> assert false);
  (* esbuild bundleをset_htmlし、Window.run / destroy へ *)
  ()
```

- sync（`~mode:"sync"`）handler: `context -> input -> responder -> unit`
- async（`~mode:"async"`）handler: `context -> input -> responder ->
  cancellation_token -> unit` — worker domain上で実行。checkpointで
  tokenをpoll。応答せずreturnするとbridgeが `cancelled` でreject。
  `~timeout_ms` はwatchdogとして働く。

## 6. TypeScript（`web/main.ts`）

```ts
import { invokeCommand, cancelCommand,
         ProtocolError, ApplicationError } from "./client.js";
import { appPing } from "./commands_gen.js";

const result = await invokeCommand(appPing, { message: "hi" });
// typed result: PingResponse
// typed error:  catch ApplicationError -> e.typedError: PingError
// protocol:     catch ProtocolError -> e.code / e.category / e.retryable
```

`cancelCommand(requestId, traceId)` は実行中のasync requestへv1 cancel
envelopeを送ります。`traceId`/`requestId` はOCaml側の統一traceへ
そのまま現れます — それがこのruntimeの要点です。

## 7. 残っている手作業 / 既知の制限

- `commands.ml` はparseのみ — OCaml compilerによるtypecheckはなく、
  `command` 形式のeditor/Merlin対応もない（Phase 2継続候補）。
- JS→OCaml event pushは未実装 — Commandのみ。
- Linux backend: 同時にliveにできるWindowは1つ、初期thread上で作成。
- `commands_gen.ts` は `./client.js` をimport — emit clientは同一
  出力dirで `client.ts` の名前にすること。
- 生成 `commands_gen.ml` のmodule名は `Commands_gen` — executableの
  `modules` に含めること。
