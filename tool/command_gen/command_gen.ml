(* ocaml-webui.command-gen — Command manifest から OCaml 登録コードと
   TS descriptor を生成する (Phase 1 PoC)。

   Usage:
     ocaml-webui.command-gen --manifest <commands.json>
       --ocaml <out.ml> --ts <out.ts>

   生成物:
   - OCaml: `handlers` record (全Commandのhandler必須 — 欠落はビルドエラー)
     と `commands : handlers -> Bridge.packed_command list`。
   - TS: 各Commandの `defineCommand` descriptor (wire名は manifest のみが正本)。

   wire名不一致・pack忘れが生成側で構造的に消えることを検証するのが目的。 *)

module M = Command_manifest

(* ─── 識別子変換 ─── *)

(* "usage.refresh" -> "usage_refresh" (OCaml record field / let名) *)
let ocaml_ident_of_name name =
  String.map
    (fun c -> if c = '.' || c = '-' then '_' else c)
    name

(* "usage_refresh_request" -> "UsageRefreshRequest" (TS型名) *)
let pascal_of_snake s =
  String.split_on_char '_' s
  |> List.map (fun part ->
         match part with
         | "" -> ""
         | _ ->
             String.make 1 (Char.uppercase_ascii part.[0])
             ^ String.sub part 1 (String.length part - 1))
  |> String.concat ""

(* "usage.refresh" -> "usageRefresh" (TS export名) *)
let camel_of_name name =
  let s = ocaml_ident_of_name name in
  let p = pascal_of_snake s in
  if String.length p = 0 then p
  else String.make 1 (Char.lowercase_ascii p.[0])
       ^ String.sub p 1 (String.length p - 1)

(* ─── manifest正規化 ─── *)

type cmd = {
  name : string;
  raw_json : bool;
  schema_module : string;      (* raw_jsonでは不使用 *)
  input_type : string;
  output_type : string;
  error_type : string;
  is_async : bool;
  timeout_ms : int option;
  ts_module : string;
  ts_output_type : string option;
  ts_type_decls : string option;
}

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("command-gen: " ^ s); exit 2) fmt

let require name field = function
  | Some v -> v
  | None -> fail "command %S: required field %s missing" name field

let normalize (c : M.command) : cmd =
  let raw_json =
    match c.kind with
    | None | Some "atd" -> false
    | Some "raw_json" -> true
    | Some k -> fail "command %S: unknown kind %S (expected \"atd\" or \"raw_json\")" c.name k
  in
  let is_async =
    match c.mode with
    | None | Some "sync" -> false
    | Some "async" -> true
    | Some m -> fail "command %S: unknown mode %S" c.name m
  in
  if raw_json then
    {
      name = c.name;
      raw_json;
      schema_module = "";
      input_type = "unit";
      output_type = "Yojson.Safe.t";
      error_type = "string";
      is_async;
      timeout_ms = c.timeout_ms;
      ts_module = "";
      ts_output_type = c.ts_output_type;
      ts_type_decls = c.ts_type_decls;
    }
  else
    {
      name = c.name;
      raw_json;
      schema_module = require c.name "schemaModule" c.schema_module;
      input_type = require c.name "input" c.input_type;
      output_type = require c.name "output" c.output_type;
      error_type = require c.name "error" c.error_type;
      is_async;
      timeout_ms = c.timeout_ms;
      ts_module = require c.name "tsModule" c.ts_module;
      ts_output_type = None;
      ts_type_decls = c.ts_type_decls;
    }

(* ─── OCaml生成 ─── *)

let emit_ocaml_handler_sig oc (c : cmd) =
  let schema = c.schema_module in
  Printf.fprintf oc "  %s : Bridge.context ->\n" (ocaml_ident_of_name c.name);
  if c.raw_json then begin
    (* raw_json: input unit / output Yojson.Safe.t / error string *)
    Printf.fprintf oc
      "    unit -> (Yojson.Safe.t, string) Bridge.responder ->\n"
  end else begin
    Printf.fprintf oc "    %s.%s -> (%s.%s, %s.%s) Bridge.responder ->\n"
      schema c.input_type schema c.output_type schema c.error_type
  end;
  if c.is_async then
    Printf.fprintf oc "    Bridge.cancellation_token -> unit;\n"
  else
    Printf.fprintf oc "    unit;\n"

let emit_ocaml_codec oc (c : cmd) =
  if c.raw_json then
    Printf.fprintf oc
      "           ~input_of_yojson:(fun _ -> ())\n\
      \           ~output_to_yojson:(fun j -> j)\n\
      \           ~error_to_yojson:(fun message ->\n\
      \             `Assoc\n\
      \               [ (\"code\", `String \"internal_error\");\n\
      \                 (\"message\", `String message);\n\
      \                 (\"retryable\", `Bool false);\n\
      \                 (\"category\", `String \"internal\") ]))\n"
  else
    let schema = c.schema_module in
    Printf.fprintf oc
      "           ~input_of_yojson:%s.%s_of_yojson\n\
      \           ~output_to_yojson:%s.yojson_of_%s\n\
      \           ~error_to_yojson:%s.yojson_of_%s)\n"
      schema c.input_type schema c.output_type schema c.error_type

let emit_ocaml_command oc (c : cmd) =
  let ident = ocaml_ident_of_name c.name in
  let define =
    if c.is_async then "Bridge.define_async" else "Bridge.define"
  in
  Printf.fprintf oc "    Bridge.pack\n";
  Printf.fprintf oc "      (%s\n" define;
  Printf.fprintf oc "         (Bridge.make_codec\n";
  emit_ocaml_codec oc c;
  (match c.timeout_ms with
   | Some ms -> Printf.fprintf oc "         ~name:%S ~timeout_ms:%d h.%s);\n" c.name ms ident
   | None -> Printf.fprintf oc "         ~name:%S h.%s);\n" c.name ident)

let emit_ocaml path (cmds : cmd list) =
  let oc = open_out_bin path in
  output_string oc "(* GENERATED FILE — do not edit. Source: command manifest. *)\n\n";
  output_string oc "module Bridge = Webui_bridge_atd\n\n";
  output_string oc "(* 全Commandのhandlerを必須化 — manifestに追加したCommandに\n";
  output_string oc "   handlerが無ければrecord構築時にビルドエラーになる。 *)\n";
  output_string oc "type handlers = {\n";
  List.iter (emit_ocaml_handler_sig oc) cmds;
  output_string oc "}\n\n";
  output_string oc "(* install へそのまま渡せる packed list。\n";
  output_string oc "   manifestの全Commandを含むため pack 忘れは構造的に起きない。 *)\n";
  output_string oc "let commands (h : handlers) : Bridge.packed_command list =\n  [\n";
  List.iter (emit_ocaml_command oc) cmds;
  output_string oc "  ]\n";
  close_out oc

(* ─── TS生成 ─── *)

let ts_type_names (c : cmd) =
  ( pascal_of_snake c.input_type,
    pascal_of_snake c.output_type,
    pascal_of_snake c.error_type )

let emit_ts_imports oc (cmds : cmd list) =
  (* 生成モジュールごとのimportをまとめる（同じmoduleに複数command可） *)
  let modules =
    cmds
    |> List.filter_map (fun c -> if c.raw_json then None else Some c.ts_module)
    |> List.sort_uniq compare
  in
  List.iter
    (fun m ->
      let fns =
        cmds
        |> List.filter (fun c -> (not c.raw_json) && c.ts_module = m)
        |> List.concat_map (fun c ->
               let ti, to_, te = ts_type_names c in
               [ "write" ^ ti; "read" ^ to_; "read" ^ te;
                 "type " ^ ti; "type " ^ to_; "type " ^ te ])
      in
      Printf.fprintf oc "import {\n";
      List.iter (Printf.fprintf oc "  %s,\n") fns;
      Printf.fprintf oc "} from %S;\n\n" m)
    modules;
  output_string oc
    "import { defineCommand, type CommandDescriptor } from \"./client.js\";\n\n"

let emit_ts_descriptor oc (c : cmd) =
  let export = camel_of_name c.name in
  if c.raw_json then begin
    let out_ty =
      match c.ts_output_type with Some t -> t | None -> "unknown"
    in
    (match c.ts_type_decls with
     | Some decls -> Printf.fprintf oc "%s\n\n" decls
     | None -> ());
    Printf.fprintf oc
      "export const %s: CommandDescriptor<null, %s, never> =\n\
      \  defineCommand(\n\
      \    %S,\n\
      \    () => null,\n\
      \    (json) => json as %s,\n\
      \    (json) => json as never,\n\
      \  );\n\n"
      export out_ty c.name out_ty
  end else begin
    let ti, to_, te = ts_type_names c in
    Printf.fprintf oc
      "export const %s: CommandDescriptor<%s, %s, %s> =\n\
      \  defineCommand(\n\
      \    %S,\n\
      \    write%s,\n\
      \    read%s,\n\
      \    read%s,\n\
      \  );\n\n"
      export ti to_ te c.name ti to_ te
  end

let emit_ts path (cmds : cmd list) =
  let oc = open_out_bin path in
  output_string oc "// GENERATED FILE — do not edit. Source: command manifest.\n\n";
  emit_ts_imports oc cmds;
  List.iter (emit_ts_descriptor oc) cmds;
  close_out oc

(* ─── main ─── *)

let () =
  let manifest_path = ref "" in
  let ocaml_path = ref "" in
  let ts_path = ref "" in
  let args = Array.length Sys.argv in
  let i = ref 1 in
  while !i < args do
    let need_value flag ref_ =
      if !i + 1 >= args then fail "%s requires a value" flag;
      ref_ := Sys.argv.(!i + 1);
      i := !i + 2
    in
    (match Sys.argv.(!i) with
     | "--manifest" -> need_value "--manifest" manifest_path
     | "--ocaml" -> need_value "--ocaml" ocaml_path
     | "--ts" -> need_value "--ts" ts_path
     | flag -> fail "unknown flag %s" flag)
  done;
  if !manifest_path = "" || !ocaml_path = "" || !ts_path = "" then
    fail "usage: ocaml-webui.command-gen --manifest <json> --ocaml <out.ml> --ts <out.ts>";
  let json = Yojson.Safe.from_file !manifest_path in
  let manifest = M.manifest_of_yojson json in
  let cmds = List.map normalize manifest.M.commands in
  emit_ocaml !ocaml_path cmds;
  emit_ts !ts_path cmds
