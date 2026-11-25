# commands.ml のcompile可能化 — 検討中（ペンディング）

日付: 2026-11-23
状態: **ペンディング**（実装するかどうか未決定）

## 問題 — なぜ現状の`commands.ml`はcompileできないか

`commands.ml`はOCaml構文に見えるが、実際にはOCamlとしてcompileできない。
`command-gen`がparseする宣言言語が、たまたまOCamlそっくりの見た目を
しているだけである。

```ocaml
let ping = command "app.ping" ~mode:"sync"
  ~input:ping_request ~output:ping_response ~error:ping_error
```

OCaml compilerに通すと2箇所で壊れる:

1. **`command`は未定義** — どこにもそんな関数は存在しない。
   generatorがparse時に認識する「予約形」であり、OCamlの値ではない。
2. **`~input:ping_request`は値の位置に型名を書いている** —
   `~input:foo`は「値foo」を渡す構文だが、`ping_request`はtype宣言の
   **型名**であり同名の値は存在しない。OCamlには型を関数引数として
   渡す仕組みがないため、この形は原理的にcompile不可能。

## compileできないと何が困るか — 何が既にカバーされているか

| 困ること | 現状の代替 |
|---|---|
| editorで`ping_request`へjump-to-defできない | 目grep |
| 型名typo・未定義参照がeditorで赤くならない | **command-gen実行時に`file:line:col: error:`で検出**（build時、実装済み） |
| ファイルの構文エラー・型整合性がcompilerに検査されない | decl_parseが独自diagnosticsを出す（実装済み） |
| merlinが型情報を持てない | なし |

**正しさの検証自体は既にbuild時にできている。** compile可能化で
追加されるのは「editor内の即時フィードバックとmerlin連携」だけ —
つまり機能ではなく開発体験（DX）への投資である。

## compile可能にするには

`command`はstub関数を作れば解決するが、「型を値として渡す方法が
OCamlに存在しない」が本質的な壁。以下の案を比較検討した。

### 案A1: 型注釈で型を運ぶ（最有力）

```ocaml
let ping : (ping_request, ping_response, ping_error) Webui_decl.command =
  command "app.ping" ~mode:"sync"
```

- `Webui_decl` libが `type ('i,'o,'e) command` + stub `command`関数を提供
- 右辺は普通の関数呼び出し、型は左辺注釈`(A,B,C) command`の型パラメータ
  としてcompilerが本物の型として解決 → merlinでjump・未定義型が即error
- decl_parseは`~input:`等の代わりに型注釈のパラメータを読む形に変更
- raw_jsonは `(unit, Yojson.Safe.t, Yojson.Safe.t) command` 等で表現
- compileされた値はcodegen用metadataのみ保持しruntimeでは実質未使用
- `~schema_module`等のcodegen用メタデータはstub関数の引数として
  引き受ける必要あり（interface上のnoiseになる）

### 案A2: module wrapper `~input:(module Ping_request : T)`

型をfirst-class moduleとして渡す。compileは可能だが構文が重く、
型宣言とmodule宣言の二重定義になる — 脱落。

### 案A3: 現状維持（parse専用のまま）

compile不能であることをdocで明示するだけ。最軽量だがmerlin効果は
永遠に得られない。

## トレードオフの本質

- **得るもの**: editor/merlin体験（build待たずに型名typo検出、
  定義ジャンプ、hoverでの型確認）
- **払うもの**:
  - 宣言構文の変更（`~input:`等が消えて型注釈へ — decl_parseの変更も必要）
  - 「compileさせるためだけのstub lib」`Webui_decl`の保守
  - compileされた値はruntimeで使われない冗長性
  - codegen用メタデータがstub関数signatureに混入する

## 判断

**「build時検証で十分」として現状維持（案A3）も妥当な選択**であり、
現時点ではペンディング。再検討のトリガー:

- commands.mlが大きくなってeditor支援の欠如が実害になった場合
- merlin連携を求める外部利用者が現れた場合
- `Webui_decl`の値をruntime自己登録に使う等、compile結果に
  codegen以外の用途が生まれた場合（その時は冗長性の問題も解消される）
