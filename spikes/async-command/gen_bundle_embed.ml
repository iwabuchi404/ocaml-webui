(* Generator: reads a file and outputs an OCaml module with its content
   as an escaped string literal.
   Usage: ocaml gen_bundle_embed.ml <input> <output>
   Uses %S format to escape |}, backslash, quote, and newlines safely. *)
let () =
  let input = Sys.argv.(1) in
  let output = Sys.argv.(2) in
  let ic = open_in input in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  let oc = open_out output in
  Printf.fprintf oc "let bundle = %S\n" (Bytes.to_string buf);
  close_out oc
