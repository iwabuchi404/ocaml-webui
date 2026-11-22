(* GENERATED FILE — do not edit. Source: command manifest. *)

module Bridge = Webui_bridge_atd

(* 全Commandのhandlerを必須化 — manifestに追加したCommandに
   handlerが無ければrecord構築時にビルドエラーになる。 *)
type handlers = {
  echo_ping : Bridge.context ->
    Test_schema.Echo.echo_request -> (Test_schema.Echo.echo_response, Test_schema.Echo.echo_error) Bridge.responder ->
    unit;
  work_slow : Bridge.context ->
    Test_schema.Work.work_request -> (Test_schema.Work.work_result, Test_schema.Work.work_error) Bridge.responder ->
    Bridge.cancellation_token -> unit;
  trace_recent : Bridge.context ->
    unit -> (Yojson.Safe.t, string) Bridge.responder ->
    unit;
}

(* install へそのまま渡せる packed list。
   manifestの全Commandを含むため pack 忘れは構造的に起きない。 *)
let commands (h : handlers) : Bridge.packed_command list =
  [
    Bridge.pack
      (Bridge.define
         (Bridge.make_codec
           ~input_of_yojson:Test_schema.Echo.echo_request_of_yojson
           ~output_to_yojson:Test_schema.Echo.yojson_of_echo_response
           ~error_to_yojson:Test_schema.Echo.yojson_of_echo_error)
         ~name:"echo.ping" h.echo_ping);
    Bridge.pack
      (Bridge.define_async
         (Bridge.make_codec
           ~input_of_yojson:Test_schema.Work.work_request_of_yojson
           ~output_to_yojson:Test_schema.Work.yojson_of_work_result
           ~error_to_yojson:Test_schema.Work.yojson_of_work_error)
         ~name:"work.slow" ~timeout_ms:5000 h.work_slow);
    Bridge.pack
      (Bridge.define
         (Bridge.make_codec
           ~input_of_yojson:(fun _ -> ())
           ~output_to_yojson:(fun j -> j)
           ~error_to_yojson:(fun message ->
             `Assoc
               [ ("code", `String "internal_error");
                 ("message", `String message);
                 ("retryable", `Bool false);
                 ("category", `String "internal") ]))
         ~name:"trace.recent" h.trace_recent);
  ]
