module Schema = Command_schema.Echo

let fail msg = failwith msg

(** [expect_raises label f] runs [f ()] and verifies that it raises.
    If [f ()] returns normally, the test fails. *)
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
  let json = read_fixture "echo-request-valid.json" in
  let request = Schema.echo_request_of_json json in
  if request.message <> "hello echo" then
    fail ("request message mismatch: " ^ request.message);
  let reencoded = Schema.json_of_echo_request request in
  let reparsed = Schema.echo_request_of_json reencoded in
  if reparsed.message <> request.message then
    fail "request round-trip failed"

let expect_round_trip_result () =
  let json = read_fixture "echo-result-valid.json" in
  let result = Schema.echo_result_of_json json in
  if result.echoed <> "hello echo" then
    fail ("result echoed mismatch: " ^ result.echoed);
  if result.length <> 10 then
    fail ("result length mismatch: " ^ string_of_int result.length);
  let reencoded = Schema.json_of_echo_result result in
  let reparsed = Schema.echo_result_of_json reencoded in
  if reparsed.echoed <> result.echoed || reparsed.length <> result.length then
    fail "result round-trip failed"

let expect_round_trip_error () =
  let json = read_fixture "echo-error-valid.json" in
  let error = Schema.echo_error_of_json json in
  (match error.code with
   | Empty_message -> ()
   | _ -> fail "error code mismatch");
  if error.message <> "message must not be empty" then
    fail ("error message mismatch: " ^ error.message);
  if error.retryable <> false then fail "error retryable should be false";
  if error.category <> "validation" then
    fail ("error category mismatch: " ^ error.category);
  let reencoded = Schema.json_of_echo_error error in
  let reparsed = Schema.echo_error_of_json reencoded in
  (match reparsed.code with
   | Empty_message -> ()
   | _ -> fail "error round-trip code mismatch");
  if reparsed.message <> error.message then
    fail "error round-trip message mismatch"

let expect_decode_failures () =
  expect_raises "missing message"
    (fun () -> ignore (Schema.echo_request_of_json {|{}|}));
  expect_raises "wrong message type"
    (fun () -> ignore (Schema.echo_request_of_json {|{"message":123}|}));
  expect_raises "unknown error code"
    (fun () -> ignore (Schema.echo_error_code_of_yojson (`String "unknown_code")));
  expect_raises "missing length"
    (fun () -> ignore (Schema.echo_result_of_json {|{"echoed":"hi"}|}))

let expect_variant_json_strings () =
  let check code expected =
    let json = Schema.json_of_echo_error_code code in
    let stripped =
      String.sub json 1 (String.length json - 2)
    in
    if stripped <> expected then
      fail ("variant JSON mismatch: got " ^ stripped ^ " expected " ^ expected)
  in
  check Empty_message "empty_message";
  check Too_long "too_long"

let expect_unknown_field_tolerance () =
  let json =
    {|{"message":"hi","extra":"ignored","more":42}|}
  in
  let request = Schema.echo_request_of_json json in
  if request.message <> "hi" then fail "unknown field: message mismatch"

let () =
  expect_round_trip_request ();
  expect_round_trip_result ();
  expect_round_trip_error ();
  expect_decode_failures ();
  expect_variant_json_strings ();
  expect_unknown_field_tolerance ();
  Printf.printf
    "echo_codec_test: passed round-trip decode variant unknown-field\n%!"
