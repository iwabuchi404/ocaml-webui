# Webui_raw 実装状況

更新日: 2026-07-19

## 現在地

7段階計画の Step 1〜6 を実装した。`Webui_raw` は `owebview` のOCaml
bindingを経由せず、固定した upstream `webview` を直接呼び出す。

| Step | 状況 | 主な成果 |
|---|---|---|
| 1. Repository/依存基盤 | 完了 | direct upstream pin、root build、opam metadata、依存出所 |
| 2. API/state machine | 完了 | typed error、Window/Call state、40 transition test |
| 3. Window lifecycle | 完了 | create/config/run/close/destroy、owner-thread検査 |
| 4. Dispatch queue | 完了 | Window単位queue、single wakeup、root/cancel/例外diagnostics |
| 5. Binding/Call token | 完了 | registry、request copy、one-shot response、close cancel |
| 6. Shutdown stress | 完了 | close、multi-Window/Domain/GC、pending Call、異常系cleanup |
| 7. Spike移行/API freeze | 未着手 | 最終gate |

## 実装済みAPI

- `Window.create`, `run`, `request_close`, `destroy`
- `set_title`, `set_size`, `navigate`, `set_html`, `init`, `eval`
- worker Domain/threadから利用できる `Window.dispatch`
- `Binding.create/remove` とcopy済みrequest JSONを持つ `Call.t`
- Domain-safeな `Call.resolve_json/reject_json/cancel`
- lifecycle、root、queue、enqueue/execute/cancel、callback例外を返す
  `Diagnostics.snapshot`
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
    `Running`へrollbackしてpending Callをcancel
  - close失敗後の再close、destroy、全root/queue 0を確認

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
- close scheduling失敗時はWindowを`Running`へ戻す。ただしclose開始時点で所有権を
  回収したpending Callとdispatchはcancel済みとし、late responseを許可しない。
- close scheduling faultはone-shotであり、その後の`request_close`で終了を再試行できる。

## 次の実装

Step 6の合格条件を満たしたため、Step 7「移行とraw契約のfreeze」へ進む。

1. 3つのPhase 1 spikeをpatch scriptなしで`Webui_raw`へ移行する。
2. `owebview`をbuild dependencyから削除する。
3. 公開`.mli`、lifecycle図、supported-thread表をreviewする。
4. clean root buildと全実機probe後にraw API契約をfreezeする。
