(* gen_embed.ml — ファイルをOCaml文字列リテラルとして埋め込む
   Usage: ocaml gen_embed.ml <input> <let名> (stdoutへ出力)
   %S escapeで |} / quote / backslash / 改行を安全に処理 *)
let () =
  let input = Sys.argv.(1) in
  let name = Sys.argv.(2) in
  let ic = open_in_bin input in
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  close_in ic;
  Printf.printf "let %s = %S\n" name (Bytes.to_string buf)
