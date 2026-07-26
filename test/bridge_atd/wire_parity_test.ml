(** Wire parity test: baseline and ATD application error envelopes
    must produce structurally identical JSON. *)

module Baseline = Webui_bridge_baseline
module Atd = Webui_bridge_atd
module Schema = Command_schema.Text_analyze

let fail msg = failwith msg

let baseline_error_json =
  let error =
    Baseline.Error.make ~category:"validation" ~code:"empty_text"
      ~message:"text must not be empty" ()
  in
  Baseline.Protocol.failure_json
    (Some
       { Baseline.request_id = "req-1"; trace_id = "trace-1"; command = "text.analyze" })
    error

let atd_error_json =
  let error =
    Schema.
      { code = Empty_text;
        message = "text must not be empty";
        retryable = false;
        category = "validation"
      }
  in
  Atd.Protocol.failure_json_raw
    (Some
       { Atd.request_id = "req-1"; trace_id = "trace-1"; command = "text.analyze" })
    (Schema.yojson_of_text_analyze_error error)

let expect_json_equal () =
  let baseline = Yojson.Safe.from_string baseline_error_json in
  let atd = Yojson.Safe.from_string atd_error_json in
  (* Compare structurally, ignoring key order *)
  let rec json_equal a b =
    match (a, b) with
    | `Null, `Null -> true
    | `Bool x, `Bool y -> x = y
    | `Int x, `Int y -> x = y
    | `Float x, `Float y -> x = y
    | `String x, `String y -> x = y
    | `List xs, `List ys ->
      List.length xs = List.length ys && List.for_all2 json_equal xs ys
    | `Assoc xs, `Assoc ys ->
      List.length xs = List.length ys &&
      List.for_all
        (fun (k, v) ->
          match List.assoc_opt k ys with
          | Some v' -> json_equal v v'
          | None -> false)
        xs
    | _ -> false
  in
  if not (json_equal baseline atd) then
    fail
      (Printf.sprintf "wire parity failed:\n  baseline: %s\n  atd:      %s"
         baseline_error_json atd_error_json)

let expect_error_code_at_top_level () =
  let atd = Yojson.Safe.from_string atd_error_json in
  (match atd with
   | `Assoc fields ->
     (match List.assoc_opt "error" fields with
      | Some (`Assoc error_fields) ->
        (match List.assoc_opt "code" error_fields with
         | Some (`String "empty_text") -> ()
         | _ -> fail "error.code should be empty_text at top level");
        (match List.assoc_opt "details" error_fields with
         | None -> ()
         | _ -> fail "error should not have details wrapper")
      | _ -> fail "error field missing or not an object")
   | _ -> fail "response not an object")

let () =
  expect_json_equal ();
  expect_error_code_at_top_level ();
  Printf.printf "wire_parity_test: passed baseline vs ATD error envelope\n%!"
