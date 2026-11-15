(** Experimental typed Command bridge using ATD-generated codecs.

    This is the ATD-based counterpart to [Webui_bridge_baseline]. Payload
    types and JSON codecs are supplied by ATD-generated modules, eliminating
    handwritten [List.assoc_opt] decoding. Protocol v1 wire JSON is unchanged. *)

type context = {
  request_id : string;
  trace_id : string;
  command : string;
}

(** Cooperative cancellation token passed to async Command handlers. Check
    {!token_is_cancelled} at handler checkpoints; nothing forcibly interrupts
    running work. Reasons: [`Js_cancel] (cancel message from JS), [`Timeout]
    (per-command watchdog), [`Window_close] (native cancel propagation). *)
type cancellation_token = Webui_async.cancellation_token

val token_is_cancelled : cancellation_token -> bool
val token_cancel_reason :
  cancellation_token -> Webui_async.cancel_reason option

module Error : sig
  type t = {
    code : string;
    message : string;
    retryable : bool;
    category : string;
    details : Yojson.Safe.t option;
  }

  val make :
    ?retryable:bool ->
    ?category:string ->
    ?details:Yojson.Safe.t ->
    code:string ->
    message:string ->
    unit ->
    t
end

module Protocol : sig
  val version : int

  type request = { context : context; payload : Yojson.Safe.t }

  type decode_error = {
    request_id : string option;
    trace_id : string option;
    error : Error.t;
  }

  val decode_request_json : string -> (request, decode_error) result

  (** Envelope-level decode. A [{kind:"cancel"}] envelope cancels the call
      identified by [targetRequestId]; a missing or absent [kind] is a normal
      invoke envelope. *)
  type message =
    | Invoke of request
    | Cancel of {
        request_id : string;
        trace_id : string;
        target_request_id : string;
      }

  val decode_message_json : string -> (message, decode_error) result
  val success_json : context -> Yojson.Safe.t -> string
  val failure_json : context option -> Error.t -> string
  val failure_json_raw : context option -> Yojson.Safe.t -> string
end

(** Codec record linking ATD-generated types to the bridge. *)
type ('input, 'output, 'error) codec = {
  input_of_yojson : Yojson.Safe.t -> 'input;
  output_to_yojson : 'output -> Yojson.Safe.t;
  error_to_yojson : 'error -> Yojson.Safe.t;
}

val make_codec :
  input_of_yojson:(Yojson.Safe.t -> 'input) ->
  output_to_yojson:('output -> Yojson.Safe.t) ->
  error_to_yojson:('error -> Yojson.Safe.t) ->
  ('input, 'output, 'error) codec

(** Typed responder for a specific Command. [responder_resolve] and
    [responder_reject] pass through the ATD-generated encoders so handlers
    never construct JSON manually. *)
type ('output, 'error) responder

val responder_context : ('output, 'error) responder -> context
val responder_resolve :
  ('output, 'error) responder -> 'output -> Webui_raw.Call.response_submission
val responder_reject :
  ('output, 'error) responder -> 'error -> Webui_raw.Call.response_submission
val responder_cancel : ('output, 'error) responder -> Webui_raw.Call.cancellation

(** A typed Command carrying its codec and handler. *)
type ('input, 'output, 'error) command

(** Existential packaging so different Command types can share a registry. *)
type packed_command

val define :
  ('input, 'output, 'error) codec ->
  name:string ->
  (context ->
   'input ->
   ('output, 'error) responder ->
   unit) ->
  ('input, 'output, 'error) command

(** Like {!define} but the handler runs on a spawned worker domain, keeping
    the UI thread free. The handler receives a {!cancellation_token} to poll
    at its own checkpoints.

    - If the handler returns without a responder call, the request is rejected
      with [internal_error / handler_returned_without_response].
    - [~timeout_ms] rejects the call with [timeout] (category ["timeout"],
      retryable) when still pending after the deadline; the worker keeps
      running but its late response is discarded by the one-shot Call.
    - A JS [cancel] message rejects with [cancelled] (category ["cancelled"]). *)
val define_async :
  ('input, 'output, 'error) codec ->
  name:string ->
  ?timeout_ms:int ->
  (context ->
   'input ->
   ('output, 'error) responder ->
   cancellation_token ->
   unit) ->
  ('input, 'output, 'error) command

val pack : ('input, 'output, 'error) command -> packed_command
val command_name : packed_command -> string

type install_error =
  | Duplicate_command of string
  | Raw_error of Webui_raw.Error.t

type t

val install :
  ?trace:Webui_trace.sink ->
  Webui_raw.Window.t ->
  commands:packed_command list ->
  (t, install_error) result
(** [?trace] receives flat lifecycle events keyed by traceId/requestId.
    When omitted, events are not constructed (zero overhead). Emitted
    names: [invoke_received], [invoke_decode_failed], [handler_started]
    (async only), [handler_completed] (outcome: returned /
    returned_without_response / exception), [handler_exception],
    [response_submitted] (outcome + submission + durationMs),
    [request_cancelled] (targetRequestId + cancelled), [request_timeout]
    (timeoutMs). *)

val remove : t -> (unit, Webui_raw.Error.t) result

(** Number of calls currently tracked in the pending registry. Useful for
    leak checks: after all in-flight commands complete it returns to 0. *)
val pending_count : t -> int
