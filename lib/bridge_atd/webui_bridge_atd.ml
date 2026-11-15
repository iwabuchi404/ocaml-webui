(** Experimental typed Command bridge using ATD-generated codecs.

    Unlike [Webui_bridge_baseline], payload decoding/encoding is driven by
    generated [of_yojson]/[to_yojson] functions rather than manual
    [List.assoc_opt]. Protocol v1 wire JSON is unchanged. *)

type context = {
  request_id : string;
  trace_id : string;
  command : string;
}

type cancellation_token = Webui_async.cancellation_token

let token_is_cancelled = Webui_async.is_cancelled
let token_cancel_reason = Webui_async.cancel_reason

module Error = struct
  type t = {
    code : string;
    message : string;
    retryable : bool;
    category : string;
    details : Yojson.Safe.t option;
  }

  let make ?(retryable = false) ?(category = "application") ?details ~code
      ~message () =
    { code; message; retryable; category; details }

  let to_yojson error =
    let fields =
      [
        ("code", `String error.code);
        ("message", `String error.message);
        ("retryable", `Bool error.retryable);
        ("category", `String error.category);
      ]
    in
    let fields =
      match error.details with
      | None -> fields
      | Some details -> fields @ [ ("details", details) ]
    in
    `Assoc fields
end

module Protocol = struct
  let version = 1

  type request = { context : context; payload : Yojson.Safe.t }

  type decode_error = {
    request_id : string option;
    trace_id : string option;
    error : Error.t;
  }

  let optional_string fields name =
    match List.assoc_opt name fields with
    | Some (`String value) when value <> "" -> Some value
    | _ -> None

  let decode_error ?request_id ?trace_id code message =
    Error
      {
        request_id;
        trace_id;
        error =
          Error.make ~category:"protocol" ~code ~message ();
      }

  let decode_object fields =
    let request_id = optional_string fields "requestId" in
    let trace_id = optional_string fields "traceId" in
    match List.assoc_opt "protocol" fields with
    | Some (`Int protocol) when protocol <> version ->
        decode_error ?request_id ?trace_id "protocol_mismatch"
          (Printf.sprintf "expected protocol %d but received %d" version
             protocol)
    | Some (`Int _) -> (
        match (request_id, trace_id, optional_string fields "command") with
        | None, _, _ ->
            decode_error ?trace_id "invalid_request"
              "requestId must be a non-empty string"
        | _, None, _ ->
            decode_error ?request_id "invalid_request"
              "traceId must be a non-empty string"
        | _, _, None ->
            decode_error ?request_id ?trace_id "invalid_request"
              "command must be a non-empty string"
        | Some request_id, Some trace_id, Some command -> (
            match List.assoc_opt "payload" fields with
            | None ->
                decode_error ~request_id ~trace_id "invalid_request"
                  "payload is required"
            | Some payload ->
                Ok { context = { request_id; trace_id; command }; payload }))
    | _ ->
        decode_error ?request_id ?trace_id "invalid_request"
          "protocol must be an integer"

  let decode_request_json json =
    match Yojson.Safe.from_string json with
    | `List [ `Assoc fields ] -> decode_object fields
    | _ ->
        decode_error "invalid_request"
          "native binding expects exactly one request envelope"
    | exception Yojson.Json_error message ->
        decode_error "invalid_json" message

  type message =
    | Invoke of request
    | Cancel of {
        request_id : string;
        trace_id : string;
        target_request_id : string;
      }

  (** Envelope-level decode. [{kind:"cancel"}] cancels the call identified by
      [targetRequestId]; a missing or ["invoke"] kind is an invoke envelope. *)
  let decode_message_json json =
    match Yojson.Safe.from_string json with
    | `List [ `Assoc fields ] -> (
        match optional_string fields "kind" with
        | Some "cancel" -> (
            match
              ( optional_string fields "requestId",
                optional_string fields "targetRequestId" )
            with
            | Some request_id, Some target_request_id ->
                let trace_id =
                  match optional_string fields "traceId" with
                  | Some trace_id -> trace_id
                  | None -> ""
                in
                Ok (Cancel { request_id; trace_id; target_request_id })
            | _ ->
                decode_error "invalid_request"
                  "cancel requires requestId and targetRequestId")
        | Some kind ->
            decode_error "invalid_request" ("unknown kind: " ^ kind)
        | None -> (
            match decode_object fields with
            | Ok request -> Ok (Invoke request)
            | Error decode_error -> Error decode_error))
    | _ ->
        decode_error "invalid_request"
          "native binding expects exactly one request envelope"
    | exception Yojson.Json_error message ->
        decode_error "invalid_json" message

  let identity_fields (context : context option) =
    match context with
    | None ->
        [ ("requestId", `Null); ("traceId", `Null); ("command", `Null) ]
    | Some context ->
        [
          ("requestId", `String context.request_id);
          ("traceId", `String context.trace_id);
          ("command", `String context.command);
        ]

  let response_json context fields =
    `Assoc
      (("protocol", `Int version) :: identity_fields context @ fields)
    |> Yojson.Safe.to_string

  let success_json context value =
    response_json (Some context) [ ("ok", `Bool true); ("value", value) ]

  let failure_json context error =
    response_json context
      [ ("ok", `Bool false); ("error", Error.to_yojson error) ]

  (** Like [failure_json] but places a raw JSON value directly into the
      [error] field. Used by typed [responder_reject] so that
      ATD-generated application errors appear at top level, matching
      the handwritten baseline wire format. *)
  let failure_json_raw context error_json =
    response_json context
      [ ("ok", `Bool false); ("error", error_json) ]
end

type ('input, 'output, 'error) codec = {
  input_of_yojson : Yojson.Safe.t -> 'input;
  output_to_yojson : 'output -> Yojson.Safe.t;
  error_to_yojson : 'error -> Yojson.Safe.t;
}

let make_codec
    ~(input_of_yojson : Yojson.Safe.t -> 'input)
    ~(output_to_yojson : 'output -> Yojson.Safe.t)
    ~(error_to_yojson : 'error -> Yojson.Safe.t)
    : ('input, 'output, 'error) codec =
  { input_of_yojson; output_to_yojson; error_to_yojson }

type ('output, 'error) responder = {
  raw_call : Webui_raw.Call.t;
  context : context;
  output_to_yojson : 'output -> Yojson.Safe.t;
  error_to_yojson : 'error -> Yojson.Safe.t;
  mark_done : unit -> unit;
}

let responder_context (r : ('output, 'error) responder) = r.context

let responder_resolve (r : ('output, 'error) responder) (value : 'output) =
  let submission =
    Webui_raw.Call.resolve_json r.raw_call
      (Protocol.success_json r.context (r.output_to_yojson value))
  in
  r.mark_done ();
  submission

let responder_reject (r : ('output, 'error) responder) (error : 'error) =
  let submission =
    Webui_raw.Call.reject_json r.raw_call
      (Protocol.failure_json_raw (Some r.context)
         (r.error_to_yojson error))
  in
  r.mark_done ();
  submission

let responder_reject_protocol (r : ('output, 'error) responder) (error : Error.t) =
  let submission =
    Webui_raw.Call.reject_json r.raw_call
      (Protocol.failure_json (Some r.context) error)
  in
  r.mark_done ();
  submission

let responder_cancel (r : ('output, 'error) responder) =
  let cancellation = Webui_raw.Call.cancel r.raw_call in
  r.mark_done ();
  cancellation

type ('input, 'output, 'error) command =
  | Command :
      {
        name : string;
        input_of_yojson : Yojson.Safe.t -> 'input;
        output_to_yojson : 'output -> Yojson.Safe.t;
        error_to_yojson : 'error -> Yojson.Safe.t;
        handler :
            context ->
            'input ->
            ('output, 'error) responder ->
            unit;
      }
      -> ('input, 'output, 'error) command
  | Async_command :
      {
        name : string;
        input_of_yojson : Yojson.Safe.t -> 'input;
        output_to_yojson : 'output -> Yojson.Safe.t;
        error_to_yojson : 'error -> Yojson.Safe.t;
        timeout_ms : int option;
        handler :
            context ->
            'input ->
            ('output, 'error) responder ->
            cancellation_token ->
            unit;
      }
      -> ('input, 'output, 'error) command

type packed_command =
  | Packed : ('input, 'output, 'error) command -> packed_command

let define
    (codec : ('input, 'output, 'error) codec)
    ~name
    (handler :
       context ->
       'input ->
       ('output, 'error) responder ->
       unit) :
    ('input, 'output, 'error) command =
  Command {
    name;
    input_of_yojson = codec.input_of_yojson;
    output_to_yojson = codec.output_to_yojson;
    error_to_yojson = codec.error_to_yojson;
    handler;
  }

let define_async
    (codec : ('input, 'output, 'error) codec)
    ~name
    ?timeout_ms
    (handler :
       context ->
       'input ->
       ('output, 'error) responder ->
       cancellation_token ->
       unit) :
    ('input, 'output, 'error) command =
  Async_command {
    name;
    input_of_yojson = codec.input_of_yojson;
    output_to_yojson = codec.output_to_yojson;
    error_to_yojson = codec.error_to_yojson;
    timeout_ms;
    handler;
  }

let pack command = Packed command

let command_name = function
  | Packed (Command c) -> c.name
  | Packed (Async_command c) -> c.name

type install_error =
  | Duplicate_command of string
  | Raw_error of Webui_raw.Error.t

type pending_entry = {
  raw_call : Webui_raw.Call.t;
  context : context;
  token : Webui_async.cancellation_token;
  completed : bool Atomic.t;
}

type t = {
  binding : Webui_raw.Binding.t;
  pending : (string, pending_entry) Hashtbl.t;
  pending_lock : Mutex.t;
}

let client_javascript =
  {js|(function () {
  let sequence = 0;
  function nextId(prefix) {
    sequence += 1;
    if (globalThis.crypto && typeof globalThis.crypto.randomUUID === "function") {
      return prefix + "-" + globalThis.crypto.randomUUID();
    }
    return prefix + "-" + Date.now().toString(36) + "-" + sequence.toString(36);
  }
  function sendCancel(requestId, traceId) {
    return globalThis.__ocaml_webui_invoke({
      protocol: 1,
      kind: "cancel",
      requestId: nextId("cancel"),
      traceId,
      targetRequestId: requestId
    });
  }
  globalThis.ocamlWebui = Object.freeze({
    invoke(command, payload, options = {}) {
      const requestId = options.requestId || nextId("request");
      const traceId = options.traceId || nextId("trace");
      return globalThis.__ocaml_webui_invoke({
        protocol: 1,
        requestId,
        traceId,
        command,
        payload
      });
    },
    invokeHandle(command, payload, options = {}) {
      const requestId = options.requestId || nextId("request");
      const traceId = options.traceId || nextId("trace");
      const inner = globalThis.__ocaml_webui_invoke({
        protocol: 1,
        requestId,
        traceId,
        command,
        payload
      });
      const cancel = function () { return sendCancel(requestId, traceId); };
      let promise;
      if (options.timeoutMs != null) {
        let timeoutId = null;
        promise = Promise.race([
          inner,
          new Promise(function (resolve, reject) {
            timeoutId = setTimeout(function () {
              sendCancel(requestId, traceId);
              reject({
                code: "timeout",
                message: "request timed out",
                retryable: true,
                category: "timeout"
              });
            }, options.timeoutMs);
          })
        ]);
        promise = promise.finally(function () { clearTimeout(timeoutId); });
      } else {
        promise = inner;
      }
      return { promise, cancel };
    }
  });
})();|js}

let build_registry commands =
  let registry = Hashtbl.create (max 1 (List.length commands)) in
  let rec add = function
    | [] -> Ok registry
    | packed :: rest ->
        let name = command_name packed in
        if Hashtbl.mem registry name then
          Error (Duplicate_command name)
        else (
          Hashtbl.add registry name packed;
          add rest)
  in
  add commands

let log_handler_exception context exn =
  `Assoc
    [
      ("event", `String "bridge_atd.handler_exception");
      ("requestId", `String context.request_id);
      ("traceId", `String context.trace_id);
      ("command", `String context.command);
      ("exception", `String (Printexc.to_string exn));
    ]
  |> Yojson.Safe.to_string |> Printf.eprintf "%s\n%!"

let log_decode_exception context exn =
  `Assoc
    [
      ("event", `String "bridge_atd.decode_exception");
      ("requestId", `String context.request_id);
      ("traceId", `String context.trace_id);
      ("command", `String context.command);
      ("exception", `String (Printexc.to_string exn));
    ]
  |> Yojson.Safe.to_string |> Printf.eprintf "%s\n%!"

let decode_input ~input_of_yojson responder request =
  try Some (input_of_yojson request.Protocol.payload)
  with exn ->
    log_decode_exception request.context exn;
    ignore
      (responder_reject_protocol responder
         (Error.make ~category:"protocol" ~code:"invalid_payload"
            ~message:"payload decode failed" ()));
    None

let install window ~commands =
  match build_registry commands with
  | Error _ as error -> error
  | Ok registry -> (
      match Webui_raw.Window.init window client_javascript with
      | Error error -> Error (Raw_error error)
      | Ok () ->
          let pending = Hashtbl.create 16 in
          let pending_lock = Mutex.create () in
          let pending_find request_id =
            Mutex.lock pending_lock;
            let entry = Hashtbl.find_opt pending request_id in
            Mutex.unlock pending_lock;
            entry
          in
          let make_entry raw_call context =
            let token =
              Webui_async.token
                ~external_check:(fun () ->
                  if Webui_raw.Call.is_cancelled raw_call then
                    Some `Window_close
                  else None)
                ()
            in
            let entry =
              {
                raw_call;
                context;
                token;
                completed = Atomic.make false;
              }
            in
            let mark_done () =
              if not (Atomic.exchange entry.completed true) then (
                Mutex.lock pending_lock;
                Hashtbl.remove pending context.request_id;
                Mutex.unlock pending_lock)
            in
            Mutex.lock pending_lock;
            Hashtbl.replace pending context.request_id entry;
            Mutex.unlock pending_lock;
            (entry, mark_done)
          in
          let internal_error code message =
            Error.make ~category:"internal" ~code ~message ()
          in
          let invoke raw_call =
            match
              Protocol.decode_message_json
                (Webui_raw.Call.request_json raw_call)
            with
            | Error decode_error ->
                let context =
                  match (decode_error.request_id, decode_error.trace_id) with
                  | Some request_id, Some trace_id ->
                      Some { request_id; trace_id; command = "unknown" }
                  | _ -> None
                in
                ignore
                  (Webui_raw.Call.reject_json raw_call
                     (Protocol.failure_json context decode_error.error))
            | Ok (Protocol.Cancel cancel) -> (
                let cancel_context =
                  {
                    request_id = cancel.request_id;
                    trace_id = cancel.trace_id;
                    command = "cancel";
                  }
                in
                let ack cancelled =
                  ignore
                    (Webui_raw.Call.resolve_json raw_call
                       (Protocol.success_json cancel_context
                          (`Assoc
                            [
                              ("cancelled", `Bool cancelled);
                              ( "targetRequestId",
                                `String cancel.target_request_id );
                            ])))
                in
                match pending_find cancel.target_request_id with
                | None -> ack false
                | Some entry ->
                    Webui_async.cancel entry.token `Js_cancel;
                    ignore
                      (Webui_raw.Call.reject_json entry.raw_call
                         (Protocol.failure_json (Some entry.context)
                            (Error.make ~category:"cancelled" ~code:"cancelled"
                               ~message:"request cancelled" ())));
                    if not (Atomic.exchange entry.completed true) then (
                      Mutex.lock pending_lock;
                      Hashtbl.remove pending cancel.target_request_id;
                      Mutex.unlock pending_lock);
                    ack true)
            | Ok (Protocol.Invoke request) -> (
                match Hashtbl.find_opt registry request.context.command with
                | None ->
                    ignore
                      (Webui_raw.Call.reject_json raw_call
                         (Protocol.failure_json (Some request.context)
                            (Error.make ~category:"protocol"
                               ~code:"unknown_command"
                               ~message:
                                 ("unknown command: " ^ request.context.command)
                               ())))
                | Some (Packed (Command c)) ->
                    let _entry, mark_done =
                      make_entry raw_call request.context
                    in
                    let responder =
                      {
                        raw_call;
                        context = request.context;
                        output_to_yojson = c.output_to_yojson;
                        error_to_yojson = c.error_to_yojson;
                        mark_done;
                      }
                    in
                    (match
                       decode_input ~input_of_yojson:c.input_of_yojson
                         responder request
                     with
                    | None -> ()
                    | Some input -> (
                        try c.handler request.context input responder
                        with exn ->
                          log_handler_exception request.context exn;
                          ignore
                            (responder_reject_protocol responder
                               (internal_error "internal_error"
                                  "command handler raised"))))
                | Some (Packed (Async_command c)) ->
                    let entry, mark_done =
                      make_entry raw_call request.context
                    in
                    let responder =
                      {
                        raw_call;
                        context = request.context;
                        output_to_yojson = c.output_to_yojson;
                        error_to_yojson = c.error_to_yojson;
                        mark_done;
                      }
                    in
                    (match
                       decode_input ~input_of_yojson:c.input_of_yojson
                         responder request
                     with
                    | None -> ()
                    | Some input ->
                        Webui_async.detach (fun () ->
                            (try
                               c.handler request.context input responder
                                 entry.token
                             with exn ->
                               log_handler_exception request.context exn;
                               ignore
                                 (responder_reject_protocol responder
                                    (internal_error "internal_error"
                                       "command handler raised")));
                            if not (Atomic.get entry.completed) then
                              ignore
                                (responder_reject_protocol responder
                                   (internal_error
                                      "handler_returned_without_response"
                                      "async handler returned without \
                                       responding")));
                        (match c.timeout_ms with
                        | None -> ()
                        | Some timeout_ms ->
                            Webui_async.detach (fun () ->
                                Webui_async.sleep_ms timeout_ms;
                                if not (Atomic.get entry.completed) then (
                                  Webui_async.cancel entry.token `Timeout;
                                  ignore
                                    (responder_reject_protocol responder
                                       (Error.make ~retryable:true
                                          ~category:"timeout" ~code:"timeout"
                                          ~message:"command timed out" ())))))))
          in
          match
            Webui_raw.Binding.create window ~name:"__ocaml_webui_invoke"
              invoke
          with
          | Ok binding -> Ok { binding; pending; pending_lock }
          | Error error -> Error (Raw_error error))

let remove bridge = Webui_raw.Binding.remove bridge.binding

let pending_count bridge =
  Mutex.lock bridge.pending_lock;
  let count = Hashtbl.length bridge.pending in
  Mutex.unlock bridge.pending_lock;
  count
