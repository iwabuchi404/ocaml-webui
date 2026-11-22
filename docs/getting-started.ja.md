# Getting started — ocaml-webui をライブラリとして使う

新規アプリの想定経路: ATDスキーマ + command manifest → 生成OCaml登録
コード + 生成TypeScript client。`examples/typed-hello` と併読する前提。

> Prototype扱い: これは v0.1 の manifest駆動経路。最終的なSSOTは
> OCaml宣言起点の生成（Phase 2、未決定）であり、下記のmanifest形式は
> 中間段階で、将来差し替わる可能性がある。

## 1. インストール

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam pin add ocaml-webui .
opam install ocaml-webui
```

素の `git+https` pin は `vendor/webview` submodule を取得しないため、
上記のローカルパスpinを使う。

## 2. 構成

```
myapp/
  schema/
    dune               # atdml + atdts のrule、スキーマlibrary
    myapp.atd          # Command payload型のSSOT
  bin/
    dune               # command-gen + emit-client + esbuild + embed rule
    commands.json      # Command manifest（docs/commands-manifest.ja.md参照）
    main.ml            # window + handlers record（人が書くのはここだけ）
    gen_bundle_embed.ml
  web/
    package.json       # esbuild + typescript
    esbuild-wrapper.mjs
    main.ts            # 生成client + 生成descriptorをimport
```

## 3. スキーマ（`schema/myapp.atd`）

```atd
type ping_request = { message: string; }
type ping_response = { echoed: string; length: int; }
type ping_error = {
  code: string;
  message: string;
  retryable: bool;
  category: string;
}
```

`atdml` が `ping_request_of_yojson` / `yojson_of_ping_response` /
`yojson_of_ping_error` を、`atdts` がTypeScript対応物を生成する。
フィールド名は両言語とも OCaml `snake_case`。wire上のJSONは
`<json name="...">` 注釈に従う。

## 4. Manifest（`bin/commands.json`）

```json
{
  "commands": [
    {
      "name": "app.ping",
      "schemaModule": "Myapp_schema.Myapp",
      "input": "ping_request",
      "output": "ping_response",
      "error": "ping_error",
      "mode": "sync",
      "tsModule": "./myapp.js"
    }
  ]
}
```

全フィールド: [commands-manifest.ja.md](commands-manifest.ja.md)。

## 5. Dune rules（`bin/dune`）

```lisp
;; スキーマlibraryのTS codecをbuild dirへ
(rule (targets myapp.ts)
  (deps ../schema/myapp.ts)
  (action (copy ../schema/myapp.ts myapp.ts)))

;; canonical runtime clientのemit（出力は編集しない）
(rule (targets client.ts)
  (action (run ocaml-webui.command-gen --emit-client client.ts)))

;; manifest → OCaml登録コード + TS descriptor
(rule (targets commands_gen.ml commands_gen.ts)
  (deps commands.json)
  (action
    (run ocaml-webui.command-gen --manifest commands.json
     --ocaml commands_gen.ml --ts commands_gen.ts)))

;; webソースのcopy → esbuild bundle → OCaml文字列埋め込み
;; （完成形は examples/typed-hello/bin/dune を参照）
```

生成物は全て `_build/` 配下 — source treeへemitしない。
TSエディタで生成importを解決するには先に `dune build` を実行する。

## 6. Handler（`bin/main.ml`）

`commands_gen.ml` は `handlers` recordを出力 — manifestの全Commandが
必須フィールドなので、欠ければコンパイルエラーになる。

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
  (* esbuild bundleをset_htmlし、Window.run / destroy *)
  ()
```

- sync（`mode:"sync"`）handler: `context -> input -> responder -> unit`
- async（`mode:"async"`）handler: `context -> input -> responder ->
  cancellation_token -> unit` — worker domainで実行。checkpointで
  tokenをpollし、応答せずreturnすればbridgeが `cancelled` でrejectする。
  manifestの `timeoutMs` はwatchdogとして働く。

## 7. TypeScript（`web/main.ts`）

```ts
import { invokeCommand, cancelCommand,
         ProtocolError, ApplicationError } from "./client.js";
import { appPing } from "./commands_gen.js";

const result = await invokeCommand(appPing, { message: "hi" });
// result: PingResponse（型付き）
// 型付きerror:  ApplicationError をcatch → e.typedError: PingError
// protocol系:   ProtocolError をcatch → e.code / e.category / e.retryable
```

`cancelCommand(requestId, traceId)` で実行中のasync requestへv1 cancel
envelopeを送る。`traceId`/`requestId` はOCaml側の統一traceにそのまま
現れる — これがこのruntimeの要点。

## 8. まだ手動な部分・既知の制約

- `.atd` と `commands.json` の2ファイル同期は手作業（Phase 2で解消予定）
- JS→OCaml event push は未実装 — Commandのみ
- Linux backend: 同時Windowは1つ、`Window.create`は初期スレッド上
- `commands_gen.ts` は `./client.js` をimport — emitしたclientは同じ
  出力dirに `client.ts` という名前で置くこと
- 生成 `commands_gen.ml` のmodule名は `Commands_gen` — executableの
  `modules` に含めること
