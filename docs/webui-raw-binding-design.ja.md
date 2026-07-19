# Webui_raw: OCaml WebView raw binding 設計

状態: 実装前ドラフト

日付: 2026-07-19

対象: Windows / OCaml 5.4 / WebView2を優先

[English version](webui-raw-binding-design.md)

## 1. 名前と位置付け

このコンポーネントの名前を **Webui_raw** とする。

- OCamlモジュール名: `Webui_raw`
- Dune公開ライブラリ名: `ocaml-webui.raw`
- ソースディレクトリ: `lib/raw/`
- native stubの接頭辞: `ocaml_webui_raw_*`

名前に`raw`を含めるのは意図的である。将来のアプリケーションコードは
このライブラリへ直接依存せず、上位の`Webui` runtimeとTyped Command APIを使う。

`Webui_raw`が置き換えるのはowebviewのOCaml bindingである。ブラウザエンジンや
WebView2そのものは再実装しない。

```text
Application / Typed Command runtime
                |
                v
            Webui_raw       <- このプロジェクトが所有
                |
                v
  upstream webview C/C++ API <- バージョン固定した依存
                |
                v
       Windows WebView2 Runtime
```

## 2. 今raw bindingを所有する理由

Phase 1のWindows/WebView2実機検証で、次が判明した。

1. binding callbackはnative UI threadを共有し、native UI処理を停止させる。
2. 別OCaml Domainから短いUI dispatch closureを通して結果を返せる。
3. 二重完了を防ぐにはresponseのone-shot所有権が必要である。
4. Window close時は新規responseを止め、workerをjoinしてからdestroyする必要がある。
5. binding/dispatch closureには明示的なGC root所有権が必要である。
6. owebviewは`CAMLdrop`より先にruntime lockを解放しており、Domain dispatch中に
   Windows access violation `0xC0000005`を再現した。
7. owebviewのbuild skeletonは今回のWindows toolchainをサポートしていない。

初期スパイクはowebviewのC++ stubをbuild時にコピーしてパッチしていた。
仮説検証には有効だったがproductionの依存境界にはできないため、現在は3スパイク
すべてを`Webui_raw`へ移行した。今後のbridge、cancellation、traceはこの所有bindingを
基盤にする。

## 3. 参照元

以下からAPI形状と実装上の知識を参照する。ただし、未検証のlifecycle前提は
そのまま引き継がない。

- `vendor/owebview/lib/webview.mli`
- `vendor/owebview/lib/webview.ml`
- `vendor/owebview/lib/webview_stubs.cpp`
- `vendor/owebview/lib/dune`
- `vendor/owebview/vendor/webview.h`（webview 0.12）
- `spikes/phase1-threading/`
- `spikes/phase1-domain-dispatch/`
- `spikes/phase1-window-close/`

owebviewは参照専用submoduleとして残すがbuild依存にはしない。上流`webview`を直接
固定し、licenseと正確なrevisionを記録する。

## 4. 目標

`Webui_raw`は、小さくレビュー可能なWindows優先bindingとして次を保証する。

- UI thread所有権を明示する。
- Window lifecycleを明示し、観測可能にする。
- Closing/Destroyed後にWebViewへアクセスしない。
- workerからUIへのthread-safeなdispatchを提供する。
- JavaScript callをone-shotで完了する。
- binding、dispatch、pending callのGC rootを決定的に解放する。
- OCaml例外をC callback境界の外へ出さない。
- 汎用`Failure`文字列ではなく型付きnative errorを返す。
- shutdownを明示し、GC finalizerからnative Windowをdestroyしない。
- rootとqueueの不変条件をテストで証明できるdiagnosticsを提供する。
- 対応toolchainでrepository rootからbuildできる。

## 5. 対象外

raw bindingでは次を実装しない。

- Typed Command schemaやATD生成
- JSON parse、validation、application error codec
- native JavaScript call IDより上位のCall ID / Trace ID方針
- Eio、Lwt、その他async runtimeとの統合
- worker process supervision
- capabilityやpermission check
- resource URLやcustom WebView2 scheme
- 汎用WebView2 COM wrapper
- 初期実装でのmacOS/Linux対応
- GC finalizerからの自動native destroy

これらはraw bindingより上位、または将来のplatform固有実装で扱う。

## 6. 必要な機能

### 6.1 最初の利用可能版

| 領域 | 関数・挙動 |
|---|---|
| Lifecycle | create、run、close要求、destroy、state取得 |
| Window | title設定、size設定 |
| Content | navigate、HTML設定、init script、eval script |
| Binding | bind、unbind、request dataのcopy、binding寿命管理 |
| Call response | JSON resolve/reject、cancel、重複応答拒否 |
| Dispatch | OCaml Domainからenqueueし、UI threadで実行 |
| Error | 型付きoperationとnative error code |
| Version | 固定した上流webviewのversion取得 |
| Diagnostics | state、binding root、dispatch root、pending call |

### 6.2 制限・延期するAPI

- `get_window`と`get_native_handle`は`Webui_raw.Unsafe_platform`配下に置く。
- 既存native Windowへのembedは延期する。
- native callbackの任意user dataは内部実装だけで使う。
- 文字列IDによる直接`webview_return`は公開せず、one-shotの`Call.t`を渡す。
- worker Domainからnative APIを直接呼ばせず、必ずdispatchを使う。

## 7. OCaml API案

以下は設計契約であり、最終syntaxではない。

```ocaml
module Error : sig
  type code =
    | Missing_dependency
    | Cancelled
    | Invalid_state
    | Invalid_argument
    | Duplicate
    | Not_found
    | Unspecified
    | Unknown of int

  type operation =
    | Create | Run | Request_close | Destroy
    | Set_title | Set_size | Navigate | Set_html | Init | Eval
    | Bind | Unbind | Dispatch | Respond

  type t = {
    operation : operation;
    code : code;
    message : string;
  }
end

module Window : sig
  type t

  type state =
    | Created
    | Running
    | Closing
    | Stopped
    | Destroyed

  type size_hint = Initial | Minimum | Maximum | Fixed
  type config = { debug : bool }

  val create : config -> (t, Error.t) result
  val state : t -> state
  val run : t -> (unit, Error.t) result
  val request_close : t -> (unit, Error.t) result
  val destroy : t -> (unit, Error.t) result
  val with_window : config -> (t -> 'a) -> ('a, Error.t) result

  val set_title : t -> string -> (unit, Error.t) result
  val set_size :
    t -> width:int -> height:int -> size_hint -> (unit, Error.t) result
  val navigate : t -> string -> (unit, Error.t) result
  val set_html : t -> string -> (unit, Error.t) result
  val init : t -> string -> (unit, Error.t) result
  val eval : t -> string -> (unit, Error.t) result
  val dispatch : t -> (unit -> unit) -> (unit, Error.t) result
end

module Call : sig
  type t

  type response_submission =
    [ `Queued
    | `Already_completed
    | `Window_closing
    | `Enqueue_failed of Error.t ]

  type cancellation = [ `Cancelled | `Already_completed ]

  val request_json : t -> string
  val resolve_json : t -> string -> response_submission
  val reject_json : t -> string -> response_submission
  val cancel : t -> cancellation
end

module Binding : sig
  type t

  val create :
    Window.t -> name:string -> (Call.t -> unit) -> (t, Error.t) result
  val remove : t -> (unit, Error.t) result
end

module Diagnostics : sig
  type snapshot = {
    window_state : Window.state;
    binding_roots : int;
    dispatch_roots : int;
    pending_calls : int;
    queued_dispatches : int;
    dispatch_enqueued : int;
    dispatch_executed : int;
    dispatch_cancelled : int;
    callback_exceptions : int;
    response_failures : int;
  }

  val snapshot : Window.t -> snapshot
  val leaked_windows : unit -> int
end
```

最初の版では境界のJSONを文字列として扱う。JSON validityとtyped codecは上位bridgeの
責務とする。`Queued`はowner-thread delivery queueへの受理であり、JavaScriptへの到達
保証ではない。native response失敗は`response_failures`で観測する。一方、`Call.t`は
response stateを所有し、二重応答やshutdown後応答を行えないようにする。

## 8. Webui_raw内部のレイヤー

```text
webui_raw.mli
  公開する低水準OCaml契約

webui_raw.ml
  型付きerror、state check、result変換、安全なwrapper

webui_raw_native.ml
  非公開external declarationのみ

webui_raw_stubs.cpp
  C++ context、runtime lock、root、上流webview call

platform/windows/
  WebView2 header、link flag、Windows専用diagnostics/test helper
```

公開moduleはnative pointerや`external` declarationを露出しない。unsafeな呼び出しは
private native moduleに閉じ込める。

## 9. Native contextと所有権

各`Window.t`は概念上、次のnative contextを所有する。

```text
window_context
  native webview handle
  lifecycle state
  UI owner thread identity
  mutex
  active bindings by name
  pending calls by native call ID
  dispatch queue
  native wakeup scheduled flag
  diagnostic counters
```

contextはabstractなOCaml custom blockの背後に置く。native WebViewはowner thread上の
明示的な`Window.destroy`だけがdestroyする。

custom-block finalizerはWebView APIを呼ばない。誤ったDomain/threadで実行される
可能性があるためである。明示destroy済みなら不活性contextを解放できる。live contextが
finalizeされた場合、debug buildはlifecycle leakを報告するが危険な自動cleanupはしない。

## 10. Threading契約

### 10.1 UI owner threadだけで許可する操作

- runとdestroy
- bindingの作成・削除
- title、size、navigation、HTML、init、eval
- dispatch workのdrainとJavaScript response送信

native contextはowner threadを記録し、誤った呼び出しには`Invalid_state`を返す。

### 10.2 Worker Domainから許可する操作

- `Window.dispatch`
- `Call.resolve_json`、`Call.reject_json`、`Call.cancel`
- `Window.request_close`

Call操作はone-shot所有権を取得してからUI workをenqueueする。closeもarbitrary threadから
WebView APIを直接呼ばず、thread-safe requestとして実装する。

### 10.3 Runtime lock規約

1. `webview_run`のblocking中はOCaml runtimeを解放し、OCamlへ戻る前に再取得する。
2. WebView callbackはOCaml valueへ触れる前にruntimeを取得する。
3. `CAMLdrop`は必ず`caml_release_runtime_system`より先に実行する。
4. rootのregister/removeはruntime保持中だけ行う。
5. C callback境界では`caml_callback*_exn`を使い、OCaml例外を越境させない。
6. OCaml未登録threadからcallbackする場合はthread登録・解除を行う。
7. OCaml raiseをまたいでdestructorが必要なC++ RAII objectを生存させない。

## 11. Lifecycle状態機械

```text
Created -------> Running -------> Closing -------> Stopped -------> Destroyed
   |                |                 ^               |
   |                +-- close/error --+               |
   +---------------- setup failure -------------------+
```

- `Closing`後は新規bindingとdispatchを拒否する。
- `run`から戻ったら`Running`または`Closing`を`Stopped`へ移す。
- destroy前にpending callとqueued dispatchをcancelする。
- setup failure時は`Created`から、通常終了時は`Stopped`からdestroyできる。
- destroyはOCaml API上でidempotentにする。
- native handleをclearしてから`Destroyed`を公開する。

C++ contextをnative safety stateの正本とする。上位runtimeはmirrorできるが、
この検査を迂回できない。

## 12. Call response状態機械

```text
Pending ---> Dispatch_queued ---> Responded
   |               |
   +-------------> Cancelled
   |
   +-------------> Failed
```

response所有権の取得とWindow state確認を1つの同期された遷移として行う。
Phase 1のようにlifecycleを読み、その後別操作でdispatchする形では間にcloseが入る。

- resolve、reject、cancel、failureのうち正確に1つだけが勝つ。
- 重複完了はnative workをせず`Already_completed`を返す。
- queue前のresponseよりclosingを優先する。
- queued responseはnative destroy前にcancelできる。
- dispatch enqueue失敗時は`Failed`へ移しrootを解放する。
- JavaScript responseはUI owner threadからのみ送る。

## 13. Dispatch設計

上流`webview_dispatch`ごとに独立したOCaml closureを渡さない。この方式では、native
callback実行前にWindowが閉じた場合、queued closureの所有権が曖昧になる。

`Webui_raw`はWindowごとのqueueを所有する。

1. workerはclosure rootをregisterし、context mutex下でqueueへpushする。
2. queueが空でない間、native UI wakeupは最大1つだけscheduleする。
3. wakeupには個々のclosureではなく安定したWindow contextを渡す。
4. UI trampolineはmutexを保持せずaccepted itemをswap/drainする。
5. closure rootは実行後またはcancel後に正確に1回removeする。
6. Closingは新規itemを拒否し、destroy前にqueued itemをcancelする。

OCaml closure実行中やcallback/raise/blockし得るnative API呼び出し中はmutexを保持しない。

## 14. Bindingとcallback設計

各bindingはWindow context、一意な名前、handler用global root、active/removed stateを持つ。

binding trampolineの順序:

1. OCaml runtime/threadを取得・登録する。
2. native call IDとrequest JSONを直ちにcopyする。
3. Window所有のpending `Call.t`を作る。
4. `caml_callback_exn`でOCaml handlerを呼ぶ。
5. 未処理例外をinternal failed-call eventへ変換する。
6. runtime解放前にlocal rootをdropする。

unbindとdestroyはnative bindingを削除してからOCaml rootを解放する。root removalは
idempotentにし、diagnosticsへ反映する。stableなapplication error schemaは上位bridgeが
決定する。

## 15. Error model

| Native code | OCaml code |
|---|---|
| `WEBVIEW_ERROR_MISSING_DEPENDENCY` | `Missing_dependency` |
| `WEBVIEW_ERROR_CANCELED` | `Cancelled` |
| `WEBVIEW_ERROR_INVALID_STATE` | `Invalid_state` |
| `WEBVIEW_ERROR_INVALID_ARGUMENT` | `Invalid_argument` |
| `WEBVIEW_ERROR_DUPLICATE` | `Duplicate` |
| `WEBVIEW_ERROR_NOT_FOUND` | `Not_found` |
| `WEBVIEW_ERROR_UNSPECIFIED` | `Unspecified` |
| 将来追加されたinteger | `Unknown n` |

FFI内部ではprivate exceptionを使ってよいが、公開wrapperが捕捉して
`(value, Error.t) result`へ変換する。汎用`Failure`は公開契約に含めない。
すべてのC++例外を`extern "C"`境界で捕捉し、runtime保持中に変換する。

## 16. Buildと依存方針

初期サポートはWindowsだけとする。

- OCaml: project-local opam switchの5.4.x
- Dune: 現在のproject version以上の互換release
- C++: OCaml switchと互換性のあるMinGW-w64 toolchain
- 上流webview: 最初は0.12相当のdirect revisionを固定
- WebView2 SDK header: 固定した上流webviewが要求するversion
- WebView2 Runtime: create時に確認するsystem dependency

root buildでowebviewのexample/configを再帰buildしない。既知のmanual C++ object ruleで
bootstrapできるが、compiler executableを説明なくhard-codeしない。config stepで
選択compilerとlink libraryを記録する。root opam package定義とnative prerequisiteの
setup手順も追加する。

## 17. Diagnosticsと不変条件

debug/test buildで次を観測する。

- active binding root
- queued/running dispatch root
- state別pending call
- lifecycle transition
- close後に拒否したoperation
- callback exception
- dispatch enqueue/drain/cancel回数

テストで次をassertする。

- rootを二重register/removeしない。
- destroy後にrootを残さない。
- context mutex保持中にuser callbackを実行しない。
- 許可したwakeup path以外のnative callをworkerから実行しない。
- `Closing`後にdispatchをacceptしない。
- Callを2回以上完了しない。
- clear済みnative handleを使わない。
- native destroyを2回呼ばない。

diagnosticsはhookへ流し、通常動作ではstdoutへ直接書かない。

## 18. Source構成

```text
lib/
  raw/
    dune
    webui_raw.mli
    webui_raw.ml
    webui_raw_native.ml
    webui_raw_stubs.cpp
    platform/
      windows/
        dune
        webview2_config.ml

test/
  raw/
    state_machine_test.ml
    root_lifecycle_test.ml
    dispatch_stress.ml
    window_close_stress.ml

vendor/
  webview/                 # 固定した上流direct dependency
  webview2-sdk-<version>/

spikes/
  phase1-*                 # Webui_rawへ移行し、検証記録として残す
```

## 19. 7段階の実装計画

### Step 1: Repositoryと依存の基盤

- 上流`webview`を直接pinする。
- owebviewを通常Dune workspaceから分離・除去する。
- root opam/build metadataを追加する。
- binding実装前に`dune build @all`を成功させる。
- compiler、WebView2 SDK、runtime、licenseの出所を記録する。

合格条件: clean checkoutからowebview exampleや未宣言libraryを要求せずroot buildが成功する。

### Step 2: API skeletonと純粋な状態機械

- `Error`、`Window.state`、`Call` completion state、private native API
- 全valid/invalid transitionのpure unit test
- `.mli`にthread affinityとresult API契約を記載

合格条件: duplicate response、close-before-response、response-before-close、setup failure、
double destroyをtestでcoverする。

### Step 3: Native contextと基本Window lifecycle

- native context custom block
- create、title、size、HTML/navigation、run、close request、destroy
- owner-thread checkとtyped native error変換
- `webview_run`周辺の正しいruntime解放
- この段階ではcallback/bindingを実装しない

合格条件: create/run/close/destroyを繰り返し、setup failure後にleakを残さない。

### Step 4: 所有するdispatch queue

- Window単位の同期queueと単一native wakeup
- queued closureのroot所有権
- callback exception捕捉
- close中のqueue拒否/cancel
- enqueue、drain、cancel、rootのdiagnostics

合格条件: Phase 1 threading probeが`Webui_raw`を使い、dispatch/close競合後もrootが0。

### Step 5: Bindingとone-shot Call token

- bind/unbind root registry
- copy済みrequest JSONとabstractな`Call.t`
- resolve/reject/cancel state machine
- structured callback-exception hook
- publicなresponse-by-ID APIを作らない

合格条件: Domain success、exception、duplicate、enqueue failureが1回だけ完了しrootを解放。

### Step 6: Shutdownと並行処理の強化

- Closing -> Stopped -> Destroyedの協調終了
- response claim/dispatch drain周辺のclose timingランダム化
- 複数pending callと複数Window
- CPU-bound処理とallocation/GC stress
- 異常な`run`/callback/dispatch failure時のcleanup

合格条件:

- 少なくとも100回のrandomized closeが成功する。
- queued-before-closeとenqueue-during-closeを明示的に観測する。
- 複数pending callが決定的にcancelされる。
- destroy後のdiagnosticsが0になる。
- crash、hang、duplicate completion、post-destroy accessがない。

### Step 7: 移行とraw契約のfreeze

- 3つのPhase 1スパイクをpatch scriptなしで`Webui_raw`上へ移行する。
- owebviewをbuild dependencyから削除する。
- 公開`.mli`、lifecycle図、supported-thread表をreviewする。
- このgate後に手書きbridgeベースラインを開始する。

合格条件: clean checkoutからroot buildとfocused runtime testが成功し、`spikes/`配下に
owebview stubのcopy/patchが残らない。

## 20. Test matrix

| Test | 必須観測 |
|---|---|
| Blocking callback | native UI dispatchが待機し、renderer結果を記録 |
| Domain success | callbackが短時間でreturnし、owner threadで応答 |
| Domain failure | rejectは1回だけで例外がC境界を越えない |
| Duplicate response | 2回目をnative workなしで拒否 |
| work完了前のclose | response cancel、worker join、root 0 |
| enqueue中のclose | queue所有権またはcloseがatomicに勝つ |
| queue後のclose | destroy前にdrain/cancelし、leakしない |
| native enqueue failure | rootをrollbackし、CallをFailedへ移す |
| CPU-bound Domain | 実multicore負荷中もUIが動作 |
| Allocation/GC stress | closureが有効で、その後解放される |
| Concurrent calls | 独立one-shot stateと決定的shutdown |
| Multiple Windows | lifecycle、root、dispatchがWindow scopeになる |
| Repeated create/destroy | process growth、stale handle、double destroyがない |

自動close testは3000 ms taskの500 ms地点に固定せずtimingをランダム化する。
4回の決め打ち成功はbasic pathの証拠だがrace境界には不十分である。

## 21. Riskと対策

### 上流callback保証

Risk: shutdown開始時にnative dispatch callbackがqueue済みかもしれない。

対策: closure queueを所有し、native wakeupには安定したcontextだけを渡す。
`Closing`で新規itemを止め、destroy前にdrain/cancelし、stress testで検証する。

### OCaml 5 Domainsと共有native registry

Risk: 単一global runtime lock前提は複数Domainで成立しない。

対策: Window/binding変更をUI threadへ閉じ込め、cross-Domain queueに明示mutexを使う。
runtime所有権をC++ container mutexの代わりにしない。

### 明示destroyの呼び忘れ

Risk: native Window/contextとregistered rootがleakする。

対策: `Window.with_window`を標準のscope helperとして提供し、
`Diagnostics.leaked_windows`とroot countを公開する。finalizer threadから危険な
destroyをせず、呼び忘れは検出可能なleakとして扱う。

### Build portability

Risk: MinGW object ruleが説明のないWindows専用特殊処理になる。

対策: toolchain discoveryとnative prerequisiteをcode化し、platform ruleを隔離する。
macOS/Linuxはruntime testが通るまでsupportを表明しない。

## 22. 意図的に延期する未解決事項

- 上位runtimeでEio、Lwt、minimal Domain schedulerのどれを使うか
- stableなstructured application error schema
- Vite/hot-reload integrationとschema handshake
- custom scheme実装でWebView2 COM APIまで降りる必要があるか
- macOS/Linux buildとcallback-thread挙動
- platform-native handleをpublicにするか

これらはminimalで安全なWindows bindingの所有を妨げない。

## 23. 決定事項の要約

1. 手書きbridgeベースラインより先に`Webui_raw`を実装する。
2. OCaml FFI、lifecycle、root、dispatch queue、one-shot Call tokenを所有する。
3. 固定した上流`webview`実装とWebView2は引き続き利用する。
4. JSON/Typed Command/Trace/Eio/Lwtはこの層より上、または外に置く。
5. explicit destroyを使い、GC finalizerからnative Windowをdestroyしない。
6. closeとresponse dispatchを同期されたstate transitionとして扱う。
7. clean root buildとrandomized shutdown stressをPhase 2開始条件にする。
