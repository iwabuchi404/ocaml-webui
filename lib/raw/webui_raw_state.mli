type window = Created | Running | Closing | Stopped | Destroyed

type window_event = Start_run | Request_close | Run_returned | Destroy

type call = Pending | Dispatch_queued | Responded | Cancelled | Failed

type call_event = Queue_response | Complete_response | Cancel | Fail

type error =
  | Invalid_window_transition of window * window_event
  | Invalid_call_transition of call * call_event
  | Call_already_completed of call

val transition_window : window -> window_event -> (window, error) result
val transition_call : call -> call_event -> (call, error) result
val is_call_terminal : call -> bool

val string_of_window : window -> string
val string_of_window_event : window_event -> string
val string_of_call : call -> string
val string_of_call_event : call_event -> string
val string_of_error : error -> string
