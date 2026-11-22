# examples/minimal

最小構成のocaml-webuiアプリ — npm不要・コード生成無し。

OCaml側は passthrough codec（入出力とも `Yojson.Safe.t`）の `"echo"`
Commandを1つ登録。JS側はHTML内のインラインscriptが protocol v1
envelopeを手で組み立て `__ocaml_webui_invoke` を直接呼ぶ。

protocolのwire形状を確認するための教材。実アプリでは生成client +
manifest経路（`../typed-hello`）を使うこと。

## 実行

```bash
opam exec -- dune exec examples/minimal/main.exe
```

ボタンで `{message, seq}` を `echo` へ送り、生のrequest/response
envelopeを表示する。

## ファイル

- `main.ml` — window・command・埋め込みHTMLの全て。
- `dune` — `ocaml-webui.raw` + `ocaml-webui.bridge-atd` のみ。
