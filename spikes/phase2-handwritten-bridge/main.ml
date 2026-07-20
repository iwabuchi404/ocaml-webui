module Bridge = Webui_bridge_baseline

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

type analyze_request = { text : string; delay_ms : int }

let decode_analyze_request = function
  | `Assoc fields -> (
      match (List.assoc_opt "text" fields, List.assoc_opt "delayMs" fields) with
      | Some (`String text), Some (`Int delay_ms)
        when delay_ms >= 0 && delay_ms <= 2_000 ->
          Ok { text; delay_ms }
      | Some (`String _), Some (`Int _) ->
          Error
            (Bridge.Error.make ~category:"validation" ~code:"invalid_delay"
               ~message:"delayMs must be between 0 and 2000" ())
      | Some (`String _), _ ->
          Error
            (Bridge.Error.make ~category:"validation" ~code:"invalid_delay"
               ~message:"delayMs must be an integer" ())
      | _ ->
          Error
            (Bridge.Error.make ~category:"validation" ~code:"invalid_text"
               ~message:"text must be a string" ()))
  | _ ->
      Error
        (Bridge.Error.make ~category:"validation" ~code:"invalid_payload"
           ~message:"payload must be an object" ())

let word_count text =
  let words = ref 0 in
  let inside_word = ref false in
  String.iter
    (fun character ->
      let whitespace =
        match character with ' ' | '\t' | '\r' | '\n' -> true | _ -> false
      in
      if whitespace then inside_word := false
      else if not !inside_word then (
        inside_word := true;
        incr words))
    text;
  !words

type phase = {
  window : Webui_raw.Window.t;
  workers_mutex : Mutex.t;
  mutable workers : unit Domain.t list;
  handler_started : bool Atomic.t;
  first_submission : Webui_raw.Call.response_submission option Atomic.t;
  second_submission : Webui_raw.Call.response_submission option Atomic.t;
}

let create_phase () =
  {
    window = require (Webui_raw.Window.create { debug = false });
    workers_mutex = Mutex.create ();
    workers = [];
    handler_started = Atomic.make false;
    first_submission = Atomic.make None;
    second_submission = Atomic.make None;
  }

let add_worker phase worker =
  Mutex.protect phase.workers_mutex (fun () ->
      phase.workers <- worker :: phase.workers)

let join_workers phase =
  let workers =
    Mutex.protect phase.workers_mutex (fun () -> List.rev phase.workers)
  in
  List.iter Domain.join workers

let analyze_command phase =
  Bridge.command ~name:"text.analyze" (fun context payload responder ->
      if context.request_id = "request-handler-error" then
        failwith "intentional handwritten bridge handler failure"
      else
        match decode_analyze_request payload with
      | Error error ->
          Atomic.set phase.first_submission
            (Some (Bridge.Responder.reject responder error))
      | Ok request ->
          Atomic.set phase.handler_started true;
          let worker =
            Domain.spawn (fun () ->
                Unix.sleepf (float request.delay_ms /. 1_000.);
                let first =
                  if String.trim request.text = "" then
                    Bridge.Responder.reject responder
                      (Bridge.Error.make ~category:"validation"
                         ~code:"empty_text"
                         ~message:"text must not be empty" ())
                  else
                    Bridge.Responder.resolve responder
                      (`Assoc
                        [
                          ("bytes", `Int (String.length request.text));
                          ("words", `Int (word_count request.text));
                          ("observedTraceId", `String context.trace_id);
                        ])
                in
                Atomic.set phase.first_submission (Some first);
                if context.request_id = "request-success" then
                  Atomic.set phase.second_submission
                    (Some
                       (Bridge.Responder.resolve responder
                          (`Assoc [ ("unexpected", `Bool true) ]))))
          in
          add_worker phase worker)

let wait_until label predicate =
  let deadline = Unix.gettimeofday () +. 5.0 in
  while (not (predicate ())) && Unix.gettimeofday () < deadline do
    Unix.sleepf 0.01
  done;
  if not (predicate ()) then failwith (label ^ " timed out")

let assert_clean_destroy phase expected_bindings =
  let before_destroy = Webui_raw.Diagnostics.snapshot phase.window in
  if before_destroy.pending_calls <> 0 then
    failwith "pending bridge Call remained after Window.run";
  if before_destroy.dispatch_roots <> 0 then
    failwith "bridge dispatch root remained after Window.run";
  if before_destroy.binding_roots <> expected_bindings then
    failwith
      (Printf.sprintf "expected %d bindings before destroy but found %d"
         expected_bindings before_destroy.binding_roots);
  require (Webui_raw.Window.destroy phase.window);
  let after_destroy = Webui_raw.Diagnostics.snapshot phase.window in
  if
    after_destroy.pending_calls <> 0 || after_destroy.dispatch_roots <> 0
    || after_destroy.binding_roots <> 0
  then failwith "bridge resources remained after destroy"

let success_html =
  {html|<!doctype html><meta charset="utf-8"><title>bridge baseline</title>
<script>
(async () => {
  try {
    const success = await ocamlWebui.invoke(
      "text.analyze",
      { text: "hello typed bridge", delayMs: 50 },
      { requestId: "request-success", traceId: "trace-success" }
    );
    if (success.requestId !== "request-success" || success.traceId !== "trace-success") {
      throw new Error("success identity mismatch");
    }
    if (!success.ok || success.value.bytes !== 18 || success.value.words !== 3 ||
        success.value.observedTraceId !== "trace-success") {
      throw new Error("success payload mismatch: " + JSON.stringify(success));
    }

    let validation;
    try {
      await ocamlWebui.invoke(
        "text.analyze",
        { text: "", delayMs: 0 },
        { requestId: "request-empty", traceId: "trace-empty" }
      );
      throw new Error("empty text unexpectedly resolved");
    } catch (error) {
      validation = error;
    }
    if (validation?.requestId !== "request-empty" ||
        validation?.traceId !== "trace-empty" ||
        validation?.error?.code !== "empty_text") {
      throw new Error("validation error mismatch: " + JSON.stringify(validation));
    }

    let unknown;
    try {
      await ocamlWebui.invoke(
        "missing.command",
        null,
        { requestId: "request-unknown", traceId: "trace-unknown" }
      );
      throw new Error("unknown command unexpectedly resolved");
    } catch (error) {
      unknown = error;
    }
    if (unknown?.requestId !== "request-unknown" ||
        unknown?.traceId !== "trace-unknown" ||
        unknown?.error?.code !== "unknown_command") {
      throw new Error("unknown command mismatch: " + JSON.stringify(unknown));
    }

    let internal;
    try {
      await ocamlWebui.invoke(
        "text.analyze",
        { text: "handler error", delayMs: 0 },
        { requestId: "request-handler-error", traceId: "trace-handler-error" }
      );
      throw new Error("handler exception unexpectedly resolved");
    } catch (error) {
      internal = error;
    }
    if (internal?.requestId !== "request-handler-error" ||
        internal?.traceId !== "trace-handler-error" ||
        internal?.error?.code !== "internal_error" ||
        internal?.error?.message !== "command handler raised") {
      throw new Error("handler error mismatch: " + JSON.stringify(internal));
    }
    await __baseline_report("pass");
  } catch (error) {
    await __baseline_report("fail:" + (error?.stack || JSON.stringify(error)));
  }
})();
</script>|html}

let run_success_phase () =
  let phase = create_phase () in
  let report = Atomic.make None in
  let bridge =
    match Bridge.install phase.window ~commands:[ analyze_command phase ] with
    | Ok bridge -> bridge
    | Error (Bridge.Duplicate_command name) ->
        failwith ("duplicate command: " ^ name)
    | Error (Bridge.Raw_error error) -> fail_error error
  in
  let report_binding =
    require
      (Webui_raw.Binding.create phase.window ~name:"__baseline_report"
         (fun call ->
           Atomic.set report (Some (Webui_raw.Call.request_json call));
           ignore (Webui_raw.Call.resolve_json call "null");
           require (Webui_raw.Window.request_close phase.window)))
  in
  require
    (Webui_raw.Window.set_title phase.window
       "OCaml WebUI handwritten bridge baseline");
  require
    (Webui_raw.Window.set_size phase.window ~width:760 ~height:480 Initial);
  require (Webui_raw.Window.set_html phase.window success_html);
  let watchdog =
    Thread.create
      (fun () ->
        let deadline = Unix.gettimeofday () +. 10.0 in
        while Atomic.get report = None && Unix.gettimeofday () < deadline do
          Unix.sleepf 0.05
        done;
        if Atomic.get report = None then
          ignore (Webui_raw.Window.request_close phase.window))
      ()
  in
  require (Webui_raw.Window.run phase.window);
  Thread.join watchdog;
  join_workers phase;
  (match Atomic.get report with
  | Some {|["pass"]|} -> ()
  | Some value -> failwith ("renderer reported failure: " ^ value)
  | None -> failwith "renderer did not report bridge result");
  (match Atomic.get phase.first_submission with
  | Some `Queued -> ()
  | _ -> failwith "successful bridge response was not queued");
  (match Atomic.get phase.second_submission with
  | Some `Already_completed -> ()
  | _ -> failwith "duplicate bridge response was not rejected");
  ignore bridge;
  ignore report_binding;
  assert_clean_destroy phase 2

let cancel_html =
  {html|<!doctype html><meta charset="utf-8"><title>bridge cancel</title>
<script>
ocamlWebui.invoke(
  "text.analyze",
  { text: "close while pending", delayMs: 750 },
  { requestId: "request-cancel", traceId: "trace-cancel" }
).catch(() => {});
</script>|html}

let run_cancel_phase () =
  let phase = create_phase () in
  let closer_error = Atomic.make None in
  let bridge =
    match Bridge.install phase.window ~commands:[ analyze_command phase ] with
    | Ok bridge -> bridge
    | Error (Bridge.Duplicate_command name) ->
        failwith ("duplicate command: " ^ name)
    | Error (Bridge.Raw_error error) -> fail_error error
  in
  require (Webui_raw.Window.set_html phase.window cancel_html);
  let closer =
    Thread.create
      (fun () ->
        (try
           wait_until "bridge handler start" (fun () ->
               Atomic.get phase.handler_started);
           Unix.sleepf 0.05
         with exn -> Atomic.set closer_error (Some exn));
        match Webui_raw.Window.request_close phase.window with
        | Ok () -> ()
        | Error error ->
            Atomic.set closer_error
              (Some (Failure (Webui_raw.Error.to_string error))))
      ()
  in
  require (Webui_raw.Window.run phase.window);
  Thread.join closer;
  Option.iter raise (Atomic.get closer_error);
  join_workers phase;
  (match Atomic.get phase.first_submission with
  | Some `Already_completed -> ()
  | _ -> failwith "late bridge response was not rejected after close");
  ignore bridge;
  assert_clean_destroy phase 1

let () =
  Printexc.record_backtrace true;
  try
    run_success_phase ();
    run_cancel_phase ();
    Printf.printf
      "handwritten_bridge: passed success validation unknown handler_error duplicate cancel roots=0\n%!"
  with exn ->
    Printf.eprintf "handwritten_bridge: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
