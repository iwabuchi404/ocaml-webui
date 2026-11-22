(* examples/typed-hello — Command + schema宣言 (SSOT)
   このファイルは parse されるが compile はされない。
   ocaml-webui.command-gen --decl が
     - type 宣言   → schema/hello.atd 経由で OCaml/TS codec (atdml/atdts)
     - command宣言 → commands_gen.ml / commands_gen.ts
   を生成する。wire名は snake_case → camelCase / CamelCase → snake_case に
   自動変換される（[@json "..."] で上書き可能）。 *)

[@@@schema_module "Hello_schema.Hello"]
[@@@ts_module "./hello.js"]

(* hello.ping — sync Command。validation error の型付き返却を示す。 *)

type hello_ping_request = {
  message : string;
}

type hello_ping_response = {
  echoed : string;
  length : int;
  observed_trace_id : string;   (* wire: observedTraceId *)
}

type hello_ping_error_code =
  | Empty_message               (* wire: empty_message *)
  | Too_long                    (* wire: too_long *)

type hello_ping_error = {
  code : hello_ping_error_code;
  message : string;
  retryable : bool;
  category : string;
}

(* work.count — async Command。handler は cancellation_token を
   checkpoint で poll し、JS cancel / timeout / window close に
   協調的に応答する。 *)

type work_count_request = {
  target : int;
  delay_ms : int;               (* wire: delayMs *)
}

type work_count_result = {
  counted : int;
  elapsed_ms : int;             (* wire: elapsedMs *)
  cancelled : bool;
}

type work_count_error = {
  code : string;
  message : string;
  retryable : bool;
  category : string;
}

let hello_ping = command "hello.ping" ~mode:"sync"
  ~input:hello_ping_request ~output:hello_ping_response ~error:hello_ping_error

let work_count = command "work.count" ~mode:"async" ~timeout_ms:30000
  ~input:work_count_request ~output:work_count_result ~error:work_count_error

(* trace.recent — unified trace を JS へ返す raw_json passthrough。
   OCaml側codecを持たないため schema 宣言は不要。 *)

let trace_recent = command "trace.recent" ~kind:"raw_json" ~mode:"sync"
  ~ts_output_type:"TraceRecentResult"
  ~ts_type_decls:{ts|export interface TraceEvent {
  name: string;
  ts: number;
  trace_id: string;
  request_id: string;
  command: string;
  data: Record<string, unknown>;
}

export interface TraceRecentResult {
  events: TraceEvent[];
}|ts}
