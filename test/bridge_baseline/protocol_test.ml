module Bridge = Webui_bridge_baseline

let fail format = Printf.ksprintf failwith format

let expect_decode_error expected_code json =
  match Bridge.Protocol.decode_request_json json with
  | Error { error = { code; _ }; _ } when code = expected_code -> ()
  | Error { error = { code; message; _ }; _ } ->
      fail "expected decode error %s but received %s: %s" expected_code code
        message
  | Ok _ -> fail "expected decode error %s" expected_code

let require_member name json =
  match json with
  | `Assoc fields -> (
      match List.assoc_opt name fields with
      | Some value -> value
      | None -> fail "missing JSON field %s" name)
  | _ -> fail "expected JSON object"

let expect_string expected = function
  | `String actual when actual = expected -> ()
  | actual ->
      fail "expected string %S but received %s" expected
        (Yojson.Safe.to_string actual)

let test_valid_request () =
  let json =
    {|[{"protocol":1,"requestId":"request-1","traceId":"trace-1","command":"text.analyze","payload":{"text":"hello"}}]|}
  in
  match Bridge.Protocol.decode_request_json json with
  | Error { error = { code; message; _ }; _ } ->
      fail "valid request failed with %s: %s" code message
  | Ok request ->
      if request.context.request_id <> "request-1" then
        fail "request ID was not decoded";
      if request.context.trace_id <> "trace-1" then
        fail "trace ID was not decoded";
      if request.context.command <> "text.analyze" then
        fail "command was not decoded";
      require_member "text" request.payload |> expect_string "hello"

let test_decode_failures () =
  expect_decode_error "invalid_json" "[";
  expect_decode_error "invalid_request" "[]";
  expect_decode_error "protocol_mismatch"
    {|[{"protocol":2,"requestId":"r","traceId":"t","command":"c","payload":null}]|};
  expect_decode_error "invalid_request"
    {|[{"protocol":1,"requestId":"r","command":"c","payload":null}]|};
  expect_decode_error "invalid_request"
    {|[{"protocol":1,"requestId":"r","traceId":"t","command":"c"}]|}

let test_response_identity () =
  let context =
    Bridge.
      { request_id = "request-9"; trace_id = "trace-9"; command = "echo" }
  in
  let success =
    Bridge.Protocol.success_json context (`Assoc [ ("answer", `Int 42) ])
    |> Yojson.Safe.from_string
  in
  require_member "requestId" success |> expect_string "request-9";
  require_member "traceId" success |> expect_string "trace-9";
  require_member "command" success |> expect_string "echo";
  (match require_member "ok" success with
  | `Bool true -> ()
  | _ -> fail "success response did not set ok=true");
  let error =
    Bridge.Error.make ~category:"validation" ~code:"bad_value"
      ~message:"bad value" ()
  in
  let failure =
    Bridge.Protocol.failure_json (Some context) error
    |> Yojson.Safe.from_string
  in
  require_member "requestId" failure |> expect_string "request-9";
  require_member "traceId" failure |> expect_string "trace-9";
  let error_json = require_member "error" failure in
  require_member "code" error_json |> expect_string "bad_value";
  require_member "category" error_json |> expect_string "validation"

let () =
  test_valid_request ();
  test_decode_failures ();
  test_response_identity ();
  Printf.printf "protocol_test: passed request error response contracts\n%!"
