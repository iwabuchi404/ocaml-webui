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

let expect_duplicate_command () =
  let codec =
    Bridge.make_codec
      ~input_of_yojson:(fun _ -> ())
      ~output_to_yojson:(fun _ -> `Null)
      ~error_to_yojson:(fun _ -> `Null)
  in
  let cmd = Bridge.define codec ~name:"dup" (fun _ _ _ -> ()) in
  let window =
    match Webui_raw.Window.create { debug = false } with
    | Ok w -> w
    | Error e -> fail ("window create failed: " ^ Webui_raw.Error.to_string e)
  in
  (match Bridge.install window ~commands:[Bridge.pack cmd; Bridge.pack cmd] with
   | Error (Bridge.Duplicate_command "dup") -> ()
   | Error (Bridge.Duplicate_command name) ->
     fail ("duplicate name mismatch: " ^ name)
   | Error (Bridge.Raw_error e) ->
     fail ("unexpected raw error: " ^ Webui_raw.Error.to_string e)
   | Ok _ -> fail "duplicate command not detected");
  ignore (Webui_raw.Window.destroy window)

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

let () =
  expect_valid_request ();
  expect_invalid_json ();
  expect_protocol_mismatch ();
  expect_missing_field ();
  expect_response_identity ();
  expect_application_error_envelope ();
  expect_duplicate_command ();
  Printf.printf "atd_protocol_test: passed request error response identity app-error duplicate\n%!"
