# 手書きbridgeベースライン設計

更新日: 2026-07-20

## 目的

ロードマップ手順2として、将来のATD生成版が削減すべき定型実装を実物で測る。
これは完成版Typed Command APIではなく、学習教材・比較対象・下位raw APIの利用例である。

実装名は `Webui_bridge_baseline`、Dune package名は
`ocaml-webui.bridge-baseline` とする。「baseline」を名前に残し、後で生成版と誤認しない
ようにする。

## 暫定raw境界

このbridgeが使用する `Webui_raw` APIを次に限定する。

- `Window.init`
- `Binding.create/remove`
- `Call.request_json`
- `Call.resolve_json/reject_json/cancel`

Window生成、run、close、destroyはapplication側が所有する。Linuxではprocess initial
thread上のsingle-live-Window制約を維持する。非WSL Linux/macOS実機gateまではraw APIを
正式freezeせず、この限定面だけを暫定freezeとして扱う。

## Protocol v1

raw binding名は `__ocaml_webui_invoke` の1本だけとする。JavaScriptへは手書きclient
`globalThis.ocamlWebui.invoke(command, payload, options)` を `Window.init` で注入する。

raw bindingが受け取るJSONはJavaScript引数配列なので、wire requestは次の形になる。

```json
[{
  "protocol": 1,
  "requestId": "request-123",
  "traceId": "trace-456",
  "command": "text.analyze",
  "payload": { "text": "hello world", "delayMs": 50 }
}]
```

成功はPromise resolve、失敗はPromise rejectとし、両方に同じidentityを返す。

```json
{
  "protocol": 1,
  "requestId": "request-123",
  "traceId": "trace-456",
  "command": "text.analyze",
  "ok": true,
  "value": { "bytes": 11, "words": 2 }
}
```

```json
{
  "protocol": 1,
  "requestId": "request-123",
  "traceId": "trace-456",
  "command": "text.analyze",
  "ok": false,
  "error": {
    "code": "empty_text",
    "message": "text must not be empty",
    "retryable": false,
    "category": "validation"
  }
}
```

`requestId`は1回の呼出を識別し、`traceId`は将来のDomain/Workerをまたいで維持する。
現段階ではclientが未指定時に生成し、OCaml bridgeは検証・伝播する。Window ID、origin、
CapabilityはJavaScriptから自己申告させず、今回のbaseline対象外とする。

## 実行・所有権

handler型は `context -> payload -> Responder.t -> unit` とする。handlerは同期・Domainの
どちらでもよいが、UI callbackをblockしてはならない。`Responder`はraw `Call.t`を隠し、
success/error envelopeを必ず付加する。

- 最初のresolve/rejectだけを受理する
- 二重応答は `Already_completed`
- Window closeはraw層がpending Callをcancelする
- close後のlate responseも `Already_completed`
- handler例外はログへ元例外を残し、WebViewにはsanitized `internal_error`だけを返す

非同期runtimeは選定しない。baseline mini-appは標準 `Domain`を直接spawnして明示joinし、
この定型処理自体を将来比較できるようにする。

## 手書きで残る定型実装

- Command名の文字列registry
- request/response/error envelope codec
- application input/output/errorのYojson codec
- JavaScript client関数と型の手動同期
- Domain spawn/join
- response submissionの分岐
- trace eventの手動出力

次段階のATD版では、少なくともapplication codec、TypeScript型/client、Command registry、
schema hashをSSOTから生成し、このbaselineとの差分を数える。

### 初回計測値

空行を含む物理行数は次のとおり。生成版との比較では同じ数え方を使う。

| 対象 | 行数 | 非空行 |
|---|---:|---:|
| reusable handwritten bridge `.ml` | 256 | 228 |
| public `.mli` | 71 | 56 |
| `text.analyze` mini-app + embedded JS | 321 | 302 |
| pure protocol contract test | 86 | 78 |

1 Command追加の意味定義が、少なくともOCaml input型、手書きdecoder、handler/registry、
JavaScript invocation/result assertionへ分散した。今回は比較を見やすくするためmini-appの
1ファイルへ集めたが、実アプリではOCaml/TypeScript/testの複数ファイルになる。この変更点
分散と327行の汎用bridge本体がATD版の比較基準であり、単純な総行数だけでなく「Command
追加時に人が同期する箇所数」を主要指標にする。

## 受入条件

1. pure contract testでvalid request、malformed JSON、protocol mismatch、必須field欠落、
   success/error identity伝播を確認する。
2. WindowsとWSLgで `text.analyze` の成功、validation error、unknown Commandを1本の
   native binding経由で確認する。
3. handler例外の詳細はnative logだけに残し、WebViewにはsanitized
   `internal_error`を返す。
4. async handlerのcallbackは即returnし、Domain responseがUI dispatchされる。
5. 二重応答を拒否する。
6. pending中のWindow closeでCallをcancelし、late responseを拒否する。
7. run終了・destroy後にpending Callとbinding/dispatch rootが0になる。

## 対象外

- ATD/atdgen/atdts
- schema hash/handshake
- Eio/Lwt
- timeout/AbortSignal
- full trace store/debug viewer
- Capability/Scope
- Worker process
- Stream/Resource/Data Plane
