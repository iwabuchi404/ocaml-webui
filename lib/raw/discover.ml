let read_command command =
  let channel = Unix.open_process_in command in
  let buffer = Buffer.create 256 in
  (try
     while true do
       Buffer.add_string buffer (input_line channel);
       Buffer.add_char buffer ' '
     done
   with End_of_file -> ());
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 -> String.trim (Buffer.contents buffer)
  | Unix.WEXITED code ->
      failwith (Printf.sprintf "%s exited with code %d" command code)
  | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
      failwith (Printf.sprintf "%s stopped by signal %d" command signal)

let split_words value =
  let words = ref [] in
  let word = Buffer.create 32 in
  let flush () =
    if Buffer.length word > 0 then (
      words := Buffer.contents word :: !words;
      Buffer.clear word)
  in
  String.iter
    (function
      | ' ' | '\t' | '\r' | '\n' -> flush ()
      | character -> Buffer.add_char word character)
    value;
  flush ();
  List.rev !words

let quote value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter
    (function
      | ('"' | '\\') as character ->
          Buffer.add_char buffer '\\';
          Buffer.add_char buffer character
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let write_sexp path values =
  let channel = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () ->
      output_char channel '(';
      List.iter
        (fun value ->
          output_char channel ' ';
          output_string channel (quote value))
        values;
      output_string channel " )\n")

let () =
  let common_c_flags =
    [ "-std=c++14"; "-I"; "../../vendor/webview/core/include" ]
  in
  let c_flags, library_flags =
    match Sys.os_type with
    | "Win32" ->
        ( common_c_flags
          @ [
              "-I";
              "../../vendor/webview/compatibility/mingw/include";
              "-I";
              "../../vendor/webview2-sdk-1.0.1150.38/include";
            ],
          [
            "-lstdc++";
            "-ladvapi32";
            "-lole32";
            "-lshell32";
            "-lshlwapi";
            "-luser32";
            "-lversion";
          ] )
    | "Unix" ->
        let kernel = read_command "uname -s" in
        if kernel <> "Linux" then
          failwith ("unsupported Unix platform: " ^ kernel);
        let packages = "gtk+-3.0 webkit2gtk-4.1" in
        let pkg_c_flags =
          read_command ("pkg-config --cflags " ^ packages) |> split_words
        in
        let pkg_library_flags =
          read_command ("pkg-config --libs " ^ packages) |> split_words
        in
        ( common_c_flags @ pkg_c_flags,
          [ "-lstdc++" ] @ pkg_library_flags @ [ "-ldl" ] )
    | platform -> failwith ("unsupported platform: " ^ platform)
  in
  write_sexp "c_flags.sexp" c_flags;
  write_sexp "c_library_flags.sexp" library_flags
