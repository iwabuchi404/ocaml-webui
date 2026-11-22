(* examples/minimal — コード生成・npm不要の最小サンプル。

   OCaml側: Webui_bridge_atd に passthrough codec の "echo" Command を
   1つ登録するだけ。入力JSONをそのまま返す。

   JS側: __ocaml_webui_invoke に protocol v1 envelope を手で組み立てて
   投げる。実アプリではここは生成client (webui_client.ts) が肩代わりする
   ので、このサンプルはプロトコルの素形を確認する用途。 *)

module Bridge = Webui_bridge_atd

let require = function
  | Ok value -> value
  | Error error -> failwith (Webui_raw.Error.to_string error)

(* JSON passthrough — 入力は decode せず handler にそのまま届き、
   出力も handler が組んだ JSON をそのまま返す。 *)
let echo_command =
  Bridge.define
    (Bridge.make_codec
       ~input_of_yojson:(fun j -> j)
       ~output_to_yojson:(fun j -> j)
       ~error_to_yojson:(fun message ->
         `Assoc
           [ ("code", `String "echo_error");
             ("message", `String message);
             ("retryable", `Bool false);
             ("category", `String "application") ]))
    ~name:"echo"
    (fun context request responder ->
      ignore
        (Bridge.responder_resolve responder
           (`Assoc
             [ ("echo", request);
               ("requestId", `String context.request_id);
               ("traceId", `String context.trace_id) ])))

let html = {html|<!doctype html>
<meta charset="utf-8">
<title>ocaml-webui minimal</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; }
  button { padding: .4rem 1rem; }
  pre { background: #f4f4f4; padding: 1rem; white-space: pre-wrap; }
</style>
<h1>ocaml-webui — minimal (raw protocol)</h1>
<p>Sends a hand-built protocol v1 envelope to the "echo" Command.</p>
<button id="send">invoke echo</button>
<pre id="out"></pre>
<script>
var seq = 0;
document.getElementById('send').addEventListener('click', function () {
  seq += 1;
  var envelope = {
    protocol: 1,
    requestId: 'request-' + seq,
    traceId: 'trace-' + seq,
    command: 'echo',
    payload: { message: 'hello', seq: seq }
  };
  var out = document.getElementById('out');
  out.textContent = 'sent: ' + JSON.stringify(envelope, null, 2);
  globalThis.__ocaml_webui_invoke(envelope).then(
    function (res) {
      out.textContent += '\n\nreceived: ' + JSON.stringify(res, null, 2);
    },
    function (rej) {
      out.textContent += '\n\nrejected: ' + JSON.stringify(rej, null, 2);
    });
});
</script>
|html}

let () =
  Printexc.record_backtrace true;
  let window = require (Webui_raw.Window.create { debug = false }) in
  (match Bridge.install window ~commands:[ Bridge.pack echo_command ] with
   | Ok _bridge -> ()
   | Error (Bridge.Duplicate_command name) ->
       failwith ("duplicate command: " ^ name)
   | Error (Bridge.Raw_error error) ->
       failwith (Webui_raw.Error.to_string error));
  require (Webui_raw.Window.set_title window "ocaml-webui minimal");
  require (Webui_raw.Window.set_size window ~width:640 ~height:480 Initial);
  require (Webui_raw.Window.set_html window html);
  require (Webui_raw.Window.run window);
  require (Webui_raw.Window.destroy window)
