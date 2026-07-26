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
  Bridge.define text_analyze_codec ~name:"text.analyze"
    (fun context request responder ->
      if context.request_id = "request-handler-error" then
        failwith "intentional ATD bridge handler failure"
      else if context.request_id = "request-handler-exit" then
        raise Exit
      else begin
        if request.delay_ms < 0 || request.delay_ms > 2_000 then
          Atomic.set phase.first_submission
            (Some
               (Bridge.responder_reject responder
                  (Schema.
                    { code = Invalid_delay;
                      message = "delayMs must be between 0 and 2000";
                      retryable = false;
                      category = "validation"
                    })))
        else begin
          Atomic.set phase.handler_started true;
          let worker =
            Domain.spawn (fun () ->
                Unix.sleepf (float request.delay_ms /. 1_000.);
                let first =
                  if String.trim request.text = "" then
                    Bridge.responder_reject responder
                      (Schema.
                        { code = Empty_text;
                          message = "text must not be empty";
                          retryable = false;
                          category = "validation"
                        })
                  else
                    Bridge.responder_resolve responder
                      (Schema.
                        { bytes = String.length request.text;
                          words = word_count request.text;
                          observed_trace_id = context.trace_id
                        })
                in
                Atomic.set phase.first_submission (Some first);
                if context.request_id = "request-success" then
                  Atomic.set phase.second_submission
                    (Some
                       (Bridge.responder_resolve responder
                          (Schema.
                            { bytes = 0;
                              words = 0;
                              observed_trace_id = "duplicate"
                            }))))
          in
          add_worker phase worker
        end
      end)

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
  Printf.sprintf
    {html|<!doctype html><meta charset="utf-8"><title>ATD bridge</title>
<script>
%s
</script>|html}
    Bundle_embed.bundle

let run_success_phase () =
  let phase = create_phase () in
  let report = Atomic.make None in
  let bridge =
    match
      Bridge.install phase.window
        ~commands:[ Bridge.pack (analyze_command phase) ]
    with
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
       "OCaml WebUI ATD typed bridge");
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
  {html|<!doctype html><meta charset="utf-8"><title>ATD bridge cancel</title>
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
    match
      Bridge.install phase.window
        ~commands:[ Bridge.pack (analyze_command phase) ]
    with
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
      "atd_bridge: passed success validation unknown handler_error duplicate cancel malformed roots=0\n%!"
  with exn ->
    Printf.eprintf "atd_bridge: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
