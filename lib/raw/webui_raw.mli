module Error : sig
  type code =
    | Missing_dependency
    | Cancelled
    | Invalid_state
    | Invalid_argument
    | Duplicate
    | Not_found
    | Unspecified
    | Unknown of int

  type operation =
    | Create
    | Run
    | Request_close
    | Destroy
    | Set_title
    | Set_size
    | Navigate
    | Set_html
    | Init
    | Eval
    | Bind
    | Unbind
    | Dispatch
    | Respond

  type t = { operation : operation; code : code; message : string }

  val make : operation -> code -> string -> t
  val code_to_string : code -> string
  val operation_to_string : operation -> string
  val to_string : t -> string
end

module Window : sig
  type t

  type state = Webui_raw_state.window =
    | Created
    | Running
    | Closing
    | Stopped
    | Destroyed

  type size_hint = Initial | Minimum | Maximum | Fixed

  type config = { debug : bool }

  val create : config -> (t, Error.t) result
  val state : t -> state

  (** Blocks on the owner thread until the native event loop stops. The OCaml
      runtime is released while the native loop is running. *)
  val run : t -> (unit, Error.t) result

  (** Thread-safe close request. This is the only Window operation, apart from
      future dispatch/Call operations, that may be called from a worker Domain. *)
  val request_close : t -> (unit, Error.t) result

  (** Explicitly destroys the native WebView. Must run on the owner thread in
      [Created] or [Stopped]. Calling it again after success is harmless. *)
  val destroy : t -> (unit, Error.t) result

  val set_title : t -> string -> (unit, Error.t) result

  val set_size :
    t -> width:int -> height:int -> size_hint -> (unit, Error.t) result

  val navigate : t -> string -> (unit, Error.t) result
  val set_html : t -> string -> (unit, Error.t) result
  val init : t -> string -> (unit, Error.t) result
  val eval : t -> string -> (unit, Error.t) result

  (** Enqueues [callback] for execution on the owner/UI thread. It may be
      called from a worker Domain while the window is [Running]. Exceptions
      are caught at the native boundary and recorded in [Diagnostics]. *)
  val dispatch : t -> (unit -> unit) -> (unit, Error.t) result
end

module Call : sig
  type t

  type state = Webui_raw_state.call =
    | Pending
    | Dispatch_queued
    | Responded
    | Cancelled
    | Failed

  type completion = [ `Sent | `Already_completed | `Window_closing ]

  val request_json : t -> string
  val resolve_json : t -> string -> completion
  val reject_json : t -> string -> completion
  val cancel : t -> completion
end

module Binding : sig
  type t

  (** Creates a binding on the owner/UI thread. The handler receives a Call
      whose request JSON has already been copied into OCaml-owned memory. *)
  val create :
    Window.t -> name:string -> (Call.t -> unit) -> (t, Error.t) result

  (** Removes a binding on the owner/UI thread. Reentrant removal from that
      binding's active handler is rejected; enqueue the removal with
      [Window.dispatch] so it runs after the handler returns. Every Call for
      the binding must also be completed or cancelled before removal. *)
  val remove : t -> (unit, Error.t) result
end

module Diagnostics : sig
  type snapshot = {
    window_state : Window.state;
    binding_roots : int;
    dispatch_roots : int;
    pending_calls : int;
    queued_dispatches : int;
    dispatch_enqueued : int;
    dispatch_executed : int;
    dispatch_cancelled : int;
    callback_exceptions : int;
  }

  val snapshot : Window.t -> snapshot
end

(** Unstable helpers for state-machine tests. Application code must not use
    this module. *)
module For_testing : sig
  include module type of Webui_raw_state

  (** Forces the next native dispatch scheduling attempt to fail. Tests use
      this to verify queue/root rollback; application code must not call it. *)
  val fail_next_dispatch : Window.t -> unit
end

val version : unit -> string
