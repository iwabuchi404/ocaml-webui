# Phase 0: パッケージング結果（opam Stage 1）

実施日: 2026-11-14。計画は `docs/phase0-packaging.ja.md` 参照。

## ゲート表

| Gate | 判定 | コマンド | 証拠 |
|---|---|---|---|
| G0.1 opam lint error 0 | ✅ | `opam lint ocaml-webui.opam` | `D:\work\ocaml-webui\ocaml-webui.opam: Passed.`（error 0, warning 0） |
| G0.2 clean checkout CI green | ⏳ push 待ち | `.github/workflows/ci.yml`（windows + linux jobs） | ローカル同等コマンドは全 pass（下記）。初回 CI 実行は push 後 |
| G0.3 pin ゲート再現 | ⚠️ 部分 | `opam install . --dry-run` → `install ocaml-webui dev (pinned)` 成功。`dune build -p ocaml-webui` 成功（public lib のみ、node 不要） | 完全な fresh clone + 新規 switch 再現は CI/初回利用時ゲート |
| G0.4 LICENSE/metadata/README/headless | ✅ | 下記 | 全項目確認済み |

### ローカル検証コマンド出力（Windows 主ゲート）

```
$ opam exec -- dune build @all          # エラーなし
$ opam exec -- dune runtest --force
ocaml_codec_test: passed round-trip decode variant unknown-field
atd_protocol_test: passed request error response identity app-error
state_machine_test: passed (20 window + 20 call transitions)
echo_codec_test: passed round-trip decode variant unknown-field
wire_parity_test: passed baseline vs ATD error envelope
protocol_test: passed request error response contracts
$ opam exec -- dune build test/bridge_atd/install_probe.exe   # ビルド成功
$ opam exec -- dune build -p ocaml-webui                       # 成功（public のみ）
$ opam install . --dry-run
  - install ocaml-webui dev (pinned)     # 成功
$ opam lint ocaml-webui.opam
D:\work\ocaml-webui\ocaml-webui.opam: Passed.
```

## 変更ファイル一覧

| ファイル | 変更 |
|---|---|
| `LICENSE` | 著作権者を `iwabuchi404` に変更（既存 MIT 維持） |
| `dune-project` | `(generate_opam_files true)` + `(package ...)` stanza で SSOT 化。name を `ocaml-webui` に統一 |
| `ocaml-webui.opam` | 手書き → **生成物**（先頭に `edit dune-project instead` コメント） |
| `ocaml-webui.opam.template` | 新規。debian/fedora/arch の depexts |
| `test/bridge_atd/protocol_test.ml` | `expect_duplicate_command` を除去（Window.create を含むため） |
| `test/bridge_atd/install_probe.ml` | 新規。Window 必須の duplicate-command 検証を executable probe へ分離 |
| `test/bridge_atd/dune` | `install_probe` executable 追加 |
| `.github/workflows/ci.yml` | windows + ubuntu-24.04 2 job 構成へ刷新 |
| `README.md` | `Installing with opam (git pin)` 節追加 + `install_probe` を手動実行リストへ |
| `.gitignore` | discover.exe 生成物 + ツール設定を追加（先行コミット `e346ff3`） |

コミット: `9c68c7a Phase 0 packaging: opam Stage 1 (git-pin installable)`

## headless 分離の監査結果（G0.4 の根拠）

`(test)` stanza 6件、すべて Window 非依存:

- `test/raw/state_machine_test` — 状態遷移のみ
- `test/bridge_atd/protocol_test` — JSON encode/decode + envelope（分離後）
- `test/bridge_atd/wire_parity_test` — envelope 一致検証
- `test/bridge_baseline/protocol_test` — 同上（baseline）
- `test/command_schema/ocaml_codec_test`, `echo_codec_test` — codec round-trip

`(executable)` stanza（runtest 対象外、GUI 必須）11件:

- `test/raw/`: lifecycle_probe, dispatch_probe, binding_probe,
  window_close_stress, multi_window_stress, pending_call_stress,
  abnormal_cleanup_probe, native_close_probe, resource_safety_probe
- `test/bridge_atd/install_probe`（今回分離）
- spikes/* の各 main

TS aliases (`@phase3_ts_check`, `@phase3_ts_test`) は runtest alias 外のため
runtest に含まれない。CI で明示実行。

## 偏离と理由

| 偏离 | 理由 |
|---|---|
| debian/ubuntu を `os-family = "debian"` 1行で表現 | spec は distro 別列挙を示唆したが、family が debian+ubuntu+派生を正確にカバー。重複行を避ける |
| spec 外: CI に `git diff --exit-code -- ocaml-webui.opam` 追加 | SSOT→生成物の一貫性を直接検証。opam lint だけでは「生成が最新か」が保証できない |
| spec 外: `atd`/`atdml`/`atdts` に `:build` フィルタ | code generator であり生成コードは yojson のみ依存。consumer に不要 |
| maintainer メールなし | ユーザー選択。`maintainer: ["iwabuchi404"]` のみ |
| `available` OS 制限なし | ユーザー選択 |
| 生成 opam 内に `"odoc" {with-doc}` / `x-maintenance-intent` が自動付与 | dune 3.18 の標準生成物。有害ではないため残置 |

## 未決質問

- なし（4項目すべてユーザー確認済み）

## 残課題

- **G0.2/G0.3 の完全達成は push 後の初回 CI 実行が必要**
  - CI 未push コミット: `e3ec7d8`(LICENSE), `e346ff3`(gitignore), `2907a0b`(旧CI+opam), `9c68c7a`(Phase 0)
  - 初回実行リスク: `conf-mingw-w64-g++-x86_64` の runner での解決、Linux depext の apt 解決
- `install_probe.exe` はビルド確認済みだが、実 Window での実行検証は未実施（Windows 実機で `dune exec` して確認推奨）
