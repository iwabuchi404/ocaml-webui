module Error = struct
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

  let make operation code message = { operation; code; message }

  let code_to_string = function
    | Missing_dependency -> "missing_dependency"
    | Cancelled -> "cancelled"
    | Invalid_state -> "invalid_state"
    | Invalid_argument -> "invalid_argument"
    | Duplicate -> "duplicate"
    | Not_found -> "not_found"
    | Unspecified -> "unspecified"
    | Unknown code -> Printf.sprintf "unknown(%d)" code

  let operation_to_string = function
    | Create -> "create"
    | Run -> "run"
    | Request_close -> "request_close"
    | Destroy -> "destroy"
    | Set_title -> "set_title"
    | Set_size -> "set_size"
    | Navigate -> "navigate"
    | Set_html -> "set_html"
    | Init -> "init"
    | Eval -> "eval"
    | Bind -> "bind"
    | Unbind -> "unbind"
    | Dispatch -> "dispatch"
    | Respond -> "respond"

  let to_string error =
    Printf.sprintf "%s: %s: %s"
      (operation_to_string error.operation)
      (code_to_string error.code) error.message
end

let code_of_native = function
  | -5 -> Error.Missing_dependency
  | -4 -> Error.Cancelled
  | -3 -> Error.Invalid_state
  | -2 -> Error.Invalid_argument
  | -1 -> Error.Unspecified
  | 1 -> Error.Duplicate
  | 2 -> Error.Not_found
  | code -> Error.Unknown code

let of_native_result operation = function
  | None -> Ok ()
  | Some (code, message) ->
      Error (Error.make operation (code_of_native code) message)

module Window = struct
  type t = Webui_raw_native.window

  type state = Webui_raw_state.window =
    | Created
    | Running
    | Closing
    | Stopped
    | Destroyed

  type size_hint = Initial | Minimum | Maximum | Fixed

  type config = { debug : bool }

  let state window =
    match Webui_raw_native.state window with
    | 0 -> Created
    | 1 -> Running
    | 2 -> Closing
    | 3 -> Stopped
    | 4 -> Destroyed
    | state -> failwith (Printf.sprintf "unknown native window state: %d" state)

  let create config =
    match Webui_raw_native.create config.debug with
    | Created window -> Ok window
    | Create_error (code, message) ->
        Error (Error.make Error.Create (code_of_native code) message)

  let run window = of_native_result Error.Run (Webui_raw_native.run window)

  let request_close window =
    of_native_result Error.Request_close
      (Webui_raw_native.request_close window)

  let destroy window =
    of_native_result Error.Destroy (Webui_raw_native.destroy window)

  let with_window config callback =
    match create config with
    | Error _ as error -> error
    | Ok window -> (
        match callback window with
        | value -> (
            match destroy window with
            | Ok () -> Ok value
            | Error error -> Error error)
        | exception exn ->
            let backtrace = Printexc.get_raw_backtrace () in
            ignore (destroy window);
            Printexc.raise_with_backtrace exn backtrace)

  let set_title window title =
    of_native_result Error.Set_title
      (Webui_raw_native.set_title window title)

  let int_of_size_hint = function
    | Initial -> 0
    | Minimum -> 1
    | Maximum -> 2
    | Fixed -> 3

  let set_size window ~width ~height hint =
    of_native_result Error.Set_size
      (Webui_raw_native.set_size window width height (int_of_size_hint hint))

  let navigate window url =
    of_native_result Error.Navigate (Webui_raw_native.navigate window url)

  let set_html window html =
    of_native_result Error.Set_html (Webui_raw_native.set_html window html)

  let init window js =
    of_native_result Error.Init (Webui_raw_native.init window js)

  let eval window js =
    of_native_result Error.Eval (Webui_raw_native.eval window js)

  let dispatch window callback =
    of_native_result Error.Dispatch
      (Webui_raw_native.dispatch window callback ignore)
end

module Call = struct
  type state = Webui_raw_state.call =
    | Pending
    | Dispatch_queued
    | Responded
    | Cancelled
    | Failed

  type t = {
    window : Window.t;
    id : string;
    request_json : string;
    state : state Atomic.t;
  }

  type response_submission =
    [ `Queued
    | `Already_completed
    | `Window_closing
    | `Enqueue_failed of Error.t ]

  type cancellation = [ `Cancelled | `Already_completed ]

  let finish call = Webui_raw_native.finish_call call.window call.id

  let rec mark_cancelled call =
    match Atomic.get call.state with
    | (Pending | Dispatch_queued) as state ->
        if Atomic.compare_and_set call.state state Cancelled then (
          finish call;
          true)
        else mark_cancelled call
    | Responded | Cancelled | Failed -> false

  let create window binding_name id request_json =
    let call = { window; id; request_json; state = Atomic.make Pending } in
    match
      Webui_raw_native.register_call window binding_name id (fun () ->
          ignore (mark_cancelled call))
    with
    | None -> Ok call
    | Some (code, message) ->
        Atomic.set call.state Failed;
        Error (Error.make Error.Bind (code_of_native code) message)

  let request_json call = call.request_json
  let state call = Atomic.get call.state

  let respond call status result_json =
    if not (Atomic.compare_and_set call.state Pending Dispatch_queued) then
      `Already_completed
    else
      let execute () =
        if Atomic.compare_and_set call.state Dispatch_queued Responded then (
          (match
             Webui_raw_native.respond call.window call.id status result_json
           with
          | None -> ()
          | Some _ -> Atomic.set call.state Failed);
          finish call)
        else finish call
      in
      let cancel () = ignore (mark_cancelled call) in
      match Webui_raw_native.dispatch call.window execute cancel with
      | None -> `Queued
      | Some (code, message) ->
          if Atomic.compare_and_set call.state Dispatch_queued Failed then
            finish call;
          let error =
            Error.make Error.Dispatch (code_of_native code) message
          in
          if error.code = Error.Invalid_state then `Window_closing
          else `Enqueue_failed error

  let resolve_json call result_json = respond call 0 result_json
  let reject_json call result_json = respond call 1 result_json

  let cancel call =
    if mark_cancelled call then `Cancelled else `Already_completed
end

module Binding = struct
  type t = {
    window : Window.t;
    name : string;
    token : int;
    mutable removed : bool;
  }

  let create window ~name handler =
    let native_handler id request_json =
      match Call.create window name id request_json with
      | Error error -> failwith (Error.to_string error)
      | Ok call -> (
          try handler call
          with _ ->
            Webui_raw_native.record_callback_exception window;
            ignore
              (Call.reject_json call
                 "{\"code\":\"binding_callback_raised\"}"))
    in
    match Webui_raw_native.bind window name native_handler with
    | Webui_raw_native.Bound token ->
        Ok { window; name; token; removed = false }
    | Webui_raw_native.Bind_error (code, message) ->
        Error (Error.make Error.Bind (code_of_native code) message)

  let remove binding =
    if binding.removed then Ok ()
    else
      match Webui_raw_native.unbind binding.window binding.name binding.token with
      | None ->
          binding.removed <- true;
          Ok ()
      | Some (code, message) ->
          Error (Error.make Error.Unbind (code_of_native code) message)
end

module Diagnostics = struct
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

  let snapshot window =
    let ( window_state,
          binding_roots,
          dispatch_roots,
          pending_calls,
          queued_dispatches,
          dispatch_enqueued,
          dispatch_executed,
          dispatch_cancelled,
          callback_exceptions,
          response_failures ) =
      Webui_raw_native.diagnostics window
    in
    let window_state =
      match window_state with
      | 0 -> Window.Created
      | 1 -> Window.Running
      | 2 -> Window.Closing
      | 3 -> Window.Stopped
      | 4 -> Window.Destroyed
      | state ->
          failwith (Printf.sprintf "unknown native window state: %d" state)
    in
    {
      window_state;
      binding_roots;
      dispatch_roots;
      pending_calls;
      queued_dispatches;
      dispatch_enqueued;
      dispatch_executed;
      dispatch_cancelled;
      callback_exceptions;
      response_failures;
    }

  let leaked_windows = Webui_raw_native.leaked_windows
end

module For_testing = struct
  include Webui_raw_state

  let fail_next_dispatch = Webui_raw_native.fail_next_dispatch
  let fail_next_run = Webui_raw_native.fail_next_run
  let fail_next_close_dispatch = Webui_raw_native.fail_next_close_dispatch
  let fail_next_response = Webui_raw_native.fail_next_response
  let call_state = Call.state

  module Win32 = struct
    let post_wm_close window =
      of_native_result Error.Request_close
        (Webui_raw_native.post_wm_close window)

    let current_thread_id = Webui_raw_native.current_thread_id
  end
end

let version = Webui_raw_native.version
