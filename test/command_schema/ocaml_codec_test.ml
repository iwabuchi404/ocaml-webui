module Schema = Command_schema.Text_analyze

let fail msg = failwith msg

(** [expect_raises label f] runs [f ()] and verifies that it raises.
    If [f ()] returns normally, the test fails. This avoids the
    common bug where an assertion [fail] inside a [try] is caught
    by the same [with _] that expects the decoder exception. *)
let expect_raises label f =
  match f () with
  | exception _ -> ()
  | _ -> fail (label ^ " — expected exception")

let read_fixture name =
  let dir = Filename.dirname Sys.executable_name in
  let path = Filename.concat (Filename.concat dir "fixtures") name in
  let chan = open_in path in
  let len = in_channel_length chan in
  let buf = Bytes.create len in
  really_input chan buf 0 len;
  close_in chan;
  Bytes.to_string buf

let expect_round_trip_request () =
  let json = read_fixture "request-valid.json" in
  let request = Schema.text_analyze_request_of_json json in
  if request.text <> "hello typed bridge" then
    fail ("request text mismatch: " ^ request.text);
  if request.delay_ms <> 50 then
    fail ("request delayMs mismatch: " ^ string_of_int request.delay_ms);
  let reencoded = Schema.json_of_text_analyze_request request in
  let reparsed = Schema.text_analyze_request_of_json reencoded in
  if reparsed.text <> request.text || reparsed.delay_ms <> request.delay_ms then
    fail "request round-trip failed"

let expect_round_trip_result () =
  let json = read_fixture "result-valid.json" in
  let result = Schema.text_analyze_result_of_json json in
  if result.bytes <> 18 then fail ("result bytes mismatch: " ^ string_of_int result.bytes);
  if result.words <> 3 then fail ("result words mismatch: " ^ string_of_int result.words);
  if result.observed_trace_id <> "trace-success" then
    fail ("result observedTraceId mismatch: " ^ result.observed_trace_id);
  let reencoded = Schema.json_of_text_analyze_result result in
  let reparsed = Schema.text_analyze_result_of_json reencoded in
  if reparsed.bytes <> result.bytes || reparsed.words <> result.words
  || reparsed.observed_trace_id <> result.observed_trace_id then
    fail "result round-trip failed"

let expect_round_trip_error () =
  let json = read_fixture "error-valid.json" in
  let error = Schema.text_analyze_error_of_json json in
  (match error.code with
   | Empty_text -> ()
   | _ -> fail "error code mismatch");
  if error.message <> "text must not be empty" then
    fail ("error message mismatch: " ^ error.message);
  if error.retryable <> false then fail "error retryable should be false";
  if error.category <> "validation" then
    fail ("error category mismatch: " ^ error.category);
  let reencoded = Schema.json_of_text_analyze_error error in
  let reparsed = Schema.text_analyze_error_of_json reencoded in
  (match reparsed.code with
   | Empty_text -> ()
   | _ -> fail "error round-trip code mismatch");
  if reparsed.message <> error.message then
    fail "error round-trip message mismatch"

let expect_decode_failures () =
  expect_raises "missing delayMs"
    (fun () -> ignore (Schema.text_analyze_request_of_json {|{"text":"hi"}|}));
  expect_raises "missing text"
    (fun () -> ignore (Schema.text_analyze_request_of_json {|{"delayMs":50}|}));
  expect_raises "wrong text type"
    (fun () -> ignore (Schema.text_analyze_request_of_json {|{"text":123,"delayMs":50}|}));
  expect_raises "wrong delayMs type"
    (fun () -> ignore (Schema.text_analyze_request_of_json {|{"text":"hi","delayMs":"50"}|}));
  expect_raises "unknown error code"
    (fun () -> ignore (Schema.text_analyze_error_code_of_yojson (`String "unknown_code")));
  expect_raises "missing observedTraceId"
    (fun () -> ignore (Schema.text_analyze_result_of_json {|{"bytes":1,"words":2}|}))

let expect_variant_json_strings () =
  let check code expected =
    let json = Schema.json_of_text_analyze_error_code code in
    let stripped =
      String.sub json 1 (String.length json - 2)
    in
    if stripped <> expected then
      fail ("variant JSON mismatch: got " ^ stripped ^ " expected " ^ expected)
  in
  check Empty_text "empty_text";
  check Invalid_delay "invalid_delay";
  check Invalid_text "invalid_text";
  check Invalid_payload "invalid_payload"

let expect_unknown_field_tolerance () =
  let json =
    {|{"text":"hi","delayMs":10,"extra":"ignored","more":42}|}
  in
  let request = Schema.text_analyze_request_of_json json in
  if request.text <> "hi" then fail "unknown field: text mismatch";
  if request.delay_ms <> 10 then fail "unknown field: delayMs mismatch"

let () =
  expect_round_trip_request ();
  expect_round_trip_result ();
  expect_round_trip_error ();
  expect_decode_failures ();
  expect_variant_json_strings ();
  expect_unknown_field_tolerance ();
  Printf.printf
    "ocaml_codec_test: passed round-trip decode variant unknown-field\n%!"
