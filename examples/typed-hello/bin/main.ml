(* examples/typed-hello — commands.ml宣言駆動Command生成の参照実装。

   - hello.ping : sync Command、ATD型 + 型付き validation error
   - work.count : async Command、cancellation_token checkpoint poll +
                  30s watchdog timeout
   - trace.recent : raw_json Command、unified trace ring buffer の
                    内容を返す debug用 Command

   Commandのwire名・codec・登録listは bin/commands.ml (SSOT) から
   ocaml-webui.command-gen が生成する commands_gen.ml が全て担う。
   人が書くのは handlers record への handler 実装だけ。 *)

module Bridge = Webui_bridge_atd
module Schema = Hello_schema.Hello

let require = function
  | Ok value -> value
  | Error error -> failwith (Webui_raw.Error.to_string error)

(* unified trace ring buffer — JS -> OCaml -> response_submitted の
   全ライフサイクルイベントを最新512件保持する。 *)
let trace_sink, trace_snapshot = Webui_trace.ring_buffer ~capacity:512

let max_ping_length = 1000

(* hello.ping — sync。型付き error を responder_reject で返すと
   JS側では ApplicationError + typedError として decode される。 *)
let hello_ping_handler (context : Bridge.context)
    (request : Schema.hello_ping_request) responder =
  let open Schema in
  let submission =
    if String.length request.message = 0 then
      Bridge.responder_reject responder
        { code = Empty_message;
          message = "message must not be empty";
          retryable = false;
          category = "validation" }
    else if String.length request.message > max_ping_length then
      Bridge.responder_reject responder
        { code = Too_long;
          message =
            Printf.sprintf "message length %d exceeds limit %d"
              (String.length request.message) max_ping_length;
          retryable = false;
          category = "validation" }
    else
      Bridge.responder_resolve responder
        { echoed = request.message;
          length = String.length request.message;
          observed_trace_id = context.trace_id }
  in
  ignore submission

(* work.count — async。target回 x delay_ms の busy loop を
   token checkpoint で分割し、cancel を観測したら早期 return。
   応答を送らず return した場合 bridge が cancelled reject を出す。 *)
let work_count_handler _context request responder token =
  let open Schema in
  let start = Unix.gettimeofday () in
  let rec loop i =
    if i >= request.target then true
    else if Bridge.token_is_cancelled token then false
    else begin
      Unix.sleepf (float request.delay_ms /. 1_000.);
      loop (i + 1)
    end
  in
  let completed = loop 0 in
  if completed && not (Bridge.token_is_cancelled token) then
    ignore
      (Bridge.responder_resolve responder
         { counted = request.target;
           elapsed_ms =
             int_of_float
               ((Unix.gettimeofday () -. start) *. 1_000.);
           cancelled = false })

(* trace.recent — ring buffer の最新イベントをそのまま返す。
   invoke 直前のイベント (invoke_received) も含まれる。 *)
let trace_recent_handler _context () responder =
  ignore
    (Bridge.responder_resolve responder
       (`Assoc
         [ ( "events",
             `List (List.map Webui_trace.to_yojson (trace_snapshot ())) ) ]))

let html =
  Printf.sprintf {html|<!doctype html>
<meta charset="utf-8">
<title>ocaml-webui typed-hello</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 2rem; }
  h2 { margin-top: 1.5rem; }
  button, input { padding: .3rem .6rem; margin-right: .4rem; }
  pre { background: #f4f4f4; padding: 1rem; white-space: pre-wrap;
        min-height: 8rem; }
</style>
<div id="app"></div>
<script>
%s
</script>
|html} Bundle_embed.bundle

let () =
  Printexc.record_backtrace true;
  let window = require (Webui_raw.Window.create { debug = false }) in
  (match
     Bridge.install ~trace:trace_sink window
       ~commands:
         (Commands_gen.commands
            { Commands_gen.hello_ping = hello_ping_handler;
              work_count = work_count_handler;
              trace_recent = trace_recent_handler })
   with
   | Ok _bridge -> ()
   | Error (Bridge.Duplicate_command name) ->
       failwith ("duplicate command: " ^ name)
   | Error (Bridge.Raw_error error) ->
       failwith (Webui_raw.Error.to_string error));
  require (Webui_raw.Window.set_title window "ocaml-webui typed-hello");
  require (Webui_raw.Window.set_size window ~width:720 ~height:560 Initial);
  require (Webui_raw.Window.set_html window html);
  (* dev検証フック: OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS=<ms> で
     指定ms後に window close — headless smoke test用 *)
  (match Sys.getenv_opt "OCAML_WEBUI_EXAMPLE_AUTOCLOSE_MS" with
   | Some ms ->
       let ms = int_of_string ms in
       ignore
         (Thread.create
            (fun () ->
              Unix.sleepf (float ms /. 1_000.);
              ignore (Webui_raw.Window.request_close window))
            ())
   | None -> ());
  require (Webui_raw.Window.run window);
  require (Webui_raw.Window.destroy window)
