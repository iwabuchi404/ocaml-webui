(** Unified trace events for the JS -> OCaml -> Worker request lifecycle.

    An [event] is a flat record keyed by trace/request identity. Spans are
    deliberately not modelled: cancel, timeout, and window-close paths may
    never produce a matching end event, so durations are carried as fields
    on completion events instead. *)

type event = {
  name : string;  (** Event kind, e.g. ["invoke_received"]. *)
  ts : float;  (** [Unix.gettimeofday] at emission. *)
  trace_id : string;  (** Empty when the envelope carried none. *)
  request_id : string;  (** Empty when the envelope carried none. *)
  command : string;  (** Empty when unknown (e.g. decode failure). *)
  data : (string * Yojson.Safe.t) list;  (** Event-specific fields. *)
}

type sink = event -> unit

val make :
  name:string ->
  ?trace_id:string ->
  ?request_id:string ->
  ?command:string ->
  ?data:(string * Yojson.Safe.t) list ->
  unit ->
  event

val emit : sink option -> event -> unit
(** No-op when the sink is [None]; bridges call this unconditionally so
    event construction can be skipped cheaply at the call site. *)

val to_yojson : event -> Yojson.Safe.t
val to_json_string : event -> string
val stderr_sink : sink
(** Emits one JSON object per line on stderr, same shape as the bridge's
    former ad-hoc exception logs. *)

val ring_buffer : capacity:int -> sink * (unit -> event list)
(** A thread-safe bounded buffer: the sink keeps at most [capacity] newest
    events, the snapshot returns them oldest-first. Applications can read
    it from OCaml or expose it through their own debug Command. *)
