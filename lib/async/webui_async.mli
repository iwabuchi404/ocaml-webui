(** Minimal concurrency primitives shared by the bridge and applications.

    Uses [Domain.spawn] for worker execution (no Eio/Lwt). Cancellation is
    cooperative: a token is a flag the worker checks at its own checkpoints;
    nothing forcibly interrupts a running handler. *)

type cancel_reason = [ `Js_cancel | `Timeout | `Window_close ]

type cancellation_token

val token :
  ?external_check:(unit -> cancel_reason option) -> unit -> cancellation_token
(** [external_check] is consulted lazily by [is_cancelled] when the local flag
    is not yet set. The bridge uses it to propagate window-close cancellation
    via [Webui_raw.Call.is_cancelled]. *)

val cancel : cancellation_token -> cancel_reason -> unit
val is_cancelled : cancellation_token -> bool
val cancel_reason : cancellation_token -> cancel_reason option

type 'a task

val spawn : (unit -> 'a) -> 'a task
val await : 'a task -> 'a
(** [await] joins the domain. Worker exceptions are re-raised in the caller. *)

val detach : (unit -> 'a) -> unit
(** Fire-and-forget [spawn]; the returned task is discarded. *)

val parallel : (unit -> 'a) list -> 'a list
(** Spawns all thunks and joins them in order. The first worker exception is
    re-raised after all domains have been joined. *)

val parallel_results : (unit -> 'a) list -> ('a, exn) result list
(** Like [parallel] but captures per-worker exceptions as [Error exn],
    preserving partial failures. *)

val sleep_ms : int -> unit
