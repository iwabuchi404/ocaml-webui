# ocaml-webui

デスクトップWebView UIのためのOCamlアプリケーションランタイム — 型付き
Command、構造化エラー、協調キャンセル、そして JavaScript → OCaml →
Worker をまたぐ単一トレース。

> **現状: documented prototype (v0.1)** — APIは未凍結で、まだ汎用
> フレームワークではありません。下記の型付きCommand生成経路が想定する
> 使い方であり、それ以外は参考資料・内部実装です。

## これは何か

Commandを一度だけ定義します — 制限OCaml構文の宣言ファイル
（`commands.ml`。新規アプリはこれが推奨入力）— `ocaml-webui.command-gen`
がbridgeの両側を生成します：

- OCaml: `handlers` record（handler欠落は**コンパイルエラー**）、codec、
  登録リスト。
- TypeScript: 型付き `CommandDescriptor`。
- canonical JS client（`--emit-client`）— protocol v1 を実装する
  `invokeCommand` / `cancelCommand` / `ProtocolError` /
  `ApplicationError`。

`traceId` / `requestId` が1つ、JSのinvokeからOCaml handler、worker
domain、外部プロセスまで追従します — 層ごとのログではなく、一本の
統一トレースです。

## クイックスタート

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam install . --deps-only   # または下記のpin手順
cd examples/typed-hello/web && npm ci && cd ../..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

`--recurse-submodules` は必須 — `vendor/webview` はsubmoduleであり、
無しではビルドに失敗します。Windowsでは先に
[プラットフォーム](#プラットフォーム) の前提環境を確認してください
（WebView2 runtime、MinGW-w64 C++ toolchain）。

`examples/typed-hello` は想定する経路全体を実演します：

| Command        | 実演内容                                               |
|----------------|--------------------------------------------------------|
| `hello.ping`   | sync ATD Command、型付き validation error              |
| `work.count`   | worker domain上のasync Command、JS cancel、timeout watchdog |
| `trace.recent` | 統一trace ring bufferを読む raw_json Command            |

`examples/minimal` は同じ境界をnpm・コード生成無しで示すサンプル —
手組みの protocol v1 envelope が passthrough codec を呼びます。wireの
素形を見るためのもので、実アプリのコピー元にはしません。

ライブラリとして使う手順: [docs/getting-started.ja.md](docs/getting-started.ja.md)
新規アプリは `commands.ml` 宣言を使ってください —
[docs/getting-started.ja.md](docs/getting-started.ja.md)。JSON
manifestは中間表現として残っています
（[docs/commands-manifest.ja.md](docs/commands-manifest.ja.md)）。
English docs: [README.md](README.md) /
[docs/getting-started.md](docs/getting-started.md) /
[docs/commands-manifest.md](docs/commands-manifest.md)

## プラットフォーム

| プラットフォーム | バックエンド | 状態 |
|---|---|---|
| Windows 10/11 | WebView2 | 検証済み。複数Window同時実行可 |
| Linux (Ubuntu 24.04 / WSL2) | WebKitGTK 4.1 | 検証済み。**同時Windowは1つ**、`Window.create`はプロセス初期スレッド上必須 |
| Linux (非WSL) | WebKitGTK 4.1 | 動作見込み。未ゲート |
| macOS | — | 未実装 |

## 公開ライブラリ

| ライブラリ | 用途 |
|---|---|
| `ocaml-webui.raw` | 自前のネイティブWebViewバインディング: Windowライフサイクル、binding、Call |
| `ocaml-webui.bridge-atd` | 型付きCommand bridge — 主経路 |
| `ocaml-webui.async` | Domainベースの非同期処理、cancel token、並列結果収集 |
| `ocaml-webui.trace` | 統一トレースイベント + ring buffer |
| `ocaml-webui.exec` | one-shot外部プロセス実行（timeout/cancel/上限） |
| `ocaml-webui.worker` | 永続NDJSON supervised worker |
| `ocaml-webui.resource` | ライフサイクル連動のリソース管理 |
| `ocaml-webui.command-schema` | spike共用のATDスキーマ。参考用 |
| `ocaml-webui.bridge-baseline` | 手書きbridge — **参考・比較用のみ**。推奨経路ではない |
| `ocaml-webui.command-gen` | 実行ファイル: manifest → OCaml + TS コード生成 |

## リポジトリ構成

```
lib/            公開ライブラリ
js/webui_client.ts   canonical TS client（--emit-client の出力元）
tool/command_gen/    manifestコード生成器
test/         headless単体・結合テスト（dune runtest）
spikes/       対話型WebView probe（dune exec）
examples/     利用者向けサンプル（minimal, typed-hello）
docs/         設計資料・リファレンス
```

## opamでのインストール（git pin）

> **重要:** `opam pin add <pkg> git+https://...` は git submodule を初期化
> しません。`vendor/webview`（C++ stubsが必要とする上流ヘッダ）は
> submoduleなので、素のURL pinはビルドに失敗します。下記の通り
> `--recurse-submodules` でcloneしてローカルパスをpinしてください —
> early adopter向けの推奨手順です。

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam pin add ocaml-webui .
opam install ocaml-webui
```

OCamlライブラリのみ使う場合はnode不要。esbuild経路が必要なのは
`examples/typed-hello` と TS probe のビルド時だけです。

## 前提環境

### Windows

- WebView2 runtime 入りの Windows 10 / 11
- opam 2.5以降、プロジェクトローカル OCaml 5.4.1 switch
- dune と対応する MinGW-w64 C++ toolchain
  （`opam install dune yojson conf-c++ conf-mingw-w64-g++-x86_64`）

### Linux 移植性検証

- OCaml 5.4.x、Dune 3.18以降
- Yojson 3.0以降
- C++14コンパイラと `pkg-config`
- GTK 3 / WebKitGTK 4.1 開発パッケージ

Ubuntu 24.04 / WSL2:

```bash
sudo apt update
sudo apt install -y build-essential pkg-config opam \
  libgtk-3-dev libwebkit2gtk-4.1-dev
```

## 開発・probe

`dune runtest` の headlessテストはディスプレイ不要。実WebViewを開く
probeは手動実行:

```powershell
opam exec -- dune build @all
opam exec -- dune exec test/raw/lifecycle_probe.exe
opam exec -- dune exec test/raw/dispatch_probe.exe
opam exec -- dune exec test/raw/binding_probe.exe
opam exec -- dune exec test/raw/window_close_stress.exe -- --iterations 20
opam exec -- dune exec test/raw/multi_window_stress.exe -- --cycles 10 --dispatches 40
opam exec -- dune exec test/raw/pending_call_stress.exe -- --cycles 10 --calls 48
opam exec -- dune exec test/raw/abnormal_cleanup_probe.exe
opam exec -- dune exec test/raw/native_close_probe.exe
opam exec -- dune exec test/raw/resource_safety_probe.exe
opam exec -- dune exec test/bridge_atd/install_probe.exe
opam exec -- dune runtest test/bridge_baseline
```

async Command probeは `define_async` をend-to-endで検証 — worker
domain実行、JS cancel、OCaml/JS timeout、close-while-pending:

```powershell
opam exec -- dune exec spikes/async-command/main.exe
```

Phase spike（証拠として保持）:

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
opam exec -- dune exec spikes/phase1-window-close/main.exe
opam exec -- dune exec spikes/phase2-handwritten-bridge/main.exe
opam exec -- dune exec spikes/phase3-atd-command/main.exe   # web/phase3-atd-command/ で npm ci が必要
```

resource-safety probeは意図的に生きたWindowをfinalizeしてleak検出を
確認するため、成功終了でもbackend cleanup warningが出る場合があります。
WSLgではEGL/Zink fallback warningも出ますが結果には影響しません。

## 設計資料

- [`Webui_raw`: OCaml WebView raw binding design](docs/webui-raw-binding-design.md)
- [`Webui_raw`: OCaml WebView raw binding設計（日本語）](docs/webui-raw-binding-design.ja.md)
- [`Webui_raw` implementation status（日本語）](docs/webui-raw-implementation-status.ja.md)
- [Handwritten bridge baseline design（日本語）](docs/handwritten-bridge-baseline.ja.md)
- [Command SSOT Phase 0 inventory（日本語）](docs/command-ssot-phase0-inventory.ja.md)
- [Dependency provenance](docs/dependencies.md)
