# Phase 5/6 レビュースコープ — Worker + Resource レイヤー

レビュー対象日: 2026-11-17
対象コミット範囲: `61c0f3b` … `736c6e4`（main）

## レビュー対象

| コンポーネント | ファイル | 役割 |
|---|---|---|
| Worker supervisor | `lib/worker/webui_worker.{ml,mli}` | 外部プロセス管理。NDJSON JSON-RPC多重化、reader domain、timeout、crash/restart、kill、request-level cancel/detach |
| Resource registry | `lib/resource/webui_resource.{ml,mli}` | scope付きリソース登録・冪等release・逆順revoke |
| Window teardown hook | `lib/raw/webui_raw.{ml,mli}` の `Window.on_destroy` | Window scopeの自動release基盤。raw→resource非依存を保つためOCaml側side tableで実装 |
| Trace 連携 | `lib/trace`（`worker_*`/`resource_*` イベントのみ） | イベント発火点。本体は既レビュー領域 |
| 検証 | `test/worker/`（31 checks）, `test/resource/`（20 checks）, `spikes/async-command/`（実機window-scope検証） | headless + 実機WebView2 |
| dogfooding | `D:/work/ai-usage-monitor` `lib/providers/codex_provider.ml`, `bin/main.ml` | Window-scope worker の実アプリ適用 |

## 設計書・確定事項

- `docs/worker-layer-plan.ja.md` — Worker設計計画書
- `docs/resource-layer-plan.ja.md` — Resource設計計画書
- decisions（Context Mixer）: 「外部プロセスWorker supervisor設計（2026-11-16確定）」「Resourceスコープ設計（2026-11-16確定）」

### Worker確定事項（W1–W6）

- 外部プロセスのみ、1 handle = 1 OS process
- NDJSON framing、id多重化、notification callback
- cancel = `Unix.kill sigkill`（Windows = 疑似pid→TerminateProcess、POSIX = SIGKILL）。request-level cancelは待機解除のみ（workerは生存、late response破棄）
- restart = `Never | On_crash of int`（backoffなし）
- `~execution:Worker` Commandルーティングは v1 外
- pool は v1 外

### Resource確定事項（R1–R4）

- scope = `App | Named of string | Window of Window.t`
- `Webui_worker.spawn ~scope`（default App）で `kind:"worker"` 自動登録
- `shutdown_all` = 全worker kill + `revoke_scope App`（互換経路）
- JS opaque handle / payload内resource参照は v1 外（Capability/Scope認可とは別設計）

## 不変条件（レビューで確認すべき約束）

- release関数は最大1回（registryが冪等保証）
- `revoke_scope` は逆登録順・mutex外でrelease実行
- worker kill・自然死どちらでもresourceが自動releaseされ、`Dead`のstatusを`Killed`へ汚さない
- window-scope resourceはnative destroy**成功後**・owner thread上でrelease（拒否されたdestroyではcallbackを消費しない）
- `shutdown_all` はscope不問で全workerをkillする（後方互換）

## 既知の制限・open items（バグではなく記録済み仕様）

1. **Windows疑似pid**: `Unix.create_process` はプロセスHANDLEをpid風に返す。`Unix.kill`は疑似pidのまま動くが、OS PIDが必要な操作（taskkill・WMI照合）は不可
2. **二重bookkeeping**: worker生存管理のlegacy `Registry`（shutdown_all用）と `Webui_resource` registryが併存。dead workerはlegacy側に残り得る（snapshot時にalive filterする設計だが未実装のまま問題なし）
3. **revoke順序はscope内のみ**: scope横断の依存順序保証なし
4. **codex_providerのstale scope**: window destroy後に`get_worker`が呼ばれると、destroy済みwindowを指すscopeでrespawnされる（実害なし — destroy後はアプリ終了のみ。将来multi-windowでは要対処）
5. **Named scope未活用**: Usage MonitorではWindow scopeのみ使用。Named scopeはtest/resourceでのみ検証
6. **request-level cancelの応答は破棄されるがworker側処理は継続** — worker側で処理中断したい場合はprotocol cancel frameが必要（W3で明示的にv1外）

## 検証状況

- `test/resource/resource_test.exe`: 20 checks全pass
- `test/worker/worker_test.exe`: 31 checks全pass（Windows実機でTerminateProcess・restart確認）
- `spikes/async-command/main.exe`: 実機WebView2でwindow-scope resourceのdestroy時release確認
- `D:/work/ai-usage-monitor`: `AIM_AUTOCLOSE_MS=20000` で起動→auto-refresh→codex worker spawn（`app-server --stdio`）→auto-close→destroy経由でkill、孤児プロセスなし
- CI: Windows + Linux 両ジョブ green（最新 run `44079210059`）

## レビュー時の着眼点（想定問い合わせ）

- resource release中の再入（release fnがregister/releaseを呼ぶ）の安全性 — mutex外実行で設計済みだが実装確認値あり
- `Window.on_destroy`のcallbackがnative destroy前に走る順序が、resource cleanupがwindow APIを使うケース（今後のBinding resource化等）で正しいか
- reader domainのEOF検知から `Stop`/`Restart` 分岐でresource releaseのタイミングが正しいか（`Stop`時のみrelease、`Restart`ではresourceを保持）
- `shutdown_all`の「全worker kill → revoke_scope App」の順序で、App-scope以外のworkerがrevokeされないまま残るパスがないか
