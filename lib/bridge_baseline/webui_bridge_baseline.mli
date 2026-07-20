(** Deliberately handwritten Command bridge used as the comparison baseline
    for the later ATD-generated bridge. This is not a frozen production API. *)

type context = {
  request_id : string;
  trace_id : string;
  command : string;
}

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
  val success_json : context -> Yojson.Safe.t -> string
  val failure_json : context option -> Error.t -> string
end

module Responder : sig
  type t

  val context : t -> context
  val resolve : t -> Yojson.Safe.t -> Webui_raw.Call.response_submission
  val reject : t -> Error.t -> Webui_raw.Call.response_submission
  val cancel : t -> Webui_raw.Call.cancellation
end

type handler = context -> Yojson.Safe.t -> Responder.t -> unit
type command

val command : name:string -> handler -> command

type install_error =
  | Duplicate_command of string
  | Raw_error of Webui_raw.Error.t

type t

(** Installs one low-level binding named [__ocaml_webui_invoke] and injects the
    handwritten [globalThis.ocamlWebui.invoke] JavaScript client. Command
    handlers must respond exactly once through [Responder]. *)
val install :
  Webui_raw.Window.t -> commands:command list -> (t, install_error) result

val remove : t -> (unit, Webui_raw.Error.t) result
