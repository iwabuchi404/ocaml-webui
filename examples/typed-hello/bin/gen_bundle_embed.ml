(* Generator: reads files and outputs an OCaml module with their contents
   as escaped string literals.
   Usage: ocaml gen_bundle_embed.ml <output.ml> <input1> <name1> [<input2> <name2> ...]
   Uses %S format to escape |}, backslash, quote, and newlines safely. *)
let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Bytes.to_string buf

let () =
  let output = Sys.argv.(1) in
  let oc = open_out output in
  let i = ref 2 in
  while !i < Array.length Sys.argv do
    let input = Sys.argv.(!i) in
    let name = Sys.argv.(!i + 1) in
    let content = read_file input in
    Printf.fprintf oc "let %s = %S\n" name content;
    i := !i + 2
  done;
  close_out oc
