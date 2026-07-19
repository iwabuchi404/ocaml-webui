open Webui_raw.Window

type ui_result = {
  before_destroy : Webui_raw.Diagnostics.snapshot;
  after_destroy : Webui_raw.Diagnostics.snapshot;
}

type slot = {
  label : string;
  window : Webui_raw.Window.t option Atomic.t;
  binding_calls : int Atomic.t;
  dispatch_executed : int Atomic.t;
  outcome : (ui_result, exn) result option Atomic.t;
}

let fail_error error = failwith (Webui_raw.Error.to_string error)
let require = function Ok value -> value | Error error -> fail_error error

let make_slot label =
  {
    label;
    window = Atomic.make None;
    binding_calls = Atomic.make 0;
    dispatch_executed = Atomic.make 0;
    outcome = Atomic.make None;
  }

let wait_until ~timeout predicate =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop () =
    if predicate () then true
    else if Unix.gettimeofday () >= deadline then false
    else (
      Domain.cpu_relax ();
      Unix.sleepf 0.005;
      loop ())
  in
  loop ()

let run_ui slot =
  try
    let window = require (Webui_raw.Window.create { debug = false }) in
    Atomic.set slot.window (Some window);
    ignore
      (require
         (Webui_raw.Binding.create window ~name:"ping" (fun call ->
              ignore (Atomic.fetch_and_add slot.binding_calls 1);
              ignore
                (Webui_raw.Call.resolve_json call
                   (Printf.sprintf "\"%s-ok\"" slot.label)))));
    require
      (Webui_raw.Window.set_html window
         (Printf.sprintf
            "<!doctype html><title>%s</title><script>window.ping('%s')</script>"
            slot.label slot.label));
    require (Webui_raw.Window.run window);
    let before_destroy = Webui_raw.Diagnostics.snapshot window in
    require (Webui_raw.Window.destroy window);
    let after_destroy = Webui_raw.Diagnostics.snapshot window in
    Atomic.set slot.outcome (Some (Ok { before_destroy; after_destroy }))
  with exn -> Atomic.set slot.outcome (Some (Error exn))

let get_window slot =
  match Atomic.get slot.window with
  | Some window -> window
  | None -> failwith (slot.label ^ " did not publish its Window")

let window_or_outcome_published slot =
  match (Atomic.get slot.window, Atomic.get slot.outcome) with
  | Some _, _ | _, Some _ -> true
  | None, None -> false

let cpu_checksum seed =
  let value = ref seed in
  for index = 1 to 150_000 do
    value := ((!value lsl 5) - !value + index) land 0x3fff_ffff
  done;
  !value

let run_producer slot window dispatch_count =
  for index = 1 to dispatch_count do
    let payload =
      Bytes.make (16_384 + (index mod 8 * 1024))
        (Char.chr (65 + (index mod 26)))
      |> Bytes.unsafe_to_string
    in
    let checksum = cpu_checksum (index + String.length slot.label) in
    require
      (Webui_raw.Window.dispatch window (fun () ->
           if String.length payload < 16_384 || checksum < 0 then
             failwith "captured producer data was corrupted";
           ignore (Atomic.fetch_and_add slot.dispatch_executed 1)))
  done

let validate_slot slot dispatch_count =
  match Atomic.get slot.outcome with
  | None -> failwith (slot.label ^ " UI Domain did not finish")
  | Some (Error exn) -> raise exn
  | Some (Ok result) ->
      if Atomic.get slot.binding_calls <> 1 then
        failwith (slot.label ^ " binding registry was not isolated");
      if Atomic.get slot.dispatch_executed <> dispatch_count then
        failwith (slot.label ^ " did not execute every dispatch");
      let before = result.before_destroy in
      if before.window_state <> Stopped then
        failwith (slot.label ^ " did not stop before destroy");
      if before.binding_roots <> 1 then
        failwith (slot.label ^ " lost its binding root before destroy");
      if
        before.dispatch_roots <> 0 || before.queued_dispatches <> 0
        || before.pending_calls <> 0
      then failwith (slot.label ^ " retained work after run");
      let after = result.after_destroy in
      if after.window_state <> Destroyed then
        failwith (slot.label ^ " was not destroyed");
      if
        after.binding_roots <> 0 || after.dispatch_roots <> 0
        || after.pending_calls <> 0 || after.queued_dispatches <> 0
      then failwith (slot.label ^ " retained roots after destroy")

let run_cycle cycle dispatch_count =
  let left = make_slot (Printf.sprintf "left-%d" cycle) in
  let right = make_slot (Printf.sprintf "right-%d" cycle) in
  let left_ui = Domain.spawn (fun () -> run_ui left) in
  let right_ui = Domain.spawn (fun () -> run_ui right) in
  let slots = [ left; right ] in
  let published =
    wait_until ~timeout:20.0 (fun () ->
        List.for_all window_or_outcome_published slots)
  in
  if not published then failwith "Windows were not created before timeout";
  let left_window = get_window left in
  let right_window = get_window right in
  let running =
    wait_until ~timeout:10.0 (fun () ->
        state left_window = Running && state right_window = Running)
  in
  if not running then failwith "both Windows did not enter Running";
  let bindings_ready =
    wait_until ~timeout:10.0 (fun () ->
        Atomic.get left.binding_calls = 1
        && Atomic.get right.binding_calls = 1)
  in
  if not bindings_ready then failwith "both binding callbacks did not run";

  let left_producer =
    Domain.spawn (fun () -> run_producer left left_window dispatch_count)
  in
  let right_producer =
    Domain.spawn (fun () -> run_producer right right_window dispatch_count)
  in
  for _ = 1 to 8 do
    let garbage = Array.init 20_000 (fun index -> string_of_int index) in
    if Array.length garbage <> 20_000 then failwith "allocation stress failed";
    Gc.full_major ()
  done;
  Domain.join left_producer;
  Domain.join right_producer;
  let dispatches_done =
    wait_until ~timeout:10.0 (fun () ->
        Atomic.get left.dispatch_executed = dispatch_count
        && Atomic.get right.dispatch_executed = dispatch_count)
  in
  if not dispatches_done then failwith "dispatches did not drain before timeout";
  require (Webui_raw.Window.request_close left_window);
  require (Webui_raw.Window.request_close right_window);
  Domain.join left_ui;
  Domain.join right_ui;
  validate_slot left dispatch_count;
  validate_slot right dispatch_count

let run cycles dispatch_count =
  for cycle = 1 to cycles do
    run_cycle cycle dispatch_count;
    Gc.full_major ()
  done;
  Printf.printf
    "multi_window_stress: passed cycles=%d windows=%d dispatches=%d\n%!"
    cycles (cycles * 2) (cycles * 2 * dispatch_count)

let () =
  let cycles = ref 3 in
  let dispatch_count = ref 40 in
  Arg.parse
    [
      ("--cycles", Arg.Set_int cycles, "number of two-Window cycles");
      ( "--dispatches",
        Arg.Set_int dispatch_count,
        "CPU/allocation-backed dispatches per Window" );
    ]
    ignore "multi_window_stress [options]";
  Printexc.record_backtrace true;
  try run !cycles !dispatch_count
  with exn ->
    Printf.eprintf "multi_window_stress: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
