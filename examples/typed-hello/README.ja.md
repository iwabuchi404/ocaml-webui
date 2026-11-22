# examples/typed-hello

manifest駆動Commandパイプラインの参照実装 — ocaml-webui上にアプリを
作るときの想定経路。

```
schema/hello.atd ──atdml/atdts──> OCaml + TypeScript codec
bin/commands.json ──command-gen──> commands_gen.ml + commands_gen.ts
                └──--emit-client──> client.ts（canonical protocol v1 client）
web/main.ts + 生成ファイル ──esbuild──> main.bundle.js ──embed──> main.exe
```

| Command        | 実演内容                                                        |
|----------------|------------------------------------------------------------------|
| `hello.ping`   | sync ATD Command。型付き validation error（`empty_message`/`too_long`） |
| `work.count`   | worker domain上のasync Command。`cancellation_token` checkpoint、JS cancel、30s watchdog |
| `trace.recent` | 統一trace ring bufferを読む `raw_json` Command                     |

人が書くのは `.atd` スキーマ・`commands.json`・handler本体・TSのUI —
残りは全て生成物。

## 実行

```bash
cd web && npm ci && cd ..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

headless検証には `OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS=<ms>` で指定ms後に
window closeできる。

## ファイル

- `schema/hello.atd` — payload型（codecのSSOT）。
- `bin/commands.json` — Command manifest（配線のSSOT）。
- `bin/main.ml` — window + 実装対象の `handlers` record。
- `bin/dune` — codegen + bundle + embed rule（アプリ側の雛形）。
- `web/main.ts` — emit client + 生成descriptorをimport。
- `web/esbuild-wrapper.mjs` — esbuild JS-API wrapper（cross-platform）。
