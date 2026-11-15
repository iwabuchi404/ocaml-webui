(* Bridge install probe — requires a real Window. Not headless-safe;
   run manually: opam exec -- dune exec test/bridge_atd/install_probe.exe *)

module Bridge = Webui_bridge_atd

let fail msg = failwith msg

let () =
  let codec =
    Bridge.make_codec
      ~input_of_yojson:(fun _ -> ())
      ~output_to_yojson:(fun _ -> `Null)
      ~error_to_yojson:(fun _ -> `Null)
  in
  let cmd = Bridge.define codec ~name:"dup" (fun _ _ _ -> ()) in
  let window =
    match Webui_raw.Window.create { debug = false } with
    | Ok w -> w
    | Error e -> fail ("window create failed: " ^ Webui_raw.Error.to_string e)
  in
  (match Bridge.install window ~commands:[Bridge.pack cmd; Bridge.pack cmd] with
   | Error (Bridge.Duplicate_command "dup") -> ()
   | Error (Bridge.Duplicate_command name) ->
     fail ("duplicate name mismatch: " ^ name)
   | Error (Bridge.Raw_error e) ->
     fail ("unexpected raw error: " ^ Webui_raw.Error.to_string e)
   | Ok _ -> fail "duplicate command not detected");
  ignore (Webui_raw.Window.destroy window);
  Printf.printf "install_probe: passed duplicate-command rejection\n%!"
