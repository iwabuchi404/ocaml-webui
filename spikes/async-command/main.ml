module Bridge = Webui_bridge_atd
module Schema = Command_schema.Text_analyze

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

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

let text_analyze_codec =
  Bridge.make_codec
    ~input_of_yojson:Schema.text_analyze_request_of_yojson
    ~output_to_yojson:Schema.yojson_of_text_analyze_result
    ~error_to_yojson:Schema.yojson_of_text_analyze_error

type phase = {
  window : Webui_raw.Window.t;
  handler_started : bool Atomic.t;
  reasons : (string, Webui_async.cancel_reason option) Hashtbl.t;
  reasons_lock : Mutex.t;
  submissions : (string, Webui_raw.Call.response_submission) Hashtbl.t;
  submissions_lock : Mutex.t;
}

let create_phase () =
  {
    window = require (Webui_raw.Window.create { debug = false });
    handler_started = Atomic.make false;
    reasons = Hashtbl.create 8;
    reasons_lock = Mutex.create ();
    submissions = Hashtbl.create 8;
    submissions_lock = Mutex.create ();
  }

let record_reason phase request_id reason =
  Mutex.protect phase.reasons_lock (fun () ->
      Hashtbl.replace phase.reasons request_id reason)

let reason_observed phase request_id expected =
  match
    Mutex.protect phase.reasons_lock (fun () ->
        Hashtbl.find_opt phase.reasons request_id)
  with
  | Some (Some reason) -> reason = expected
  | _ -> false

let record_submission phase request_id submission =
  Mutex.protect phase.submissions_lock (fun () ->
      Hashtbl.replace phase.submissions request_id submission)

let find_submission phase request_id =
  Mutex.protect phase.submissions_lock (fun () ->
      Hashtbl.find_opt phase.submissions request_id)

(* Async handler: sleeps in 10ms steps, polling the cooperative token.
   On cancellation it records the observed reason and returns without
   responding — the request is already rejected by the cancel/timeout path,
   and the bridge's post-return check degrades to Already_completed. *)
let analyze_command phase ~name ?timeout_ms () =
  Bridge.define_async text_analyze_codec ~name ?timeout_ms
    (fun context request responder token ->
      Atomic.set phase.handler_started true;
      let delay_ms = max 0 request.Schema.delay_ms in
      let rec loop elapsed =
        if Webui_async.is_cancelled token then
          record_reason phase context.Bridge.request_id
            (Webui_async.cancel_reason token)
        else if elapsed >= delay_ms then
          record_submission phase context.request_id
            (Bridge.responder_resolve responder
               Schema.
                 {
                   bytes = String.length request.text;
                   words = word_count request.text;
                   observed_trace_id = context.trace_id;
                 })
        else (
          Webui_async.sleep_ms 10;
          loop (elapsed + 10))
      in
      loop 0)

let wait_until label predicate =
  let deadline = Unix.gettimeofday () +. 10.0 in
  while (not (predicate ())) && Unix.gettimeofday () < deadline do
    Unix.sleepf 0.01
  done;
  if not (predicate ()) then failwith (label ^ " timed out")

let install_bridge phase commands =
  match Bridge.install phase.window ~commands with
  | Ok bridge -> bridge
  | Error (Bridge.Duplicate_command name) ->
      failwith ("duplicate command: " ^ name)
  | Error (Bridge.Raw_error error) -> fail_error error

let assert_clean_destroy phase expected_bindings =
  let before_destroy = Webui_raw.Diagnostics.snapshot phase.window in
  if before_destroy.pending_calls <> 0 then
    failwith "pending Call remained after Window.run";
  if before_destroy.dispatch_roots <> 0 then
    failwith "dispatch root remained after Window.run";
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

let interactive_html =
  Printf.sprintf
    {html|<!doctype html><meta charset="utf-8"><title>async command</title>
<script>
%s
</script>|html}
    Bundle_embed.bundle

let run_interactive_phase () =
  let phase = create_phase () in
  let report = Atomic.make None in
  let bridge =
    install_bridge phase
      [
        Bridge.pack (analyze_command phase ~name:"async.analyze" ());
        Bridge.pack
          (analyze_command phase ~name:"async.slow" ~timeout_ms:400 ());
      ]
  in
  let report_binding =
    require
      (Webui_raw.Binding.create phase.window ~name:"__async_report"
         (fun call ->
           Atomic.set report (Some (Webui_raw.Call.request_json call));
           ignore (Webui_raw.Call.resolve_json call "null");
           require (Webui_raw.Window.request_close phase.window)))
  in
  require (Webui_raw.Window.set_title phase.window "OCaml WebUI async command");
  require
    (Webui_raw.Window.set_size phase.window ~width:760 ~height:480 Initial);
  require (Webui_raw.Window.set_html phase.window interactive_html);
  let watchdog =
    Thread.create
      (fun () ->
        let deadline = Unix.gettimeofday () +. 15.0 in
        while Atomic.get report = None && Unix.gettimeofday () < deadline do
          Unix.sleepf 0.05
        done;
        if Atomic.get report = None then
          ignore (Webui_raw.Window.request_close phase.window))
      ()
  in
  require (Webui_raw.Window.run phase.window);
  Thread.join watchdog;
  (match Atomic.get report with
  | Some {|["pass"]|} -> ()
  | Some value -> failwith ("renderer reported failure: " ^ value)
  | None -> failwith "renderer did not report async probe result");
  (* Workers are detached; poll until they observe their cancel reasons. *)
  wait_until "cancel reasons"
    (fun () ->
      reason_observed phase "request-js-cancel" `Js_cancel
      && reason_observed phase "request-ocaml-timeout" `Timeout
      && reason_observed phase "request-js-timeout" `Js_cancel);
  (match find_submission phase "request-async-resolve" with
  | Some `Queued -> ()
  | _ -> failwith "async resolve submission was not queued");
  wait_until "pending drained" (fun () -> Bridge.pending_count bridge = 0);
  ignore report_binding;
  assert_clean_destroy phase 2

let close_html =
  {html|<!doctype html><meta charset="utf-8"><title>async close</title>
<script>
ocamlWebui.invoke(
  "async.analyze",
  { text: "close while pending", delayMs: 2000 },
  { requestId: "request-close", traceId: "trace-close" }
).catch(() => {});
</script>|html}

let run_close_phase () =
  let phase = create_phase () in
  let closer_error = Atomic.make None in
  let bridge =
    install_bridge phase
      [ Bridge.pack (analyze_command phase ~name:"async.analyze" ()) ]
  in
  require (Webui_raw.Window.set_html phase.window close_html);
  let closer =
    Thread.create
      (fun () ->
        (try
           wait_until "async handler start" (fun () ->
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
  (* The detached worker observes Window_close via the token's
     external_check, records it, and returns; the post-return auto-reject
     is discarded by the one-shot Call and drains the pending entry. *)
  wait_until "window close reason" (fun () ->
      reason_observed phase "request-close" `Window_close);
  wait_until "pending drained" (fun () -> Bridge.pending_count bridge = 0);
  assert_clean_destroy phase 1

let () =
  Printexc.record_backtrace true;
  try
    run_interactive_phase ();
    run_close_phase ();
    Printf.printf
      "async_bridge: passed resolve late-cancel js-cancel ocaml-timeout \
       js-timeout window-close pending=0 roots=0\n\
       %!"
  with exn ->
    Printf.eprintf "async_bridge: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
