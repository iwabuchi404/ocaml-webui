open Webui_raw.For_testing

let fail format = Printf.ksprintf failwith format

let expect_window state event expected =
  match (transition_window state event, expected) with
  | Ok actual, `Ok wanted when actual = wanted -> ()
  | Error (Invalid_window_transition (actual_state, actual_event)), `Invalid
    when actual_state = state && actual_event = event -> ()
  | actual, _ ->
      fail "window transition %s + %s: unexpected result %s"
        (string_of_window state) (string_of_window_event event)
        (match actual with
        | Ok next -> "Ok " ^ string_of_window next
        | Error error -> "Error " ^ string_of_error error)

let expect_call state event expected =
  match (transition_call state event, expected) with
  | Ok actual, `Ok wanted when actual = wanted -> ()
  | Error (Invalid_call_transition (actual_state, actual_event)), `Invalid
    when actual_state = state && actual_event = event -> ()
  | Error (Call_already_completed actual_state), `Completed
    when actual_state = state -> ()
  | actual, _ ->
      fail "call transition %s + %s: unexpected result %s"
        (string_of_call state) (string_of_call_event event)
        (match actual with
        | Ok next -> "Ok " ^ string_of_call next
        | Error error -> "Error " ^ string_of_error error)

let test_all_window_transitions () =
  let states = [ Created; Running; Closing; Stopped; Destroyed ] in
  let events = [ Start_run; Request_close; Run_returned; Destroy ] in
  let expected state event =
    match (state, event) with
    | Created, Start_run -> `Ok Running
    | Created, Destroy -> `Ok Destroyed
    | Running, Request_close -> `Ok Closing
    | Running, Run_returned -> `Ok Stopped
    | Closing, Request_close -> `Ok Closing
    | Closing, Run_returned -> `Ok Stopped
    | Stopped, Destroy -> `Ok Destroyed
    | Destroyed, Destroy -> `Ok Destroyed
    | _ -> `Invalid
  in
  List.iter
    (fun state ->
      List.iter
        (fun event -> expect_window state event (expected state event))
        events)
    states

let test_all_call_transitions () =
  let states = [ Pending; Dispatch_queued; Responded; Cancelled; Failed ] in
  let events = [ Queue_response; Complete_response; Cancel; Fail ] in
  let expected state event =
    match (state, event) with
    | Pending, Queue_response -> `Ok Dispatch_queued
    | Pending, Cancel -> `Ok Cancelled
    | Pending, Fail -> `Ok Failed
    | Dispatch_queued, Complete_response -> `Ok Responded
    | Dispatch_queued, Cancel -> `Ok Cancelled
    | Dispatch_queued, Fail -> `Ok Failed
    | (Responded | Cancelled | Failed), _ -> `Completed
    | _ -> `Invalid
  in
  List.iter
    (fun state ->
      List.iter (fun event -> expect_call state event (expected state event)) events)
    states

let test_terminal_states () =
  if is_call_terminal Pending then fail "Pending must not be terminal";
  if is_call_terminal Dispatch_queued then
    fail "Dispatch_queued must not be terminal";
  List.iter
    (fun state ->
      if not (is_call_terminal state) then
        fail "%s must be terminal" (string_of_call state))
    [ Responded; Cancelled; Failed ]

let () =
  test_all_window_transitions ();
  test_all_call_transitions ();
  test_terminal_states ();
  Printf.printf "state_machine_test: passed (20 window + 20 call transitions)\n%!"
