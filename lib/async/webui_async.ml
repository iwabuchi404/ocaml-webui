type cancel_reason = [ `Js_cancel | `Timeout | `Window_close ]

type cancellation_token = {
  cancelled : bool Atomic.t;
  reason : cancel_reason option Atomic.t;
  external_check : (unit -> cancel_reason option) option;
}

let token ?external_check () =
  {
    cancelled = Atomic.make false;
    reason = Atomic.make None;
    external_check;
  }

let cancel token reason =
  Atomic.set token.reason (Some reason);
  Atomic.set token.cancelled true

let is_cancelled token =
  if Atomic.get token.cancelled then true
  else
    match token.external_check with
    | None -> false
    | Some check -> (
        match check () with
        | None -> false
        | Some reason ->
            cancel token reason;
            true)

let cancel_reason token =
  match Atomic.get token.reason with
  | Some _ as reason -> reason
  | None -> if is_cancelled token then Atomic.get token.reason else None

type 'a task = 'a Domain.t

let spawn f = Domain.spawn f
let await = Domain.join
let detach f = ignore (spawn f)

let parallel fs =
  let tasks = List.map spawn fs in
  let results =
    List.map (fun t -> try Ok (await t) with exn -> Error exn) tasks
  in
  match List.find_map (function Error exn -> Some exn | Ok _ -> None) results with
  | Some exn -> raise exn
  | None -> List.map (function Ok value -> value | Error _ -> assert false) results

let parallel_results fs =
  let tasks =
    List.map
      (fun f -> spawn (fun () -> try Ok (f ()) with exn -> Error exn))
      fs
  in
  List.map await tasks

let sleep_ms ms = if ms > 0 then Thread.delay (float_of_int ms /. 1000.0)
