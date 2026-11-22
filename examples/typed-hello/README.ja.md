# examples/typed-hello

宣言駆動Commandパイプラインの参照実装 — ocaml-webui上にアプリを
作るときの想定経路。

```
bin/commands.ml ──command-gen --decl──> hello.atd ──atdml/atdts──> OCaml + TS codec
                                  └──> commands_gen.ml + commands_gen.ts
                └──--emit-client──> client.ts（canonical protocol v1 client）
web/main.ts + 生成ファイル ──esbuild──> main.bundle.js ──embed──> main.exe
```

| Command        | 実演内容                                                        |
|----------------|------------------------------------------------------------------|
| `hello.ping`   | sync ATD Command。型付き validation error（`empty_message`/`too_long`） |
| `work.count`   | worker domain上のasync Command。`cancellation_token` checkpoint、JS cancel、30s watchdog |
| `trace.recent` | 統一trace ring bufferを読む `raw_json` Command                     |

人が書くのは `commands.ml`（payload型 + Command宣言）・handler本体・
TSのUI — 残りは全て生成物。`commands.ml` は `command-gen` がparseする
だけで、アプリにはcompileされない。

## 実行

```bash
cd web && npm ci && cd ..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

headless検証には `OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS=<ms>` で指定ms後に
window closeできる。

## ファイル

- `bin/commands.ml` — payload型 + Command宣言（SSOT）。
- `bin/main.ml` — window + 実装対象の `handlers` record。
- `bin/dune` — codegen + bundle + embed rule（アプリ側の雛形）。
- `schema/dune` — 生成された `hello.atd` をコピーし atdml/atdts を実行。
- `web/main.ts` — emit client + 生成descriptorをimport。
- `web/esbuild-wrapper.mjs` — esbuild JS-API wrapper（cross-platform）。
