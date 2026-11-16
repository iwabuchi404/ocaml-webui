# Resource レイヤー設計計画（Phase 6 前半）

日付: 2026-11-16
状態: 計画 — ユーザー確認待ち

## 背景

設計構想 v1 Phase 6: 「opaque handle、resource registry、lifecycle、
dynamic capability、Data Plane」。Worker supervisor v1 で「寿命を持つ
外部リソース」の最初の実例（常駐プロセス）ができ、global registry +
`shutdown_all` という最小の Resource 管理も動いている。

### dogfooding の実需要（現状）

- Usage Monitor: 常駐 codex worker が `shutdown_all` で app 終了時に
  kill される（app scope で動作中）
- 今後増えうるリソース: 短命子プロセス（claude/opencode one-shot）、
  file handle、temp file、subscription、watcher

### 設計構想 §15 の階層

```text
Application Scope
└── Window Scope
   └── Command Scope
   │   └── Stream Scope
       └── Resource Scope
```

Window 終了時に scope 内 Resource を自動 revoke するのが本来の姿。

## 目的とスコープ

**v1 = registry + scope + leak detection。JS 側に見せる opaque
handle は含まない**（Command payload で resource ref を受け渡す
需要がまだ存在しない）。

```ocaml
(* 検討中の API イメージ *)
type resource
type scope = App | Named of string

val register :
  kind:string -> name:string -> scope:scope ->
  release:(unit -> unit) -> resource

val release : resource -> unit          (* idempotent *)
val revoke_scope : scope -> int         (* released count *)
val snapshot : unit -> resource_info list
val leak_count : unit -> int            (* unreleased at call time *)
```

- `release` は冪等（二度呼んでも一度だけ実行）
- `revoke_scope` はその scope に属する全 resource を release 順
  （登録逆順 = 依存の自然な逆転）
- trace: `resource_registered` / `resource_released` /
  `resource_revoked`（scope 単位）/ `resource_leaked`（終了時残存）
- `Webui_worker.spawn` が `?scope` で自動登録（`release = kill`）。
  `shutdown_all` は `revoke_scope App` の薄い別名になる

### scope 設計の論点

raw `Window` は teardown hook を持たない（`run`/`destroy` 駆動型）。
Window scope の自動 revoke をやるには raw に `on_destroy` hook を
足すか、bridge install 時に teardown を知る経路が必要。

v1では **`App` + `Named of string`（アプリ定義の任意グループ）**に
留め、Window scope は「raw teardown hook が必要になった時点」に
送るのが自然。Usage Monitor は単一 window で app exit = window
close なので Window scope 不要が実証済み。

### one-shot プロセスとの関係

claude/opencode のような「起動→出力→終了」のバッチ実行は
`Webui_worker`（常駐NDJSON-RPC用）とは別の型。Resource v1 では
「短命 process を resource として登録し、scope revoke で kill
できる」という位置づけのみ（専用の spawn API は作らない）。

## 検討案と推奨

| # | 論点 | 推奨 |
|---|---|---|
| R1 | scope = `App \| Named of string`（Window scope は hook 追加まで凍結） | 推奨。raw 変更なしで始められる |
| R2 | `Webui_worker.spawn` が `?scope` で自動登録、`shutdown_all` = `revoke_scope App` | 推奨。二重管理を防ぐ |
| R3 | JS 側 opaque handle / Command payload resource ref は作らない | 推奨。需要が出てから |
| R4 | leak detection = `leak_count` + `resource_leaked` trace event | 推奨。CI/テストで leak を assert 可能に |
| R5 | one-shot process 専用 API は作らない | 推奨。Resource に登録すれば scope revoke できるだけで十分 |

## 実装タスク（承認後）

1. `lib/resource` — registry、release 冪等、revoke_scope、snapshot、
   leak_count、trace events
2. `Webui_worker.spawn ?scope` で auto-register、`shutdown_all` を
   `revoke_scope App` へ委譲
3. `test/resource` — register/release/revoke/順序/冪等/leak_count、
   worker 自動登録→scope revoke で kill されること
4. Usage Monitor: 何も変えなくても shutdown_all が Resource 経由に
   なる（worker が App scope に登録済みのため）

## スコープ外（v1）

- Window/Command scope（teardown hook 必要）
- JS 側 resource handle、Command payload での resource ref
- Data Plane（凍結中）、dynamic capability（凍結中）
- one-shot process 専用 spawn API、resource の型付き codec
