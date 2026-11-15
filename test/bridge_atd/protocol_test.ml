module Bridge = Webui_bridge_atd

let fail msg = failwith msg

let expect_valid_request () =
  let json =
    {|[{"protocol":1,"requestId":"req-1","traceId":"trace-1","command":"text.analyze","payload":{"text":"hi","delayMs":10}}]|}
  in
  match Bridge.Protocol.decode_request_json json with
  | Ok request ->
    if request.context.request_id <> "req-1" then fail "requestId mismatch";
    if request.context.trace_id <> "trace-1" then fail "traceId mismatch";
    if request.context.command <> "text.analyze" then fail "command mismatch";
    (match request.payload with
     | `Assoc fields ->
       (match List.assoc_opt "text" fields with
        | Some (`String "hi") -> ()
        | _ -> fail "payload text mismatch")
     | _ -> fail "payload not an object")
  | Error _ -> fail "valid request decode failed"

let expect_invalid_json () =
  (match Bridge.Protocol.decode_request_json "not json" with
   | Error { Bridge.Protocol.error = { code; _ }; _ } ->
     if code <> "invalid_json" then fail ("expected invalid_json, got " ^ code)
   | Ok _ -> fail "invalid JSON should fail")

let expect_protocol_mismatch () =
  let json =
    {|[{"protocol":2,"requestId":"req-2","traceId":"trace-2","command":"test","payload":null}]|}
  in
  (match Bridge.Protocol.decode_request_json json with
   | Error { Bridge.Protocol.error = { code; _ }; _ } ->
     if code <> "protocol_mismatch" then fail ("expected protocol_mismatch, got " ^ code)
   | Ok _ -> fail "protocol mismatch should fail")

let expect_missing_field () =
  let json =
    {|[{"protocol":1,"requestId":"req-3","traceId":"trace-3","command":"test"}]|}
  in
  (match Bridge.Protocol.decode_request_json json with
   | Error { Bridge.Protocol.error = { code; _ }; _ } ->
     if code <> "invalid_request" then fail ("expected invalid_request, got " ^ code)
   | Ok _ -> fail "missing payload should fail")

let expect_response_identity () =
  let context =
    { Bridge.request_id = "req-4"; trace_id = "trace-4"; command = "test.cmd" }
  in
  let success = Bridge.Protocol.success_json context `Null in
  let parsed = Yojson.Safe.from_string success in
  (match parsed with
   | `Assoc fields ->
     (match List.assoc_opt "requestId" fields with
      | Some (`String "req-4") -> ()
      | _ -> fail "success response requestId mismatch");
     (match List.assoc_opt "traceId" fields with
      | Some (`String "trace-4") -> ()
      | _ -> fail "success response traceId mismatch");
     (match List.assoc_opt "command" fields with
      | Some (`String "test.cmd") -> ()
      | _ -> fail "success response command mismatch");
     (match List.assoc_opt "ok" fields with
      | Some (`Bool true) -> ()
      | _ -> fail "success response ok mismatch")
   | _ -> fail "success response not an object");
  let error = Bridge.Error.make ~code:"test_error" ~message:"test" () in
  let failure = Bridge.Protocol.failure_json (Some context) error in
  (match Yojson.Safe.from_string failure with
   | `Assoc fields ->
     (match List.assoc_opt "ok" fields with
      | Some (`Bool false) -> ()
      | _ -> fail "failure response ok mismatch");
     (match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) ->
        (match List.assoc_opt "code" error_fields with
         | Some (`String "test_error") -> ()
         | _ -> fail "error code mismatch")
      | _ -> fail "error field missing")
   | _ -> fail "failure response not an object")

let expect_application_error_envelope () =
  let context =
    { Bridge.request_id = "req-5"; trace_id = "trace-5"; command = "text.analyze" }
  in
  let raw_error_json =
    `Assoc
      [
        ("code", `String "empty_text");
        ("message", `String "text must not be empty");
        ("retryable", `Bool false);
        ("category", `String "validation");
      ]
  in
  let failure = Bridge.Protocol.failure_json_raw (Some context) raw_error_json in
  (match Yojson.Safe.from_string failure with
   | `Assoc fields ->
     (match List.assoc_opt "ok" fields with
      | Some (`Bool false) -> ()
      | _ -> fail "app error: ok should be false");
     (match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) ->
        (match List.assoc_opt "code" error_fields with
         | Some (`String "empty_text") -> ()
         | _ -> fail "app error: code should be empty_text at top level");
        (match List.assoc_opt "details" error_fields with
         | None -> ()
         | _ -> fail "app error: should not have details wrapper")
      | _ -> fail "app error: error field missing")
   | _ -> fail "app error: response not an object")

let expect_message_decode_invoke () =
  let json =
    {|[{"protocol":1,"requestId":"req-6","traceId":"trace-6","command":"text.analyze","payload":{"text":"hi","delayMs":10}}]|}
  in
  match Bridge.Protocol.decode_message_json json with
  | Ok (Bridge.Protocol.Invoke request) ->
      if request.context.request_id <> "req-6" then
        fail "invoke message requestId mismatch"
  | _ -> fail "invoke envelope should decode as Invoke"

let expect_message_decode_cancel () =
  let json =
    {|[{"protocol":1,"kind":"cancel","requestId":"cancel-1","traceId":"trace-7","targetRequestId":"req-6"}]|}
  in
  match Bridge.Protocol.decode_message_json json with
  | Ok (Bridge.Protocol.Cancel cancel) ->
      if cancel.request_id <> "cancel-1" then
        fail "cancel requestId mismatch";
      if cancel.trace_id <> "trace-7" then fail "cancel traceId mismatch";
      if cancel.target_request_id <> "req-6" then
        fail "cancel targetRequestId mismatch"
  | _ -> fail "cancel envelope should decode as Cancel"

let expect_message_decode_cancel_defaults () =
  let json =
    {|[{"protocol":1,"kind":"cancel","requestId":"cancel-2","targetRequestId":"req-7"}]|}
  in
  match Bridge.Protocol.decode_message_json json with
  | Ok (Bridge.Protocol.Cancel cancel) ->
      if cancel.trace_id <> "" then fail "cancel traceId should default to empty"
  | _ -> fail "cancel without traceId should still decode"

let expect_message_decode_invalid () =
  (match
     Bridge.Protocol.decode_message_json
       {|[{"protocol":1,"kind":"cancel","requestId":"cancel-3"}]|}
   with
  | Error { Bridge.Protocol.error = { code; _ }; _ } ->
      if code <> "invalid_request" then
        fail ("expected invalid_request, got " ^ code)
  | Ok _ -> fail "cancel without targetRequestId should fail");
  match
    Bridge.Protocol.decode_message_json
      {|[{"protocol":1,"kind":"bogus","requestId":"req-9"}]|}
  with
  | Error { Bridge.Protocol.error = { code; _ }; _ } ->
      if code <> "invalid_request" then
        fail ("expected invalid_request, got " ^ code)
  | Ok _ -> fail "unknown kind should fail"

let () =
  expect_valid_request ();
  expect_invalid_json ();
  expect_protocol_mismatch ();
  expect_missing_field ();
  expect_response_identity ();
  expect_application_error_envelope ();
  expect_message_decode_invoke ();
  expect_message_decode_cancel ();
  expect_message_decode_cancel_defaults ();
  expect_message_decode_invalid ();
  Printf.printf
    "atd_protocol_test: passed request error response identity app-error cancel\n%!"
