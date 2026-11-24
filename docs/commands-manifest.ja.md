# commands.json — Command manifest リファレンス

`ocaml-webui.command-gen` の入力。1エントリ = 1 Command。生成される
もの: OCaml登録コード（`--ocaml`）、TypeScript descriptor（`--ts`）、
canonical runtime client（`--emit-client`）。

```
ocaml-webui.command-gen --manifest <json> --ocaml <out.ml> --ts <out.ts> [--emit-client <out.ts>]
ocaml-webui.command-gen --emit-client <out.ts>
```

スキーマ: `tool/command_gen/command_manifest.atd`

## `--decl` との関係

両入力は長期的に併存する:

- `--decl commands.ml` — 人が書くための宣言経路。新規アプリの推奨。
  `.atd` スキーマをemitしつつ下記と同じmanifest IRへ送る。
- `--manifest commands.json` — 中間表現。ツール・テスト・manifestを
  機械生成する用途向けに維持。

等価な入力からは byte-identical な `commands_gen.ml`/`commands_gen.ts`
が生成される（fixtureで検証済み）。`--manifest` のdeprecation計画は
ない — 旧形式ではなく、別レイヤーの入力である。

> 代替入力: `--decl <commands.ml> --atd <out.atd>` で制限OCaml構文の
> 宣言ファイル（payload型 + `command` 適用式）をparseし、`.atd`
> スキーマをemitしつつ同じmanifest IRへ送る — `--ocaml`/`--ts` 出力は
> 等価なmanifestと同一になる。`examples/typed-hello` がこの経路。
> 宣言構文は [getting-started.ja.md](getting-started.ja.md) 参照。

## トップレベル

```json
{ "commands": [ <command>, ... ] }
```

## Commandフィールド

| フィールド | 型 | 必須 | 意味 |
|---|---|---|---|
| `name` | string | はい | wire上のCommand名（例 `"app.ping"`）。OCaml record field名とTS export名へ機械変換される（`app.ping` → `app_ping` / `appPing`）。 |
| `kind` | string | 既定 `"atd"` | `"atd"` — atdml/atdts codecに依る型付きCommand。`"raw_json"` — passthrough: input `unit`、output `Yojson.Safe.t`、error `string`（`trace.recent` のようなdebug Command向け）。 |
| `schemaModule` | string | kind=atd | atdml生成codecを含むOCaml module path（例 `"Usage_schema.Usage_refresh"`）。 |
| `input` | string | kind=atd | ATDのinput型名。codec関数名は atdml 規約から導出: `<input>_of_yojson`、`yojson_of_<output>`、`yojson_of_<error>`。 |
| `output` | string | kind=atd | ATDのresult型名。 |
| `error` | string | kind=atd | ATDのtyped-error型名。 |
| `mode` | string | 既定 `"sync"` | `"sync"` → `Bridge.define`（handlerはdispatch thread上）。`"async"` → `Bridge.define_async`（worker domain上、`cancellation_token`受取）。 |
| `timeoutMs` | int | asyncのみ | watchdog deadline（ms）。超過で `timeout`（retryable）reject。workerは生き続けるが応答は破棄される。 |
| `tsModule` | string | kind=atd | 生成TS側で atdts 生成moduleをimportするパス（例 `"./usage_refresh.js"`）。 |
| `tsOutputType` | string | kind=raw_json | descriptorの `O` ジェネリクスに使うTS result型名。 |
| `tsTypeDecls` | string | kind=raw_json | `commands_gen.ts` へそのまま出力するTS型宣言（`tsOutputType` をここで定義する）。 |

## 生成OCaml — 人が用意するもの

`commands_gen.ml` が出力するもの:

```ocaml
type handlers = {
  app_ping : Bridge.context -> Schema.ping_request ->
    (Schema.ping_response, Schema.ping_error) Bridge.responder -> unit;
  (* async Command は最後の引数に Bridge.cancellation_token *)
  (* raw_json Command は unit input と (Yojson.Safe.t, string) responder *)
}

val commands : handlers -> Bridge.packed_command list
```

- manifestの全Commandが**必須record field** — handler欠落は
  `Some record fields are undefined: <field>` でコンパイルエラー。
- `commands h` はmanifest全件を含む — `pack`忘れは構造的に不可能。
- wire `name`、codec、`define`/`define_async`、`timeout_ms` はmanifest
  由来。人が書くのはhandler本体のみ。

## 生成TypeScript

`commands_gen.ts` はCommand毎に `CommandDescriptor<I, O, E>` const を
export + raw_json分の `tsTypeDecls`。codec関数を `tsModule` から、
`defineCommand` を `./client.js` からimportする — client
（`--emit-client client.ts`）は同じdirにemitすること。

raw_json descriptorは `CommandDescriptor<null, tsOutputType, never>` —
`invokeCommand(descriptor, null)` で呼ぶ。

## Protocol version

emitされるclient・生成descriptorは **protocol v1**:

```json
invoke:   { "protocol":1, "requestId":"..", "traceId":"..",
            "command":"app.ping", "payload":{...} }
response: { "protocol":1, "requestId":"..", "traceId":"..",
            "command":"app.ping", "ok":true, "value":{...} }
          | { ..., "ok":false, "error":{"code","message","retryable","category"} }
cancel:   { "protocol":1, "kind":"cancel", "requestId":"..",
            "traceId":"..", "targetRequestId":".." }
```

`client.js` は `protocol` 不一致で `ProtocolError` を投げる — OCaml
パッケージと emit client を同じpinで管理すれば同期が保たれる。

## 補足・制約

- `kind:"atd"` では `schemaModule`/`input`/`output`/`error`/`tsModule`
  が必須。`kind:"raw_json"` はそれらを無視し `tsOutputType` +
  `tsTypeDecls` を使う。
- TS側のフィールド名は snake_case のまま（atdts規約）。wire名は
  `.atd` の `<json name>` 注釈由来。
- `name` の重複検出は無い — wire名はユニークに保つこと。
- OCaml宣言入力（`--decl commands.ml`）が新規アプリの推奨経路。
  manifestはその経路が生成する中間表現として維持される設計。
