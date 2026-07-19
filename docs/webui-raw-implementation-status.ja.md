# Webui_raw 実装状況

更新日: 2026-07-20

## 現在地

7段階計画の Step 1〜7 をWindowsで実装した。`Webui_raw` は `owebview` のOCaml
bindingを経由せず、固定した upstream `webview` を直接呼び出す。公開APIはWindows版の
freeze候補であり、cross-platform契約のfreezeはLinux検証後に行う。

| Step | 状況 | 主な成果 |
|---|---|---|
| 1. Repository/依存基盤 | 完了 | direct upstream pin、root build、opam metadata、依存出所 |
| 2. API/state machine | 完了 | typed error、Window/Call state、40 transition test |
| 3. Window lifecycle | 完了 | create/config/run/close/destroy、owner-thread検査 |
| 4. Dispatch queue | 完了 | Window単位queue、single wakeup、root/cancel/例外diagnostics |
| 5. Binding/Call token | 完了 | registry、request copy、one-shot response、close cancel |
| 6. Shutdown stress | 完了 | close、multi-Window/Domain/GC、pending Call、異常系cleanup |
| 7. Spike移行/API freeze | Windows完了 | 3 spike移行、意味論確定、WM_CLOSE/資源安全性gate |

## 実装済みAPI

- `Window.create`, `run`, `request_close`, `destroy`, `with_window`
- `set_title`, `set_size`, `navigate`, `set_html`, `init`, `eval`
- worker Domain/threadから利用できる `Window.dispatch`
- `Binding.create/remove` とcopy済みrequest JSONを持つ `Call.t`
- Domain-safeな `Call.resolve_json/reject_json/cancel`
  - responseの`Queued`はowner-thread queueへの受理でありJS到達保証ではない
  - enqueue失敗は`Enqueue_failed Error.t`、close競合は`Window_closing`
  - cancel成功はresponse送信と区別した`Cancelled`
- lifecycle、root、queue、enqueue/execute/cancel、callback例外、native response失敗を返す
  `Diagnostics.snapshot`
- 明示destroyなしでfinalizeされたWindowの累積値を返す
  `Diagnostics.leaked_windows`
- upstream native errorを例外ではなく `Error.t result` へ変換

native contextはowner thread、lifecycle state、WebView handle、mutex、dispatch
queue、root数とdiagnosticsを所有する。WebViewのdestroyはowner thread上の明示操作だけで
実行し、GC finalizerからnative APIは呼ばない。

## 実ランタイム検証

Windows + OCaml 5.4.1 + MinGW-w64 + WebView2で次を確認した。

- lifecycle probeを5回連続実行: 全回成功
- dispatch probeを10回連続実行: 全回成功
- binding probeを修正後30回連続実行: 全回成功
- 1回のdispatch probeで126件enqueue、101件execute、25件close時cancel
- callback内の意図的な例外を1件捕捉し、C境界を越えないことを確認
- close開始後の新規dispatchを `Invalid_state` で拒否
- run終了後とdestroy後のdispatch root/queueが0
- double destroyとdestroy後の設定操作を検証
- Domainからのresponse、duplicate response、handler例外rejectを検証
- close時に未完了Callをcancelし、binding/pending/dispatch rootが0になることを確認
- fault injectionでnative dispatch enqueue失敗時のCall/root rollbackを確認
- randomized closeを同一process内で100回実行: 全回成功
  - enqueue 344件 = execute 45件 + cancel 299件
  - close後のdispatch 3656件を拒否
- 2つのWindowを別々のUI Domainで同時実行するstressを10サイクル実行: 全回成功
  - 同じ名前のbindingがWindowごとに分離されることを確認
  - 2つのCPU-bound producer Domainから合計800件をdispatchし、全件実行
  - 16〜23 KiBのデータを各closureに保持した状態でallocationとmajor GCを反復
  - run終了時のdispatch queue/pending Callが0、destroy後の全rootが0
- 48件のpending Callをshuffle順でresolve/reject/cancelし、closeと競合させるstressを
  10サイクル実行: 全回成功
  - 合計480 Callのうち30件がclose前にresponse/cancelを受理
  - close側のcancelが先行した447件は `Already_completed`、競合中3件は
    `Window_closing`
  - 全480件の二重完了を `Already_completed` で拒否
  - run終了時・destroy後ともpending Call/dispatch root/queueは0
- abnormal cleanup probeを10 process連続実行: 全30異常ケース成功
  - injected run failureはtyped `Run/Unspecified`を返して`Stopped`へ遷移
  - injected native response failureはCallを`Failed`にし、pending rootを解放
  - injected close dispatch failureはtyped `Request_close/Unspecified`を返し、
    `Running`へ完全rollbackしてpending Callとqueued dispatchを維持
  - close失敗後の再close、destroy、全root/queue 0を確認
- 実native HWNDへ`WM_CLOSE`をpostするprobeで、run return、pending Call cancel、
  destroy後root 0を確認
- `Window.with_window`の正常・例外経路でdestroyを確認
- 意図的なdestroy忘れを別processでfinalizeし、native APIをfinalizerから呼ばず
  `leaked_windows=1`として検出
- Step 7移行後の3スパイクをWebView2実機で再実行し、全て成功
  - threading: callback約3011 ms、Promise約3039 ms、最大frame gap 33.4 ms
  - Domain success: callback 14.6 ms、Promise約3061 ms、最大frame gap 21.8 ms
  - WM_CLOSE: close postからrun returnまで55.7 ms、pending response cancel、root 0

## 実装中に判明した点

### upstream 0.12.0 releaseの初期化停止

公式tag `0.12.0` のWindows実装ではWebView2 environment作成のretryが短く、ローカル
環境で `webview_create` が戻らなかった。upstreamの後続修正 `922a796` はretryを
60回、200 ms間隔へ変更している。現在はその修正を含むcommit
`cbbdee44afff22867de9fd88a9fc8350d9bdd399`を直接pinした。

APIが返すversion文字列は引き続き `0.12.0` であるため、再現性はversion文字列ではなく
commit hashで管理する。

### Windowsのbackground close

upstream API commentは `webview_terminate` をbackground threadから安全としているが、
Win32 backendは呼出threadに作用する `PostQuitMessage(0)` を使う。そのため
`Webui_raw.request_close` はworkerから直接terminateせず、`webview_dispatch`でUI
threadへ移してからterminateする。

### dispatchのaccept/schedule/destroy競合

queueへのaccept後、native wakeupをscheduleする前にclose/destroyが進むとstale handleを
使う余地がある。Windowsの `webview_dispatch` は短い非同期scheduleなので、queue mutex
内でacceptとscheduleを直列化し、OCaml callback実行時にはmutexを保持しない構成にした。

### binding変更時のnested event loop

binding handlerの実行中に同じbindingを直接removeすると、upstreamのcallback処理内で
停止した。さらにhandler return後へremoveをdispatchしただけでも、upstreamの
`webview_unbind`がWebView2 startup scriptを置換するためにnested Windows event loopを
pumpし、その間に別binding callbackが入るとdeadlockした。

`Webui_raw` はbind/unbindのupstream call中だけcontext mutexとOCaml runtimeを解放し、
nested callbackが両方を取得できるようにした。同時binding mutationは拒否する。また
active callback中、およびそのbindingにpending Callがある間のremoveを `Invalid_state`
で拒否する。Callをresponse/cancelした後に `Window.dispatch` したremoveは成功する。この
順序と、誤った順序の拒否をbinding probeで検証した。

### 異常終了の収束規則

Step 6ではnative異常を決定的に再現するone-shot fault injectionを`For_testing`へ追加した。

- `webview_run`がエラーを返しても、queueとpending Callをcancelして`Stopped`へ収束する。
- `webview_return`失敗時はCallを`Failed`へ移し、native pending registryから除去する。
- close scheduling失敗時はWindowを`Running`へ戻し、pending Callとqueued dispatchの
  所有権・diagnosticsもclose開始前へ完全rollbackする。成功時だけcancelする。
- close scheduling faultはone-shotであり、その後の`request_close`で終了を再試行できる。

### Step 7のfreeze候補で確定した意味論

- native closeの再現はnative handleを公開せず、
  `For_testing.Native_window.request_close`だけで行う。Windowsでは実際の`WM_CLOSE`を
  postし、LinuxではUI thread上の`gtk_window_close`へ対応させる。
- response APIはdelivery保証を名乗らず、`Queued`とresponse失敗diagnosticsを分ける。
- handler例外のfallback rejectは`{"code":"binding_callback_raised"}`に固定する。
- 明示destroyが基本契約で、`Window.with_window`を推奨経路とする。finalizerは検出だけで
  native destroyを行わない。
- native close hookとthread identityは不安定な`For_testing`に隔離し、application向け
  cross-platform公開契約へ含めない。

### ストレステストの同期修正

Step 7回帰中、close側がproducer/dispatcherの開始より先に進むと、ライブラリの不変条件
ではなく「最低1件はclose前に処理する」というtest前提だけが破れる競合を確認した。
`window_close_stress`はdispatcherが`Running`を観測してからcloseを開始し、
`pending_call_stress`は初回completion後にcloseを競合させる。修正後は標準20 close反復、
multi-Window 10 cycle、pending Call 10 cycle/480 Callが完走した。100 close反復は約4分を
超えるため通常回帰から長時間soak枠へ移す。

## 次の実装

1. 非WSL UbuntuのGUI環境で同じcompile/runtime gateを通す。
2. Linuxのsingle-live-Window制約を初期サポート契約として受け入れるか確認し、
   Windows/Linux共通の公開`.mli`をfreezeする。
3. CIにWindows compile/testとLinux compile/state-machine gateを追加する。
4. その後にmacOS compile/runtime検証を加え、上位の手書きbridge baselineへ進む。

## 追記: Linux portability着手（2026-07-19）

WSL2 Ubuntu 24.04.2 LTSとWSLg（X11/Wayland）の存在、repositoryを`/mnt/d`から参照
できること、GTK 3 / WebKitGTK 4.1 development packageがaptで提供されることを確認した。

### Windows上で実装・検証済み

- DuneのC++/link flagを`lib/raw/discover.ml`でhost別に生成
- Windowsは従来のWebView2/Win32 flags、Linuxは`pkg-config`の
  `gtk+-3.0 webkit2gtk-4.1`と`dl`を選択
- owner thread identityを`DWORD`から`std::thread::id`へ変更
- test-only native closeを`For_testing.Native_window.request_close`へ一般化
  - Windows: 実`PostMessageW(WM_CLOSE)`
  - Linux: UI threadへdispatchした`gtk_window_close`
- thread identityをplatform-neutralな`For_testing.current_thread_id`へ移動
- 変更後のWindows `dune build @all`、state machine、lifecycle、dispatch、binding、
  native close、abnormal cleanup probeは成功

### 現在のブロッカー

Ubuntuにはまだopam/C++/GTK/WebKitGTKを導入していない。導入前の確認中にWSL VMが
単純な`id`にも応答しない状態となり、通常の`wsl --shutdown` / `--terminate Ubuntu`も
timeoutした。管理者権限なしでは`WslService`を再起動できないため、Linux compile/runtime
gateはWSLサービス再起動後に再開する。source変更は未コミットのまま保持する。

## 追記: WSL2/WSLg Linux gate完了（2026-07-20）

PC再起動後にWSL2が復旧した。Ubuntu 24.04、OCaml 5.4.1、Dune 3.24.0、
GTK 3.24.41、WebKitGTK 2.52.3を用い、repositoryをWSL ext4上へ同期して検証した。
直前の「WSL復旧待ち」ブロッカーは解消済みである。

### 検証結果

- `dune build @all` 成功
- state machine: Window 20 + Call 20 transition成功
- lifecycle、dispatch、binding、native close、abnormal cleanup、resource safety成功
- pending Call stress: 10 cycle / 480 Call成功
  - `sent=95`, `already=385`, duplicate完了480件をすべて拒否
- window close stress: 20 iteration成功
  - `enqueued=240`, `executed=163`, `cancelled=77`, close後reject 560
- Linux guard: 同時2つ目のWindowとworker Domainからのcreateを
  `Create/Invalid_state`で拒否し、destroy後の順次再createに成功
- 3つのPhase 1 spike成功
  - threading: 約3秒のblocking callbackとUI dispatch遅延を観測
  - Domain dispatch: success/failureの両responseをUI threadへ戻し、重複完了を抑止
  - native close: 実`gtk_window_close`後にrun return、pending response cancel、
    Domain join、destroy後root 0を確認

WSLgは各GUI processでEGL/Zinkのdriver fallback warningを出すが、exit statusと
検証不変条件には影響しなかった。GTK critical warningとは分けて扱う。

### Linuxで判明した制約と修正

GTK/WebKitGTKをWindowsと同じ「Windowごとに別UI Domain」で同時初期化すると、
`webview_create`中のWebKitGTK `g_object_new`からabort/segmentation faultとなった。
このため現段階のLinux契約を次に限定した。

- `Window.create`はprocess initial threadだけで許可する
- 同時にliveなWindowは1つだけ許可する
- 違反はnative toolkitへ入る前にtyped `Create/Invalid_state`として返す
- 明示destroy成功後は次のWindowを順次createできる
- destroy忘れは従来どおりnative APIをfinalizerから呼ばず、leakとして検出するため、
  そのprocessでは新しいLinux Windowも作らせない

またupstream GTK backendはconstructorでdefault-size処理をidle callbackへ積む。
`run`前のCreated状態でdestroyすると、WebKit widget解放後にcallbackが動いてGTK critical
warningになっていた。create直後、bindingを登録する前にpending GLib main-context eventを
消化することで、callbackを有効なWindow上で完了させた。resource safetyと順次Window
guardの再実行でGTK critical warningが消えたことを確認した。

### Windows再回帰

Linux制約とtest capability追加後、Windowsで`dune build @all`、state machine、
lifecycle、dispatch、binding、native close、abnormal cleanup、resource safety、
multi-Window 3 cycle / 6 Window / 240 dispatchを再実行し、すべて成功した。

### 残課題

- WSLgではないUbuntu実機またはVMで、同一gateとGUI native closeを再検証する
- Linux single-live-Windowを初期公開制約としてfreezeするか判断する
- WSLgのEGL warningをCI失敗条件に含めず、GTK criticalを失敗条件にするログ基準を整備する
