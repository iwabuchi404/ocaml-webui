type event = {
  name : string;
  ts : float;
  trace_id : string;
  request_id : string;
  command : string;
  data : (string * Yojson.Safe.t) list;
}

type sink = event -> unit

let now () = Unix.gettimeofday ()

let make ~name ?(trace_id = "") ?(request_id = "") ?(command = "")
    ?(data = []) () =
  { name; ts = now (); trace_id; request_id; command; data }

let emit sink event = match sink with None -> () | Some sink -> sink event

let to_yojson event =
  `Assoc
    ([
       ("event", `String event.name);
       ("ts", `Float event.ts);
       ("traceId", `String event.trace_id);
       ("requestId", `String event.request_id);
       ("command", `String event.command);
     ]
    @ event.data)

let to_json_string event = Yojson.Safe.to_string (to_yojson event)

let stderr_sink event =
  Printf.eprintf "%s\n%!" (to_json_string event)

let ring_buffer ~capacity =
  let capacity = max 1 capacity in
  let queue = Queue.create () in
  let lock = Mutex.create () in
  let sink event =
    Mutex.protect lock (fun () ->
        if Queue.length queue >= capacity then ignore (Queue.pop queue);
        Queue.push event queue)
  in
  let snapshot () =
    Mutex.protect lock (fun () -> List.of_seq (Queue.to_seq queue))
  in
  (sink, snapshot)
