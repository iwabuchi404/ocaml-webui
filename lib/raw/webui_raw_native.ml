type window

type create_result = Created of window | Create_error of int * string

type native_error = (int * string) option

external create : bool -> create_result = "ocaml_webui_raw_create"
external state : window -> int = "ocaml_webui_raw_state"
external run : window -> native_error = "ocaml_webui_raw_run"

external request_close : window -> native_error
  = "ocaml_webui_raw_request_close"

external destroy : window -> native_error = "ocaml_webui_raw_destroy"

external set_title : window -> string -> native_error
  = "ocaml_webui_raw_set_title"

external set_size : window -> int -> int -> int -> native_error
  = "ocaml_webui_raw_set_size"

external navigate : window -> string -> native_error
  = "ocaml_webui_raw_navigate"

external set_html : window -> string -> native_error
  = "ocaml_webui_raw_set_html"

external init : window -> string -> native_error = "ocaml_webui_raw_init"
external eval : window -> string -> native_error = "ocaml_webui_raw_eval"
external dispatch :
  window -> (unit -> unit) -> (unit -> unit) -> native_error
  = "ocaml_webui_raw_dispatch"

type bind_result = Bound of int | Bind_error of int * string

external bind :
  window -> string -> (string -> string -> unit) -> bind_result
  = "ocaml_webui_raw_bind"

external unbind : window -> string -> int -> native_error
  = "ocaml_webui_raw_unbind"

external register_call :
  window -> string -> string -> (unit -> unit) -> native_error
  = "ocaml_webui_raw_register_call"

external finish_call : window -> string -> unit = "ocaml_webui_raw_finish_call"

external respond : window -> string -> int -> string -> native_error
  = "ocaml_webui_raw_return"

external record_callback_exception : window -> unit
  = "ocaml_webui_raw_record_callback_exception"

external fail_next_dispatch : window -> unit
  = "ocaml_webui_raw_fail_next_dispatch"

type diagnostics =
  int * int * int * int * int * int * int * int * int

external diagnostics : window -> diagnostics = "ocaml_webui_raw_diagnostics"
external version : unit -> string = "ocaml_webui_raw_version"
