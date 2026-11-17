(* NDJSON echo worker for headless tests. Speaks JSON-RPC: each input line
   is a request object with id/method/params; each response is one line. *)

let respond id result =
  let fields =
    match id with
    | Some v -> [ ("jsonrpc", `String "2.0"); ("id", v); ("result", result) ]
    | None -> [ ("jsonrpc", `String "2.0"); ("id", `Null); ("result", result) ]
  in
  output_string stdout (Yojson.Safe.to_string (`Assoc fields));
  output_char stdout '\n';
  flush stdout

let respond_error id code message =
  let err = `Assoc [ ("code", `Int code); ("message", `String message) ] in
  let fields =
    match id with
    | Some v -> [ ("jsonrpc", `String "2.0"); ("id", v); ("error", err) ]
    | None -> [ ("jsonrpc", `String "2.0"); ("id", `Null); ("error", err) ]
  in
  output_string stdout (Yojson.Safe.to_string (`Assoc fields));
  output_char stdout '\n';
  flush stdout

let emit_notification () =
  output_string stdout
    (Yojson.Safe.to_string
       (`Assoc
         [ ("jsonrpc", `String "2.0"); ("method", `String "tick") ]));
  output_char stdout '\n';
  flush stdout

let () =
  if Array.exists (fun a -> a = "--noread") Sys.argv then
    (* Never reads stdin: used to keep the parent's writer domain
       blocked on a full pipe. *)
    (try
       while true do
         Unix.sleepf 1.0
       done
     with _ -> ())
  else
    (try
       while true do
         let line = input_line stdin in
         match Yojson.Safe.from_string line with
         | `Assoc f ->
             let id = List.assoc_opt "id" f in
             let m =
               match List.assoc_opt "method" f with
               | Some (`String s) -> s
               | _ -> ""
             in
             let params =
               match List.assoc_opt "params" f with
               | Some p -> p
               | None -> `Null
             in
             (match m with
              | "echo" -> respond id params
              | "sleep" ->
                  let ms =
                    match params with
                    | `Assoc pf -> (
                        match List.assoc_opt "ms" pf with
                        | Some (`Int n) -> n
                        | _ -> 0)
                    | _ -> 0
                  in
                  Unix.sleepf (float_of_int ms /. 1000.);
                  respond id (`Assoc [ ("slept_ms", `Int ms) ])
              | "spam" ->
                  emit_notification ();
                  respond id `Null
              | "die" -> exit 3
              | _ -> respond_error id (-32601) ("unknown method: " ^ m))
         | _ -> ()
       done
     with End_of_file -> ())
