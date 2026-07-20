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
end

module Responder = struct
  type t = { raw_call : Webui_raw.Call.t; context : context }

  let context responder = responder.context

  let resolve responder value =
    Webui_raw.Call.resolve_json responder.raw_call
      (Protocol.success_json responder.context value)

  let reject responder error =
    Webui_raw.Call.reject_json responder.raw_call
      (Protocol.failure_json (Some responder.context) error)

  let cancel responder = Webui_raw.Call.cancel responder.raw_call
end

type handler = context -> Yojson.Safe.t -> Responder.t -> unit
type command = { name : string; handler : handler }

let command ~name handler =
  if name = "" then invalid_arg "Command name must not be empty";
  { name; handler }

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
    | command :: rest ->
        if Hashtbl.mem registry command.name then
          Error (Duplicate_command command.name)
        else (
          Hashtbl.add registry command.name command.handler;
          add rest)
  in
  add commands

let log_handler_exception context exn =
  `Assoc
    [
      ("event", `String "bridge.handler_exception");
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
                | Some handler ->
                    let responder =
                      Responder.{ raw_call; context = request.context }
                    in
                    (try handler request.context request.payload responder
                     with exn ->
                       log_handler_exception request.context exn;
                       ignore
                         (Responder.reject responder
                            (Error.make ~category:"internal"
                               ~code:"internal_error"
                               ~message:"command handler raised" ()))))
          in
          match
            Webui_raw.Binding.create window ~name:"__ocaml_webui_invoke"
              invoke
          with
          | Ok binding -> Ok { binding }
          | Error error -> Error (Raw_error error))

let remove bridge = Webui_raw.Binding.remove bridge.binding
