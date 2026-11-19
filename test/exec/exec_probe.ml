(* Probe child for exec tests. Flags compose in order:

   default         copy stdin to stdout until EOF, then exit 0
   --exit N        exit with code N (after earlier actions)
   --sleep MS      sleep MS milliseconds (after earlier actions)
   --noread        sleep 60s without reading stdin (killed by the test)
   --say-stdout S  write S to stdout
   --say-stderr S  write S to stderr
   --stdout-flood  write 'x' to stdout forever
   --stderr-flood  write 'e' to stderr forever
   --grandchild MS spawn "<self> --grandchild-body MS" inheriting all
                   std handles so the grandchild keeps our pipes open,
                   then exit 0 immediately
   --grandchild-body MS
                   sleep MS then exit 0 (run as an inherited-handle
                   grandchild; orphan dies on its own) *)

let cat () =
  (* Byte-faithful copy: CRLF translation would corrupt binary round
     trips (and JSON payloads) on Windows. *)
  set_binary_mode_in stdin true;
  set_binary_mode_out stdout true;
  let tmp = Bytes.create 4096 in
  let rec loop () =
    match input stdin tmp 0 4096 with
    | 0 -> ()
    | n ->
        output stdout tmp 0 n;
        flush stdout;
        loop ()
  in
  loop ()

let self = Sys.argv.(0)

let rec parse i =
  if i < Array.length Sys.argv then (
    (match Sys.argv.(i) with
     | "--exit" -> exit (int_of_string Sys.argv.(i + 1))
     | "--sleep" -> Unix.sleepf (float_of_string Sys.argv.(i + 1) /. 1000.)
     | "--noread" -> Unix.sleepf 60.0
     | "--say-stdout" ->
         output_string stdout Sys.argv.(i + 1);
         flush stdout
     | "--say-stderr" ->
         output_string stderr Sys.argv.(i + 1);
         flush stderr
     | "--stdout-flood" ->
         let chunk = String.make 4096 'x' in
         while true do
           output_string stdout chunk;
           flush stdout
         done
     | "--stderr-flood" ->
         let chunk = String.make 4096 'e' in
         while true do
           output_string stderr chunk;
           flush stderr
         done
     | "--grandchild" ->
         let ms = Sys.argv.(i + 1) in
         ignore
           (Unix.create_process self
              [| self; "--grandchild-body"; ms |]
              Unix.stdin Unix.stdout Unix.stderr);
         exit 0
     | "--grandchild-body" ->
         Unix.sleepf (float_of_string Sys.argv.(i + 1) /. 1000.);
         exit 0
     | _ -> ());
    parse (i + 2))

let () =
  if Array.length Sys.argv > 1 then parse 1 else cat ()
