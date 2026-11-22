(* decl_parse.ml — Phase 2 α PoC: `commands.ml`（制限OCaml構文）のparse。

   宣言ファイルは「parseするがcompileしない」:
   - `type` 宣言（record / variant / alias）→ .atd 断片
   - `let x = command "name" ~mode:... ~input:T ~output:T ~error:T`
     → manifest IR（Command_manifest.command）
   - `[@@@schema_module "..."]` / `[@@@ts_module "..."]` 浮遊attributeで
     file全体の生成先module/import pathを指定

   非対応構文は `Error` 例外（位置+理由）で reject する。
   任意OCaml型の汎用compilerではない — 型subsetのみ受理。 *)

open Parsetree

exception Error of Lexing.position * string

let fail pos fmt =
  Printf.ksprintf (fun m -> raise (Error (pos, m))) fmt

let loc_of_pos pos =
  Printf.sprintf "%s:%d:%d" pos.Lexing.pos_fname pos.Lexing.pos_lnum
    (pos.Lexing.pos_cnum - pos.Lexing.pos_bol + 1)

(* ─── 名前変換 ─── *)

(* delay_ms -> delayMs（record fieldの既定wire名） *)
let snake_to_camel s =
  match String.split_on_char '_' s with
  | [] -> s
  | first :: rest ->
      first
      ^ String.concat ""
          (List.map
             (fun p ->
               if p = "" then p
               else
                 String.make 1 (Char.uppercase_ascii p.[0])
                 ^ String.sub p 1 (String.length p - 1))
             rest)

(* Empty_message -> empty_message、FooBar -> foo_bar（constructorの既定wire名） *)
let ctor_to_wire s =
  let b = Buffer.create (String.length s + 4) in
  String.iteri
    (fun i c ->
      if
        Char.uppercase_ascii c = c && Char.lowercase_ascii c <> c && i > 0
        && s.[i - 1] <> '_'
      then Buffer.add_char b '_';
      Buffer.add_char b (Char.lowercase_ascii c))
    s;
  Buffer.contents b

(* "hello.atd" -> "Hello"、"commands.ml" -> "Commands" *)
let module_name_of_file path =
  let base = Filename.basename path in
  let stem =
    try Filename.chop_extension base with Invalid_argument _ -> base
  in
  String.mapi (fun i c -> if i = 0 then Char.uppercase_ascii c else c) stem

(* ─── attribute ─── *)

(* [@json "wire_name"] / [@@@key "value"] の文字列payload *)
let string_payload (attr : attribute) =
  match attr.attr_payload with
  | PStr [ { pstr_desc = Pstr_eval (e, _); _ } ] -> (
      match e.pexp_desc with
      | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } -> Some s
      | _ -> None)
  | _ -> None

let json_wire_name (attrs : attribute list) ~default =
  match List.find_opt (fun a -> a.attr_name.txt = "json") attrs with
  | Some attr -> Option.value (string_payload attr) ~default
  | None -> default

(* ─── type → ATD ─── *)

let rec atd_of_core_type (ct : core_type) : string =
  let open Asttypes in
  match ct.ptyp_desc with
  | Ptyp_constr ({ txt = Lident "string"; _ }, []) -> "string"
  | Ptyp_constr ({ txt = Lident "int"; _ }, []) -> "int"
  | Ptyp_constr ({ txt = Lident "float"; _ }, []) -> "float"
  | Ptyp_constr ({ txt = Lident "bool"; _ }, []) -> "bool"
  | Ptyp_constr ({ txt = Lident "list"; _ }, [ t ]) ->
      atd_of_core_type t ^ " list"
  | Ptyp_constr ({ txt = Lident "option"; _ }, [ t ]) ->
      atd_of_core_type t ^ " option"
  | Ptyp_constr ({ txt = Lident name; _ }, []) -> name
  | Ptyp_constr ({ txt = Ldot _; _ }, _) ->
      fail ct.ptyp_loc.loc_start
        "qualified type references (Module.t) are not supported — declare \
         the type in this file"
  | Ptyp_constr _ ->
      fail ct.ptyp_loc.loc_start
        "parameterized types other than list/option are not supported"
  | Ptyp_arrow _ ->
      fail ct.ptyp_loc.loc_start
        "function types are not supported in command payloads"
  | Ptyp_tuple _ ->
      fail ct.ptyp_loc.loc_start
        "tuple types are not supported — use a record"
  | Ptyp_variant _ ->
      fail ct.ptyp_loc.loc_start
        "polymorphic variants are not supported — use a plain variant"
  | Ptyp_var name ->
      fail ct.ptyp_loc.loc_start
        "type parameter '%s is not supported — use concrete types" name
  | Ptyp_alias (inner, _) -> atd_of_core_type inner
  | _ -> fail ct.ptyp_loc.loc_start "unsupported type form in payload type"

let atd_of_type_decl (td : type_declaration) : string =
  if td.ptype_params <> [] then
    fail td.ptype_loc.loc_start
      "parameterized type declarations are not supported";
  match td.ptype_kind with
  | Ptype_record fields ->
      let body =
        fields
        |> List.map (fun (ld : label_declaration) ->
               let wire =
                 json_wire_name ld.pld_attributes
                   ~default:(snake_to_camel ld.pld_name.txt)
               in
               Printf.sprintf "  %s <json name=%S>: %s;" ld.pld_name.txt
                 wire (atd_of_core_type ld.pld_type))
        |> String.concat "\n"
      in
      Printf.sprintf "type %s = {\n%s\n}\n" td.ptype_name.txt body
  | Ptype_variant ctors ->
      let body =
        ctors
        |> List.map (fun (cd : constructor_declaration) ->
               if cd.pcd_res <> None then
                 fail cd.pcd_loc.loc_start
                   "GADT-style result annotations are not supported";
               let wire =
                 json_wire_name cd.pcd_attributes
                   ~default:(ctor_to_wire cd.pcd_name.txt)
               in
               match cd.pcd_args with
               | Pcstr_tuple [] ->
                   Printf.sprintf "  | %s <json name=%S>" cd.pcd_name.txt
                     wire
               | Pcstr_tuple [ t ] ->
                   Printf.sprintf "  | %s <json name=%S> of %s"
                     cd.pcd_name.txt wire (atd_of_core_type t)
               | Pcstr_tuple _ ->
                   fail cd.pcd_loc.loc_start
                     "multi-argument constructors are not supported — use \
                      a record payload"
               | Pcstr_record _ ->
                   fail cd.pcd_loc.loc_start
                     "inline record constructors are not supported — \
                      declare the record separately")
        |> String.concat "\n"
      in
      Printf.sprintf "type %s = [\n%s\n]\n" td.ptype_name.txt body
  | Ptype_abstract -> (
      match td.ptype_manifest with
      | Some ct ->
          Printf.sprintf "type %s = %s\n" td.ptype_name.txt
            (atd_of_core_type ct)
      | None ->
          fail td.ptype_loc.loc_start
            "abstract type declarations without a manifest are not \
             supported")
  | Ptype_open ->
      fail td.ptype_loc.loc_start "open types are not supported"

(* ─── command宣言 → manifest IR ─── *)

let string_arg_at (e : expression) : string =
  match e.pexp_desc with
  | Pexp_constant { pconst_desc = Pconst_string (s, _, _); _ } -> s
  | _ -> fail e.pexp_loc.loc_start "expected a string literal"

let int_arg_at (e : expression) : int =
  match e.pexp_desc with
  | Pexp_constant { pconst_desc = Pconst_integer (s, _); _ } -> int_of_string s
  | _ -> fail e.pexp_loc.loc_start "expected an integer literal"

let type_ref_arg_at (e : expression) : string =
  match e.pexp_desc with
  | Pexp_ident { txt = Longident.Lident name; loc = _ } -> name
  | _ ->
      fail e.pexp_loc.loc_start
        "expected a type name (e.g. ~input:ping_request)"

(* `let x = command "name" ~input:T ~output:T ~error:T ~mode:"sync"` *)
let manifest_command_of_binding ~default_schema ~default_ts
    (vb : value_binding) : Command_manifest.command =
  match vb.pvb_expr.pexp_desc with
  | Pexp_apply
      ( { pexp_desc = Pexp_ident { txt = Longident.Lident "command"; _ }; _ },
        (Asttypes.Nolabel, name_expr) :: args ) ->
      let name = string_arg_at name_expr in
      let get label =
        List.find_map
          (fun (lbl, e) ->
            match lbl with
            | Asttypes.Labelled l when l = label -> Some e
            | Asttypes.Optional l when l = label -> Some e
            | _ -> None)
          args
      in
      let get_str label = Option.map string_arg_at (get label) in
      let get_tref label = Option.map type_ref_arg_at (get label) in
      Command_manifest.create_command ~name
        ?kind:(get_str "kind")
        ?schema_module:(match get_str "schema_module" with
                        | Some _ as s -> s
                        | None -> default_schema)
        ?input_type:(get_tref "input")
        ?output_type:(get_tref "output")
        ?error_type:(get_tref "error")
        ?mode:(get_str "mode")
        ?timeout_ms:(Option.map int_arg_at (get "timeout_ms"))
        ?ts_module:(match get_str "ts_module" with
                    | Some _ as s -> s
                    | None -> default_ts)
        ?ts_output_type:(get_str "ts_output_type")
        ?ts_type_decls:(get_str "ts_type_decls") ()
  | _ ->
      fail vb.pvb_expr.pexp_loc.loc_start
        "only `let x = command \"name\" ~input:T ~output:T ~error:T` is \
         allowed at top level"

(* ─── 構造全体 ─── *)

type decl_result = {
  atd_text : string;
  commands : Command_manifest.command list;
  declared_types : string list;
}

(* [@@@schema_module "..."] / [@@@ts_module "..."] を先に読み、
   次に全type宣言とcommand適用を処理する *)
let parse ~(atd_output : string) (path : string) : decl_result =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let lexbuf = Lexing.from_channel ic in
      lexbuf.Lexing.lex_curr_p <-
        { lexbuf.Lexing.lex_curr_p with Lexing.pos_fname = path };
      let structure = Parse.implementation lexbuf in
      (* 第1パス: attribute / 型宣言の収集と構造検証 *)
      let schema_override = ref None in
      let ts_override = ref None in
      let atd_parts = ref [] in
      let type_names = ref [] in
      let bindings = ref [] in
      List.iter
        (fun (item : structure_item) ->
          match item.pstr_desc with
          | Pstr_type (_, decls) ->
              List.iter
                (fun td ->
                  type_names := td.ptype_name.txt :: !type_names;
                  atd_parts := atd_of_type_decl td :: !atd_parts)
                decls
          | Pstr_attribute attr -> (
              match attr.attr_name.txt with
              | "schema_module" -> schema_override := string_payload attr
              | "ts_module" -> ts_override := string_payload attr
              | name ->
                  fail item.pstr_loc.loc_start
                    "unsupported top-level attribute [@@@%s]" name)
          | Pstr_value (Asttypes.Nonrecursive, [ vb ]) ->
              bindings := vb :: !bindings
          | _ ->
              fail item.pstr_loc.loc_start
                "only `type` declarations, `let x = command ...`, and \
                 [@@@schema_module] / [@@@ts_module] attributes are \
                 allowed")
        structure;
      let default_schema =
        match !schema_override with
        | Some _ as s -> s
        | None -> Some (module_name_of_file atd_output)
      in
      let stem = Filename.basename atd_output in
      let stem =
        try Filename.chop_extension stem with Invalid_argument _ -> stem
      in
      let default_ts =
        match !ts_override with
        | Some _ as s -> s
        | None -> Some ("./" ^ stem ^ ".js")
      in
      (* 第2パス: command適用 → manifest IR *)
      let cmds =
        List.rev_map
          (manifest_command_of_binding ~default_schema ~default_ts)
          !bindings
      in
      (* ~input/~output/~error が宣言済み型を指すか検証 *)
      List.iter
        (fun (c : Command_manifest.command) ->
          match c.kind with
          | Some "raw_json" -> ()
          | _ ->
              List.iter
                (fun (label, tref) ->
                  match tref with
                  | Some t when not (List.mem t !type_names) ->
                      fail lexbuf.Lexing.lex_curr_p
                        "command %S: ~%s:%s — type %S is not declared in \
                         this file"
                        c.name label t t
                  | _ -> ())
                [
                  ("input", c.input_type);
                  ("output", c.output_type);
                  ("error", c.error_type);
                ])
        cmds;
      {
        atd_text = String.concat "\n" (List.rev !atd_parts);
        commands = cmds;
        declared_types = List.rev !type_names;
      })

let report_error ppf pos msg =
  Printf.fprintf ppf "%s: error: %s\n%!" (loc_of_pos pos) msg
