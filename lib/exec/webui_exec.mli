(** One-shot external process execution: spawn, feed stdin, capture
    stdout/stderr, enforce a deadline and cancellation, kill and reap.

    Complements {!Webui_worker} (persistent multiplexed NDJSON workers):
    [run] is for spawn-communicate-reap commands such as CLI invocations.

    Invariants:
    - argv is passed to the OS directly; no shell is involved.
    - the deadline and cancellation cover the whole operation, including a
      blocked stdin write.
    - on timeout/cancel/output-limit the direct child is killed and reaped
      before [run] returns; owned pipes and I/O domains are cleaned up.
    - a descendant process inheriting the child's pipes cannot keep [run]
      blocked forever: reader cleanup is bounded. *)

type exit_status =
  | Exited of int
  | Signaled of int
  | Stopped of int

type completed = {
  status : exit_status;
  stdout : string;
  stderr : string;
  duration_ms : float;
}

type partial = { stdout : string; stderr : string }

type error =
  | Spawn_failed of string
  | Timeout of partial
  | Cancelled of partial
  | Output_exceeded of partial
  | Io_error of string

val run :
  argv:string list ->
  ?stdin:string ->
  ?timeout_ms:int ->
  ?token:Webui_async.cancellation_token ->
  ?max_output_bytes:int ->
  ?trace:Webui_trace.sink ->
  ?trace_id:string ->
  unit ->
  (completed, error) result
(** Runs [argv.(0)] with the remaining argv elements, feeds [~stdin]
    (then closes stdin so the child sees EOF — also when omitted),
    and captures stdout and stderr into separate buffers.

    - [~timeout_ms]: deadline from the start of [run]; on expiry the child
      is killed and [Error (Timeout partial)] is returned with the output
      collected so far.
    - [~token]: cooperative cancellation; on cancel the child is killed
      and [Error (Cancelled partial)] is returned.
    - [~max_output_bytes]: combined stdout+stderr cap (default 16 MiB);
      on excess the child is killed and
      [Error (Output_exceeded partial)] is returned.
    - [~trace] / [~trace_id]: emits exec_* events into the sink, linked to
      the parent command's trace when a trace id is given.

    A non-zero exit code is NOT an error — it is reported as
    [Ok {status = Exited n; _}] because its meaning is application
    dependent. *)
