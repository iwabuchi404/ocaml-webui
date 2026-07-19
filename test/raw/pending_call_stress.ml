open Webui_raw.Window

type action = Resolve | Reject | Cancel

type completion = Queued | Cancelled | Already_completed | Window_closing

type counters = {
  sent : int Atomic.t;
  already_completed : int Atomic.t;
  window_closing : int Atomic.t;
  duplicate_rejected : int Atomic.t;
}

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let wait_until ~timeout predicate =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if predicate () then true
    else if Unix.gettimeofday () >= deadline then false
    else (
      Domain.cpu_relax ();
      Unix.sleepf 0.002;
      loop ())
  in
  loop ()

let make_counters () =
  {
    sent = Atomic.make 0;
    already_completed = Atomic.make 0;
    window_closing = Atomic.make 0;
    duplicate_rejected = Atomic.make 0;
  }

let increment counter = ignore (Atomic.fetch_and_add counter 1)

let record_completion counters = function
  | Queued | Cancelled -> increment counters.sent
  | Already_completed -> increment counters.already_completed
  | Window_closing -> increment counters.window_closing

let complete action call index =
  match action with
  | Resolve ->
      (match
         Webui_raw.Call.resolve_json call
           (Printf.sprintf "{\"index\":%d}" index)
       with
      | `Queued -> Queued
      | `Already_completed -> Already_completed
      | `Window_closing -> Window_closing
      | `Enqueue_failed error -> fail_error error)
  | Reject ->
      (match
         Webui_raw.Call.reject_json call
           (Printf.sprintf "{\"code\":\"rejected_%d\"}" index)
       with
      | `Queued -> Queued
      | `Already_completed -> Already_completed
      | `Window_closing -> Window_closing
      | `Enqueue_failed error -> fail_error error)
  | Cancel -> (
      match Webui_raw.Call.cancel call with
      | `Cancelled -> Cancelled
      | `Already_completed -> Already_completed)

let action_for index =
  match index mod 3 with 0 -> Resolve | 1 -> Reject | _ -> Cancel

let shuffled_indices ~seed count =
  let random = Random.State.make [| seed; count |] in
  let indices = Array.init count Fun.id in
  for index = count - 1 downto 1 do
    let other = Random.State.int random (index + 1) in
    let value = indices.(index) in
    indices.(index) <- indices.(other);
    indices.(other) <- value
  done;
  indices

let run_cycle ~cycle ~calls_per_cycle =
  let window = require (Webui_raw.Window.create { debug = false }) in
  let received = Atomic.make 0 in
  let close_result = Atomic.make None in
  let counters = make_counters () in
  let first_completion_done = Atomic.make false in
  let calls = Array.init calls_per_cycle (fun _ -> Atomic.make None) in
  let binding =
    require
      (Webui_raw.Binding.create window ~name:"stress_call" (fun call ->
           let index = Atomic.fetch_and_add received 1 in
           if index >= calls_per_cycle then
             failwith "received more calls than requested";
           if index + 1 = calls_per_cycle then
             Printf.printf
               "pending_call_stress: cycle=%d registered=%d\n%!" cycle
               calls_per_cycle;
           Atomic.set calls.(index) (Some call)))
  in
  require
    (Webui_raw.Window.set_html window
       (Printf.sprintf
          {|<!doctype html><title>pending call stress</title><script>
for (let index = 0; index < %d; index += 1) {
  window.stress_call(index).catch(() => {});
}
</script>|}
          calls_per_cycle));
  let completion_worker =
    Domain.spawn (fun () ->
        let all_registered =
          wait_until ~timeout:15.0 (fun () ->
              Atomic.get received = calls_per_cycle)
        in
        if not all_registered then failwith "completion Domain timed out";
        let order = shuffled_indices ~seed:cycle calls_per_cycle in
        Array.iteri
          (fun position index ->
            Unix.sleepf (0.003 +. (float_of_int (position mod 4) *. 0.001));
            let call =
              match Atomic.get calls.(index) with
              | Some call -> call
              | None -> failwith "registered Call was not published"
            in
            let first = complete (action_for index) call index in
            record_completion counters first;
            if position = 0 then Atomic.set first_completion_done true;
            let duplicate = complete (action_for index) call index in
            if duplicate = Already_completed then
              increment counters.duplicate_rejected
            else failwith "duplicate Call completion was accepted")
          order)
  in
  let closer =
    Thread.create
      (fun () ->
        let all_registered =
          wait_until ~timeout:15.0 (fun () ->
              Atomic.get received = calls_per_cycle)
        in
        if not all_registered then
          Atomic.set close_result (Some (Error "calls were not registered"))
        else (
          Printf.printf "pending_call_stress: cycle=%d closer-ready\n%!" cycle;
          let first_completion =
            wait_until ~timeout:5.0 (fun () ->
                Atomic.get first_completion_done)
          in
          if not first_completion then
            failwith "first completion did not become ready";
          Unix.sleepf (0.035 +. (float_of_int (cycle mod 5) *. 0.003));
          match Webui_raw.Window.request_close window with
          | Ok () ->
              Printf.printf
                "pending_call_stress: cycle=%d close-accepted\n%!" cycle;
              Atomic.set close_result (Some (Ok ()))
          | Error error ->
              Printf.printf "pending_call_stress: cycle=%d close-error=%s\n%!"
                cycle (Webui_raw.Error.to_string error);
              Atomic.set close_result
                (Some (Error (Webui_raw.Error.to_string error)))))
      ()
  in
  Printf.printf "pending_call_stress: cycle=%d run-start\n%!" cycle;
  require (Webui_raw.Window.run window);
  Printf.printf "pending_call_stress: cycle=%d run-returned\n%!" cycle;
  Thread.join closer;
  Domain.join completion_worker;

  (match Atomic.get close_result with
  | Some (Ok ()) -> ()
  | Some (Error message) -> failwith message
  | None -> failwith "closer did not publish its result");
  if Atomic.get received <> calls_per_cycle then
    failwith "not every JS call reached the binding";
  if Atomic.get counters.duplicate_rejected <> calls_per_cycle then
    failwith "not every duplicate completion was rejected";
  if Atomic.get counters.sent = 0 then
    failwith "close happened before every first completion";
  if
    Atomic.get counters.already_completed + Atomic.get counters.window_closing = 0
  then failwith "every first completion beat close; shutdown race was not tested";

  let before_destroy = Webui_raw.Diagnostics.snapshot window in
  if before_destroy.window_state <> Stopped then
    failwith "window did not stop before destroy";
  if
    before_destroy.pending_calls <> 0 || before_destroy.dispatch_roots <> 0
    || before_destroy.queued_dispatches <> 0
  then failwith "Call or dispatch roots remained after run";
  if before_destroy.binding_roots <> 1 then
    failwith "binding root was lost before destroy";
  require (Webui_raw.Window.destroy window);
  let after_destroy = Webui_raw.Diagnostics.snapshot window in
  if
    after_destroy.binding_roots <> 0 || after_destroy.pending_calls <> 0
    || after_destroy.dispatch_roots <> 0
    || after_destroy.queued_dispatches <> 0
  then failwith "roots remained after destroy";
  require (Webui_raw.Binding.remove binding);
  ( Atomic.get counters.sent,
    Atomic.get counters.already_completed,
    Atomic.get counters.window_closing )

let run cycles calls_per_cycle =
  let sent = ref 0 in
  let already_completed = ref 0 in
  let window_closing = ref 0 in
  for cycle = 1 to cycles do
    Printf.printf "pending_call_stress: cycle=%d/%d start\n%!" cycle cycles;
    let cycle_sent, cycle_already, cycle_closing =
      run_cycle ~cycle ~calls_per_cycle
    in
    sent := !sent + cycle_sent;
    already_completed := !already_completed + cycle_already;
    window_closing := !window_closing + cycle_closing;
    Printf.printf
      "pending_call_stress: cycle=%d/%d done sent=%d already=%d closing=%d\n%!"
      cycle cycles cycle_sent cycle_already cycle_closing;
    Gc.full_major ()
  done;
  Printf.printf
    "pending_call_stress: passed cycles=%d calls=%d sent=%d already=%d closing=%d duplicates=%d\n%!"
    cycles (cycles * calls_per_cycle) !sent !already_completed !window_closing
    (cycles * calls_per_cycle)

let () =
  let cycles = ref 10 in
  let calls_per_cycle = ref 48 in
  Arg.parse
    [
      ("--cycles", Arg.Set_int cycles, "number of Window cycles");
      ("--calls", Arg.Set_int calls_per_cycle, "pending Calls per cycle");
    ]
    ignore "pending_call_stress [options]";
  if !cycles <= 0 || !calls_per_cycle <= 0 then
    invalid_arg "cycles and calls must be positive";
  Printexc.record_backtrace true;
  try run !cycles !calls_per_cycle
  with exn ->
    Printf.eprintf "pending_call_stress: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
