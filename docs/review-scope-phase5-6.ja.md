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
- `test/worker/worker_test.exe`: 41 checks全pass（Windows実機でTerminateProcess・restart確認）
- `spikes/async-command/main.exe`: 実機WebView2でwindow-scope resourceのdestroy時release確認
- `D:/work/ai-usage-monitor`: `AIM_AUTOCLOSE_MS=20000` で起動→auto-refresh→codex worker spawn（`app-server --stdio`）→auto-close→destroy経由でkill、孤児プロセスなし
- CI: Windows + Linux 両ジョブ green（最新 run `44126918304` / `108498a`）

## レビュー時の着眼点（想定問い合わせ）

- resource release中の再入（release fnがregister/releaseを呼ぶ）の安全性 — mutex外実行で設計済みだが実装確認値あり
- `Window.on_destroy`のcallbackがnative destroy成功後に走る順序で、resource cleanupがwindow APIを使うケース（今後のBinding resource化等）に問題がないか
- reader domainのEOF検知から `Stop`/`Restart` 分岐でresource releaseのタイミングが正しいか（`Stop`時のみrelease、`Restart`ではresourceを保持）
- `shutdown_all`の「全worker kill → revoke_scope App」の順序で、App-scope以外のworkerがrevokeされないまま残るパスがないか

## レビュー指摘と対応（`6f18ee5` / `108498a` で対応済み）

外部レビューで4件指摘され、すべて修正済み:

1. **[P1] 同時リクエストでNDJSON破損** — requester各々が`p.oc`へ直接書いていた。requesterはframeをキューへenqueueするだけにし、専用writer Domainを唯一のstdin writerとした（`send_mutex`/`send_cond`/`send_queue`）。回帰テスト: 8 Domain×20件×4096B padding。
2. **[P1] 送信ブロック中にtimeout/cancelが効かない** — 同期書込みがdeadline設定より前だった。enqueue後にdeadlineを立てrequesterは`pending.result`をpollするだけなので、writerがブロックしていてもtimeout/cancelで待機解除される。dequeue後・書込み前にpending在籍を確認し、除去済みなら送信をスキップ。回帰テスト: 1MiB要求がtimeout_ms:100で1秒以内に`Timeout`返却。
3. **[P2] 自然終了後のプロセス参照残留と Dead→Killed 遷移** — `w.proc == Some p`はoptionブロックの物理比較で常にfalseだった。`Some cur when cur == p`で含まれるrecord同士を比較し、自然終了時に`w.proc <- None`。`kill`は`Alive`のみ`Killed`へ遷移し、`Dead`/`Killed`はno-op（terminateも呼ばない）。terminate前に`waitpid [WNOHANG]`でreap済み確認をベストエフォート実行。回帰テスト: `die`後に`pid=None`・`is_alive=false`・`kill`後も`Dead`維持。
4. **[P2] 拒否されたdestroyでresource解放** — `Window.destroy`がnative検証前にcallbackを取り出して実行していた。native destroyを先に呼び、`Ok ()`のときだけcallbackを取り出して実行（owner thread上・成功後）。失敗時はcallback登録のまま残る。

5. **発生したCI障害と再修正** — writer Domainは「requesterのDomainでない場所」でstdinへ書くため、worker死亡後のwriteでPOSIX `EPIPE`+`SIGPIPE`が発生しプロセス全体が死んだ（Linux CIで`worker_test`がsignal PIPE終了。WindowsはEPIPE例外のみで検出されず）。`spawn`時に`Sys.set_signal Sys.sigpipe Sys.Signal_ignore`を1回設定し、writer側では`Sys_error`として`Worker_exited`に変換されるようにした（`108498a`）。
6. **[P2] タイムアウト済み要求が送信キューに残りメモリ増大** — timeout/cancelがpendingのみ削除していたため、writerブロック中にキュー内JSON文字列が滞留した（1MiB×60件で約60MB残留を再現）。`pending.frame : string option ref`をキュー項目と共有し、pending削除の全経路（timeout/cancel/deliver/fail_all_pending/書込後）で`frame := None`にしてペイロードを解放。`stop_writer`もキューをドレインして各frameを解放。回帰テスト: stdin非読みworkerへ60×1MiB要求を全件タイムアウトさせ、GC.compact後のlive_words増分が1M語未満であることを確認（`worker_test` 41 checks）。

修正後の検証: `worker_test` 41 checks / `resource_test` 20 checks 全pass、`dune runtest`全green、async bridge実機probe全pass、Usage Monitor codex probe正常終了。CI run `44126918304`（`108498a`）でWindows+Linux両green。
