type window = Created | Running | Closing | Stopped | Destroyed

type window_event = Start_run | Request_close | Run_returned | Destroy

type call = Pending | Dispatch_queued | Responded | Cancelled | Failed

type call_event = Queue_response | Complete_response | Cancel | Fail

type error =
  | Invalid_window_transition of window * window_event
  | Invalid_call_transition of call * call_event
  | Call_already_completed of call

let transition_window state event =
  match (state, event) with
  | Created, Start_run -> Ok Running
  | Created, Destroy -> Ok Destroyed
  | Running, Request_close -> Ok Closing
  | Running, Run_returned -> Ok Stopped
  | Closing, Request_close -> Ok Closing
  | Closing, Run_returned -> Ok Stopped
  | Stopped, Destroy -> Ok Destroyed
  | Destroyed, Destroy -> Ok Destroyed
  | _ -> Error (Invalid_window_transition (state, event))

let is_call_terminal = function
  | Responded | Cancelled | Failed -> true
  | Pending | Dispatch_queued -> false

let transition_call state event =
  if is_call_terminal state then Error (Call_already_completed state)
  else
    match (state, event) with
    | Pending, Queue_response -> Ok Dispatch_queued
    | Pending, Cancel -> Ok Cancelled
    | Pending, Fail -> Ok Failed
    | Dispatch_queued, Complete_response -> Ok Responded
    | Dispatch_queued, Cancel -> Ok Cancelled
    | Dispatch_queued, Fail -> Ok Failed
    | _ -> Error (Invalid_call_transition (state, event))

let string_of_window = function
  | Created -> "created"
  | Running -> "running"
  | Closing -> "closing"
  | Stopped -> "stopped"
  | Destroyed -> "destroyed"

let string_of_window_event = function
  | Start_run -> "start_run"
  | Request_close -> "request_close"
  | Run_returned -> "run_returned"
  | Destroy -> "destroy"

let string_of_call = function
  | Pending -> "pending"
  | Dispatch_queued -> "dispatch_queued"
  | Responded -> "responded"
  | Cancelled -> "cancelled"
  | Failed -> "failed"

let string_of_call_event = function
  | Queue_response -> "queue_response"
  | Complete_response -> "complete_response"
  | Cancel -> "cancel"
  | Fail -> "fail"

let string_of_error = function
  | Invalid_window_transition (state, event) ->
      Printf.sprintf "invalid window transition: %s + %s"
        (string_of_window state) (string_of_window_event event)
  | Invalid_call_transition (state, event) ->
      Printf.sprintf "invalid call transition: %s + %s"
        (string_of_call state) (string_of_call_event event)
  | Call_already_completed state ->
      Printf.sprintf "call already completed: %s" (string_of_call state)
