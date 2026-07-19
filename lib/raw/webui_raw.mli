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

  (** Creates a Window, passes it to [callback], and destroys it on the owner
      thread when [callback] returns or raises. Callback exceptions are
      re-raised after a best-effort destroy. *)
  val with_window : config -> (t -> 'a) -> ('a, Error.t) result

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

  type response_submission =
    [ `Queued
    | `Already_completed
    | `Window_closing
    | `Enqueue_failed of Error.t ]

  type cancellation = [ `Cancelled | `Already_completed ]

  val request_json : t -> string
  (* [result_json] must contain valid JSON. [`Queued] means that the response
     was accepted for owner-thread delivery; it does not guarantee that the
     native engine ultimately delivered it to JavaScript. *)
  val resolve_json : t -> string -> response_submission
  val reject_json : t -> string -> response_submission
  val cancel : t -> cancellation
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
    response_failures : int;
  }

  val snapshot : Window.t -> snapshot

  (** Number of Window values finalized without an explicit successful
      [Window.destroy] in this process. Native cleanup is intentionally not
      attempted from the GC finalizer. *)
  val leaked_windows : unit -> int
end

(** Unstable helpers for state-machine tests. Application code must not use
    this module. *)
module For_testing : sig
  include module type of Webui_raw_state

  (** Forces the next native dispatch scheduling attempt to fail. Tests use
      this to verify queue/root rollback; application code must not call it. *)
  val fail_next_dispatch : Window.t -> unit

  (** Schedules an immediate native loop exit and makes the next [Window.run]
      return an injected native error after normal cleanup. *)
  val fail_next_run : Window.t -> unit

  (** Makes the next close scheduling attempt fail before native dispatch. *)
  val fail_next_close_dispatch : Window.t -> unit

  (** Makes the next owner-thread native response fail. *)
  val fail_next_response : Window.t -> unit

  (** Exposes the one-shot state for failure-path assertions. *)
  val call_state : Call.t -> call

  module Win32 : sig
    (** Posts a real [WM_CLOSE] to the native HWND. This is a platform-specific
        verification hook and is not an application close API. *)
    val post_wm_close : Window.t -> (unit, Error.t) result
    val current_thread_id : unit -> int
  end
end

val version : unit -> string
