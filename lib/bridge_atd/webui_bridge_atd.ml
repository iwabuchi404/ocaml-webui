(** Experimental typed Command bridge using ATD-generated codecs.

    Unlike [Webui_bridge_baseline], payload decoding/encoding is driven by
    generated [of_yojson]/[to_yojson] functions rather than manual
    [List.assoc_opt]. Protocol v1 wire JSON is unchanged. *)

type context = {
  request_id : string;
  trace_id : string;
  command : string;
}

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
}

let responder_context (r : ('output, 'error) responder) = r.context

let responder_resolve (r : ('output, 'error) responder) (value : 'output) =
  Webui_raw.Call.resolve_json r.raw_call
    (Protocol.success_json r.context (r.output_to_yojson value))

let responder_reject (r : ('output, 'error) responder) (error : 'error) =
  Webui_raw.Call.reject_json r.raw_call
    (Protocol.failure_json_raw (Some r.context)
       (r.error_to_yojson error))

let responder_reject_protocol (r : ('output, 'error) responder) (error : Error.t) =
  Webui_raw.Call.reject_json r.raw_call
    (Protocol.failure_json (Some r.context) error)

let responder_cancel (r : ('output, 'error) responder) =
  Webui_raw.Call.cancel r.raw_call

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

let pack command = Packed command

let command_name (Packed (Command c)) = c.name

type install_error =
  | Duplicate_command of string
  | Raw_error of Webui_raw.Error.t

type t = { binding : Webui_raw.Binding.t }

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

let install window ~commands =
  match build_registry commands with
  | Error _ as error -> error
  | Ok registry -> (
      match Webui_raw.Window.init window client_javascript with
      | Error error -> Error (Raw_error error)
      | Ok () ->
          let invoke raw_call =
            match
              Protocol.decode_request_json
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
            | Ok request -> (
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
                    let responder =
                      {
                        raw_call;
                        context = request.context;
                        output_to_yojson = c.output_to_yojson;
                        error_to_yojson = c.error_to_yojson;
                      }
                    in
                    let decode_ok = ref true in
                    (try
                       let input =
                         try c.input_of_yojson request.payload
                         with exn ->
                           log_decode_exception request.context exn;
                           ignore
                             (responder_reject_protocol responder
                                (Error.make ~category:"protocol"
                                   ~code:"invalid_payload"
                                   ~message:"payload decode failed" ()));
                           decode_ok := false;
                           raise Exit
                       in
                       c.handler request.context input responder
                     with
                     | Exit when not !decode_ok -> ()
                     | exn ->
                       if !decode_ok then begin
                         log_handler_exception request.context exn;
                         ignore
                           (responder_reject_protocol responder
                              (Error.make ~category:"internal"
                                 ~code:"internal_error"
                                 ~message:"command handler raised" ()))
                       end))
          in
          match
            Webui_raw.Binding.create window ~name:"__ocaml_webui_invoke"
              invoke
          with
          | Ok binding -> Ok { binding }
          | Error error -> Error (Raw_error error))

let remove bridge = Webui_raw.Binding.remove bridge.binding
