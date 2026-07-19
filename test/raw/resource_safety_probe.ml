let fail_error error = failwith (Webui_raw.Error.to_string error)

let test_with_window () =
  let before = Webui_raw.Diagnostics.leaked_windows () in
  (match
     Webui_raw.Window.with_window { debug = false } (fun window ->
         match Webui_raw.Window.set_title window "with_window probe" with
         | Ok () -> 42
         | Error error -> fail_error error)
   with
  | Ok 42 -> ()
  | Ok _ -> failwith "with_window returned an unexpected value"
  | Error error -> fail_error error);
  (try
     ignore
       (Webui_raw.Window.with_window { debug = false } (fun _ -> raise Exit));
     failwith "with_window swallowed its callback exception"
   with Exit -> ());
  Gc.full_major ();
  if Webui_raw.Diagnostics.leaked_windows () <> before then
    failwith "with_window leaked a native Window"

let test_leak_detection () =
  let before = Webui_raw.Diagnostics.leaked_windows () in
  let create_and_forget () =
    match Webui_raw.Window.create { debug = false } with
    | Ok _ -> ()
    | Error error -> fail_error error
  in
  create_and_forget ();
  Gc.full_major ();
  Gc.full_major ();
  if Webui_raw.Diagnostics.leaked_windows () <> before + 1 then
    failwith "GC finalizer did not record the missing explicit destroy"

let run () =
  test_with_window ();
  test_leak_detection ();
  Printf.printf "resource_safety_probe: passed with_window leak_detection=1\n%!"

let () =
  Printexc.record_backtrace true;
  try run ()
  with exn ->
    Printf.eprintf "resource_safety_probe: failed: %s\n%s\n%!"
      (Printexc.to_string exn) (Printexc.get_backtrace ());
    exit 1
