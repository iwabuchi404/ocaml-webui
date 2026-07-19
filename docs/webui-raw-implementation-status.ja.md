# Webui_raw 実装状況

更新日: 2026-07-19

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

- native closeの再現はpublic HWNDを公開せず、`For_testing.Win32.post_wm_close`だけで行う。
- response APIはdelivery保証を名乗らず、`Queued`とresponse失敗diagnosticsを分ける。
- handler例外のfallback rejectは`{"code":"binding_callback_raised"}`に固定する。
- 明示destroyが基本契約で、`Window.with_window`を推奨経路とする。finalizerは検出だけで
  native destroyを行わない。
- Windows固有hookは`For_testing.Win32`に隔離し、cross-platform公開契約へ含めない。

### ストレステストの同期修正

Step 7回帰中、close側がproducer/dispatcherの開始より先に進むと、ライブラリの不変条件
ではなく「最低1件はclose前に処理する」というtest前提だけが破れる競合を確認した。
`window_close_stress`はdispatcherが`Running`を観測してからcloseを開始し、
`pending_call_stress`は初回completion後にcloseを競合させる。修正後は標準20 close反復、
multi-Window 10 cycle、pending Call 10 cycle/480 Callが完走した。100 close反復は約4分を
超えるため通常回帰から長時間soak枠へ移す。

## 次の実装

1. Linuxでcompile gateを作り、Window lifecycle、dispatch、binding/Callの意味論差を洗う。
2. Linux実機runtime probeをWindowsと同じ不変条件で通し、必要なplatform abstractionだけを
   `lib/raw`内部へ追加する。
3. Windows/Linuxで公開`.mli`が一致した時点でcross-platform raw APIをfreezeする。
4. その後にmacOS compile/runtime検証を加え、上位の手書きbridge baselineへ進む。
