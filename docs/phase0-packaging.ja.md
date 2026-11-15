# Phase 0: パッケージング計画（opam Stage 1）

## 目的

他者が `git pin` でインストールできる状態（=opam Stage 1）を整える。
公式 opam-repository への登録はしない。

## ユーザー確認済みの決定事項（2026-11-14）

| 項目 | 決定 |
|---|---|
| LICENSE | MIT |
| 著作権者名 | `iwabuchi404` |
| maintainer メール | なし（`iwabuchi404` のみ） |
| `available` で OS 制限 | **しない**（macOS失敗はユーザー側の問題として扱う） |
| Linux GTK依存 | **直接depexts**（conf-gtk3-webkit は採用しない） |

## conf-gtk3-webkit 不採用の理由

`conf-gtk3-webkit` 系の外部 conf パッケージへの依存を検討したが、
ユーザー判断で直接depextsを採用。理由:

- distro 別パッケージ名を opam.template に明示する方が依存関係が自己完結する
- 外部 conf の保守状況に依存しない
- debian 系(`libgtk-3-dev` + `libwebkit2gtk-4.1-dev`)、
  fedora(`gtk3-devel` + `webkit2gtk4.1-devel`)、
  arch(`gtk3` + `webkit2gtk-4.1`) で名前が異なるため、明示列挙が正確

## タスクと実装方針

### 0.1 LICENSE

MIT、`Copyright (c) 2026 iwabuchi404`。

### 0.2 dune-project SSOT 化

`(generate_opam_files true)` + `(package ...)` stanzaへ移行。
`ocaml-webui.opam` は生成物になる（ソースツリーには残るが
「dune-projectを編集せよ」の生成コメント付き）。
`convention` の「生成物は_build内のみ」は、opamファイルが
pin/installで必須という性質上の例外として扱う。

metadata 充填:

- synopsis / description — 既存 opam の文言を踏襲
- license — MIT
- authors / maintainers — `iwabuchi404`（メールなし）
- `(source (github iwabuchi404/ocaml-webui))` → homepage / bug-reports / dev-repo を自動生成
- `(documentation ...)` → docs/ へのURL

depends:

- `ocaml` `>= 5.4 & < 5.5`
- `dune`（dune が自動で `>= <lang dune>` を付与するため裸の `dune` のみ）
- `yojson` `>= 3.0`
- `atd` / `atdml` / `atdts` `>= 4.2` に `:build` フィルタ — code generator であり
  生成コードは yojson のみに依存するため、consumer に不要
- `conf-c++`、`conf-mingw-w64-g++-x86_64` `{os = "win32" & arch = "x86_64"}`

### 0.3 depexts

dune-project の `(package)` stanza は `depexts` フィールドをサポートしない
（公式 docs 確認済み）。`ocaml-webui.opam.template` に opam 構文で記述し、
生成ファイルへ merge させる。

- debian/ubuntu 系 → `os-family = "debian"`（1行で ubuntu 派生もカバー）
- fedora → `os-distribution = "fedora"`（centos/rhel ではパッケージ名が
  異なるため family ではなく distribution で限定）
- arch → `os-family = "arch"`（manjaro 等の派生も同一パッケージ名）
- Windows → depexts なし（`conf-mingw-w64-g++-x86_64` が自前で解決）

### 0.4 headless test 分離

監査結果:

- `(test)` stanza 6件 — `state_machine_test`, `protocol_test` (baseline/atd),
  `wire_parity_test`, `ocaml_codec_test`, `echo_codec_test`
- `test/bridge_atd/protocol_test.ml` の `expect_duplicate_command` のみ
  `Window.create` を呼んでいた → `install_probe.ml` executable へ分離
- GUI probe 計10本は `(executable)` stanza（runtest 対象外）を確認
- TS aliases (`@phase3_ts_check`, `@phase3_ts_test`) は runtest alias ではないため
  runtest に含まれない。CI で明示実行

保証: `dune runtest` / `opam run-test` は Window 非依存のみ。

### 0.5 最小CI

- Windows job: checkout(submodules: recursive) → setup-ocaml 5.4.1 →
  `--deps-only --with-test` → setup-node → npm ci → `dune build @all` →
  `dune runtest` → TS aliases → generated-opam freshness(git diff) → opam lint
- Linux job (ubuntu-24.04): 同上（depext が apt で GTK/WebKitGTK を解決）
- node は `actions/setup-node@v4` (v22)
- GUI E2E は CI に入れない

`git diff --exit-code -- ocaml-webui.opam` は spec 外の追加だが、
SSOT→生成物の一貫性を直接検証するため採用。

### 0.6 README pin 手順

`opam pin add <pkg> git+https://...` は submodule を自動初期化しない。
`vendor/webview` が C++ stubs の必須ヘッダを持つため URL pin は失敗する。
`--recurse-submodules` clone + path pin を推奨手順として明記。

### 0.7 検証

`opam lint` clean を確認し、本ファイル（計画）と
`docs/phase0-results.ja.md`（ゲート証拠）を作成。

## 受け入れゲート

- G0.1 `opam lint` error 0
- G0.2 clean checkout で CI green（Windows headless 一式 / Linux build+headless）
- G0.3 pin ゲート再現（clone→switch→pin→install→runtest）
- G0.4 LICENSE / metadata / README pin 節 / headless 分離
