module Trace = Webui_trace

let check label condition =
  if not condition then (
    Printf.eprintf "FAIL: %s\n%!" label;
    exit 1)

let test_make_and_json () =
  let event =
    Trace.make ~name:"invoke_received" ~trace_id:"t-1" ~request_id:"r-1"
      ~command:"text.analyze" ~data:[ ("outcome", `String "resolved") ] ()
  in
  check "name" (event.Trace.name = "invoke_received");
  check "trace_id" (event.trace_id = "t-1");
  check "ts positive" (event.ts > 0.);
  match Trace.to_yojson event with
  | `Assoc fields ->
      let get name = List.assoc_opt name fields in
      check "json event"
        (get "event" = Some (`String "invoke_received"));
      check "json traceId" (get "traceId" = Some (`String "t-1"));
      check "json requestId" (get "requestId" = Some (`String "r-1"));
      check "json command"
        (get "command" = Some (`String "text.analyze"));
      check "json data merged"
        (get "outcome" = Some (`String "resolved"));
      check "json ts" (match get "ts" with Some (`Float _) -> true | _ -> false)
  | _ -> check "to_yojson assoc" false

let test_defaults () =
  let event = Trace.make ~name:"x" () in
  check "empty trace_id" (event.Trace.trace_id = "");
  check "empty request_id" (event.request_id = "");
  check "empty command" (event.command = "");
  check "empty data" (event.data = [])

let test_emit () =
  (* None sink: must not raise *)
  Trace.emit None (Trace.make ~name:"noop" ());
  let seen = ref [] in
  let sink event = seen := event :: !seen in
  Trace.emit (Some sink) (Trace.make ~name:"a" ());
  Trace.emit (Some sink) (Trace.make ~name:"b" ());
  check "emit count" (List.length !seen = 2);
  match !seen with
  | [ second; first ] ->
      check "emit order" (first.Trace.name = "a" && second.name = "b")
  | _ -> check "emit order" false

let test_ring_buffer () =
  let sink, snapshot = Trace.ring_buffer ~capacity:3 in
  List.iter
    (fun i ->
      sink
        (Trace.make ~name:(Printf.sprintf "e%d" i) ~request_id:"r" ()))
    [ 1; 2; 3; 4; 5 ];
  let events = snapshot () in
  check "ring size" (List.length events = 3);
  match List.map (fun (e : Trace.event) -> e.name) events with
  | [ "e3"; "e4"; "e5" ] -> ()
  | names -> check ("ring order: " ^ String.concat "," names) false

let test_ring_buffer_partial () =
  let sink, snapshot = Trace.ring_buffer ~capacity:5 in
  sink (Trace.make ~name:"only" ());
  match List.map (fun (e : Trace.event) -> e.name) (snapshot ()) with
  | [ "only" ] -> ()
  | _ -> check "ring partial" false

let test_ring_buffer_concurrent () =
  let sink, snapshot = Trace.ring_buffer ~capacity:100 in
  let workers =
    List.init 4 (fun w ->
        Domain.spawn (fun () ->
            for i = 1 to 50 do
              sink
                (Trace.make
                   ~name:(Printf.sprintf "w%d-e%d" w i)
                   ())
            done))
  in
  List.iter Domain.join workers;
  check "concurrent ring size" (List.length (snapshot ()) = 100)

let () =
  test_make_and_json ();
  test_defaults ();
  test_emit ();
  test_ring_buffer ();
  test_ring_buffer_partial ();
  test_ring_buffer_concurrent ();
  Printf.printf "webui_trace_test: passed make json emit ring concurrent\n%!"
