(** Supervised external-process workers speaking line-delimited JSON-RPC.

    A worker is one OS child process spawned directly (no shell) with
    stdin/stdout pipes. Requests are multiplexed over the shared pipes by
    numeric ids; a dedicated reader domain demultiplexes responses and
    forwards id-less messages to the notification callback.

    Cancellation semantics: [kill] is forceful termination. On Windows it
    maps to [TerminateProcess] via the process handle; on POSIX to SIGKILL.
    There is no grace period and no cooperative cancel frame -- external
    processes cannot be assumed to honour one.

    Per-request [timeout_ms] fails the request only; the worker stays
    alive and the late response is discarded when it arrives.

    Note: {!pid} returns the value OCaml's Unix library reports. On
    Windows this is the process HANDLE exposed as a pseudo-pid; it works
    with [Unix.waitpid]/[Unix.kill] but does not equal the OS-level PID. *)

type worker

type restart_policy =
  | Never
  | On_crash of int  (** Maximum number of restarts after unexpected exit. *)

type error =
  | Spawn_failed of string
  | Worker_exited  (** Process exited; pending requests were failed. *)
  | Worker_killed  (** Killed via {!kill} or {!shutdown_all}. *)
  | Worker_dead  (** Request sent to a dead worker with no restart left. *)
  | Timeout  (** Per-request deadline elapsed; worker remains alive. *)
  | Remote_error of Yojson.Safe.t  (** JSON-RPC [error] object. *)
  | Protocol_error of string

type status = Alive | Dead | Killed

val spawn :
  name:string ->
  argv:string list ->
  ?restart:restart_policy ->
  ?on_notification:(Yojson.Safe.t -> unit) ->
  ?trace:Webui_trace.sink ->
  unit ->
  (worker, error) result
(** Spawns [argv] directly (no shell). [argv.0] is the program, searched in
    PATH. The reader domain starts immediately. Emits [worker_spawned]. *)

val request :
  worker ->
  ?trace_id:string ->
  ?timeout_ms:int ->
  method_:string ->
  Yojson.Safe.t ->
  (Yojson.Safe.t, error) result
(** Sends [{"jsonrpc":"2.0","id":n,"method":m,"params":p}] and waits for the
    matching response. Returns the [result] payload, or [Remote_error] when
    the response carries an [error] object. Emits [worker_request] and
    [worker_response]/[worker_timeout]. *)

val kill : worker -> unit
(** Force-terminates the process. Pending requests fail with
    [Worker_killed]. Idempotent. Emits [worker_killed]. *)

val is_alive : worker -> bool
val status : worker -> status
val pid : worker -> int option
(** Current process pid (pseudo-pid on Windows); [None] when not running. *)

val restart_count : worker -> int
val pending_count : worker -> int

val shutdown_all : unit -> unit
(** Kills every live worker registered by {!spawn}. Intended for
    application shutdown. *)

(** {2 Trace events}

    All events carry [data.worker = name]. Request-scoped events reuse the
    caller's [trace_id] so they join the parent Command's trace.

    - [worker_spawned] \{pid\}
    - [worker_request] \{method, request_id\} (+ trace_id when given)
    - [worker_response] \{request_id, outcome, duration_ms\}
    - [worker_timeout] \{method, request_id, timeout_ms\}
    - [worker_late_response] \{request_id\}
    - [worker_notification] \{method\}  -- received, not per request
    - [worker_protocol_error] \{line\}  -- truncated unparseable line
    - [worker_exited] \{pid, intentional, will_restart, pending_failed\}
    - [worker_restart] \{attempt, pid\}
    - [worker_killed] \{pid, pending_failed\} *)
