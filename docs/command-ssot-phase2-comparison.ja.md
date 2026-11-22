# Command SSOT Phase 2 — 入力形式3案比較（PoC前の設計検討）

関連: `decisions/OCaml型付きCommand定義を最終SSOTにする（2026-11-19確定）`,
Phase 0棚卸し `command-ssot-phase0-inventory.ja.md`,
Phase 1結果（manifest駆動 generator, `5684e30`）。

目的: `commands.json`（手書きJSON manifest）を廃止し、**OCaml宣言を
SSOT**にする入力形式を決める。生成される後段（.atd → atdml/atdts →
codec、manifest IR → commands_gen.ml/.ts、emit client）は現行を維持する。

## SSOTが表現すべきもの（不変条件）

1. payload型（request/result/error）— 現在 `.atd`
2. Command metadata — wire名、kind(atd/raw_json)、mode(sync/async)、
   timeoutMs、tsModule 相当
3. 1ファイル（または1宣言群）が唯一の正本 — 第2のmanifestを残さない
4. 生成物のwire表現は現行とbit互換（protocol v1 + ATD JSON表現）
5. handler欠落/pack忘れはビルドエラー（現行維持）
6. **任意OCaml型の汎用compilerは作らない** — 非対応型は生成diagnostics

## 候補α: 制限OCaml構文ファイルのparse（compiler-libs）

`commands.ml` を「parseするがcompileしない」宣言ファイルとして扱い、
command-genがParsetreeを歩く。

```ocaml
(* commands.ml — SSOT（parse専用、compile対象外） *)

type ping_request = { message : string }
type ping_response = { echoed : string; length : int }
type ping_error_code = Empty_message | Too_long
type ping_error = { code : ping_error_code; message : string
                  ; retryable : bool ; category : string }

let ping =
  command "app.ping" ~sync
    ~input:ping_request ~output:ping_response ~error:ping_error
```

- `command` はtoolが認識する予約関数名。`ping_request` 等の識別子は
  「型への参照」として構文的に読み取る（型名機械変換で対応付け）。
- 非対応構文（副作用式、module、fun等）はdiagnosticsでreject。
- type宣言 → `.atd` 生成、`command`適用 → manifest IR → 既存生成経路。
- **merlin/ocp-indentがそのまま効く**（valid OCaml構文のため）。
- 追加dep: `compiler-libs.common`（compiler同梱、version一致）。

## 候補β: PPX（deriver/attribute）

```ocaml
[@@@webui.command "app.ping" ~sync
  ~input:ping_request ~output:ping_response ~error:ping_error]

type ping_request = { message : string } (* 通常コード内に混在 *)
```

- **問題1**: PPXはin-memoryでコード生成する — `.atd`/`.ts`ファイルを
  出力する正規の仕組みがない（副作用file emitは非標準・dune追跡不可）。
- **問題2**: TS descriptor/client生成は結局別toolが要る → 情報源が
  PPX（OCaml compile時）とTS生成時で分断し、SSOTにならない。
- **問題3**: ppxlib依存、compile time増、derive対応型の制約管理。
- 型宣言をそのまま使えるのは美点だが、artifact生成の分断が致命的。

## 候補γ: DSL combinator（build時に実行してmanifest emit）

```ocaml
(* gen_commands.ml — build時にcompileして実行 *)
open Webui_decl
let () = emit [
  atd_command ~name:"app.ping" ~sync
    ~input:"ping_request" ~output:"ping_response" ~error:"ping_error";
]
```

- 型参照は文字列になる（first-class typeが無いため）— 型名typoは
  OCaml compileではなくgenerator段階でしか検出不能 → **型整合性の
  SSOTにならない**。
- OCaml完全な表現力（let、fun、条件分岐）をmanifest記述に使えるのは
  利点だが、prototypeには過剰。
- build段が増える（compile+実行 → JSON → 生成）。

## 比較表

| 評価軸 | α: 制限OCaml parse | β: PPX | γ: DSL combinator |
|---|---|---|---|
| SSOT単一性 | ◎ 1ファイル | △ TS側生成が分断 | ○ emitで統合可だが型参照は文字列 |
| wire互換 | ◎ 既存後段をそのまま使用 | △ artifact生成経路を新設する必要 | ◎ |
| 非対応型diagnostics | ◎ Parsetree位置情報で正確報告 | △ deriver errorは出せるがTS側は別 | ○ |
| 依存・build cost | ○ compiler-libsのみ | ✗ ppxlib + compile cost | ○ 追加実行段 |
| エディタ体験 | ◎ valid OCaml構文 | ◎ | ◎ compileされる |
| 実装規模 | 中（type→ATD変換が中核） | 大 | 小 |
| 「OCaml宣言」の体現度 | ◎ 型宣言もcommand宣言もOCaml構文 | ◎ | △ metadataはOCamlだが型は別 |

## 推奨: αをPoCする

理由:
- βは「TS側の生成経路をどうするか」が未解決のまま最大工数 — PoCとしても
  artifact emitの非標準性が本質的欠陥。
- γは型参照が文字列になり「型付きSSOT」の主旨を満たさない。metadata
  だけの移行なら現行JSONと大差ない。
- αは「型宣言→.atd」「command宣言→manifest IR」の2変換に分解でき、
  後者は現行生成器に直結。type→ATD変換も制限subsetなら bounded。
- compiler-libsはcompiler同梱でdep追加が実質ゼロ、位置情報も正確。

### α PoCの評価軸

1. typed-helloの3 Command（sync ATD / async+timeout / raw_json）を
   `commands.ml` で宣言→現行と同一の `commands_gen.ml` が生成されるか
2. 非対応型（fun型・GADT・object・polymorphic variant等）が
   「型名+位置+理由」付きdiagnosticsになるか
3. `.atd` 生成で `atdml/atdts` のwire互換（`<json name>`のsnake→camel
   機械変換規約をどうするか決定が必要）
4. handler record生成・pack網羅は現行通りか

## 未決定論点（PoC中に決める）

- `command` 宣言の引数形: `~input:ping_request`（識別子=型参照）vs
  `~input:"ping_request"`（文字列）。識別子形式は型参照として自然だが
  検証はgenerator側になる
- `<json name>` 相当のcamelCase変換規約: 自動（snake→camel）か
  注釈（`[@json "delayMs"]` attribute）か — **αなら attribute が使える**
- `commands.ml` をcompile対象にもするか（`Webui_decl` stubでcompile
  可能にするとmerlin型check効くが、型参照引数の表現が難しくなる）
- raw_json Commandの宣言形
- module分割（複数 .atd相当を1ファイルに書くか）

## PoC結果（2026-11-22、α実施済み）

`tool/command_gen/decl_parse.ml` + `--decl/--atd` フラグでαを実装。

### 評価軸の結果

| 軸 | 結果 |
|---|---|
| typed-hello 3 Commandの再現 | **達成** — `commands.ml`宣言からの `commands_gen.ml`/`commands_gen.ts` がmanifest経路と **byte-identical**（typed-hello実ファイルでdiff検証） |
| 非対応型diagnostics | **達成** — fun型・multi-arg ctor・inline record ctor・polyvariant・型parameter・GADT注釈・未宣言type参照・副作用式を `file:line:col: error: <理由>` で reject（fixture 4形態実測） |
| wire互換 | **達成** — 生成.atdが `atdml`/`atdts` 両方でcodec生成可能。`delay_ms`→`delayMs` 等の自動snake→camel変換が既存 `<json name>` と一致（variantは Camel→snake） |
| handler record生成・pack網羅 | **達成** — 後段がmanifest IRで共通のため現行と同一 |

### PoCで確定した設計点

- 型参照は **識別子形式** `~input:ping_request`（file はcompileされないため unbound問題なし、型参照として自然）
- wire名規約: **自動変換**（record field: snake→camel、constructor: Camel→snake）+ `[@json "..."]` override（両方実装済み）
- `~schema_module`/`~ts_module` はcommand毎override or file `[@@@...]` 既定
- raw_json: `~kind:"raw_json" ~ts_output_type:"T" ~ts_type_decls:"..."`（`{ts|...|ts}` quoted string可）
- `commands.ml` はcompile対象外のまま — これでPoC範囲は十分

### 残課題（Phase 2継続候補）

- `commands.ml` のcompile可能性（`Webui_decl` stub提供でmerlin型check効果）— 型参照引数表現の設計が必要
- module分割・複数ファイル
- `commands.json` manifest経路との併存期間（α is `--decl`, manifest is `--manifest`、両方維持）
- usage-monitor/typed-helloの実移行（評価済みなので次工程）
