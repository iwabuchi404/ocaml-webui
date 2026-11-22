(* commands_decl.ml — Phase 2 α PoC fixture。
   commands.json と等価な宣言をOCaml構文で書き、
   生成される commands_gen.ml/.ts がbyte-identicalになることを検証する。 *)

(* このfileの型宣言は gen.atd へ生成され、schema_module は
   Test_schema.Echo/Work をcommand毎に上書き指定する
   （file全体既定は使わない例として）。 *)

type echo_request = {
  text : string;
}

type echo_response = {
  echo : string;
}

type echo_error = {
  code : string;
  message : string;
  retryable : bool;
  category : string;
}

type work_request = {
  delay_ms : int;
}

type work_result = {
  elapsed_ms : int;
}

type work_error = {
  code : string;
  message : string;
  retryable : bool;
  category : string;
}

let echo = command "echo.ping" ~mode:"sync"
  ~schema_module:"Test_schema.Echo" ~ts_module:"./echo.js"
  ~input:echo_request ~output:echo_response ~error:echo_error

let work = command "work.slow" ~mode:"async" ~timeout_ms:5000
  ~schema_module:"Test_schema.Work" ~ts_module:"./work.js"
  ~input:work_request ~output:work_result ~error:work_error

let trace = command "trace.recent" ~kind:"raw_json" ~mode:"sync"
  ~ts_output_type:"TraceRecentResult"
  ~ts_type_decls:{ts|export interface TraceRecentResult { events: unknown[] }|ts}
