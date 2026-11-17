(** Resource registry: owned objects with a release function and a scope.

    A resource is anything with an explicit lifecycle -- a worker process,
    a file handle, a subscription, a temporary file. Registration returns a
    handle; {!release} runs the release function exactly once.
    {!revoke_scope} releases every resource in a scope in reverse
    registration order, matching the natural teardown of dependencies.

    Scopes:

    - [App]: released only via {!release} / {!revoke_scope App} (app exit).
    - [Named s]: an application-defined group; useful for per-feature
      cleanup and tests.
    - [Window w]: released automatically when the window is destroyed via
      [Webui_raw.Window.on_destroy]. The callback runs after a successful
      native teardown on the owner thread.

    [Webui_worker.spawn ~scope] registers workers automatically, so scope
    revocation kills them without extra wiring. *)

type scope =
  | App
  | Named of string
  | Window of Webui_raw.Window.t

type resource

type scope_info = [ `App | `Named of string | `Window ]

type info = {
  id : int;
  kind : string;
  name : string;
  scope : scope_info;
  registered_at : float;
}

val set_trace : Webui_trace.sink option -> unit
(** Optional sink for [resource_registered] / [resource_released] /
    [resource_revoked] events. *)

val register :
  kind:string ->
  name:string ->
  ?scope:scope ->
  release:(unit -> unit) ->
  unit ->
  resource
(** Default [scope] is [App]. For [Window w] scopes, an [on_destroy]
    callback is registered so the resource releases itself at window
    teardown. *)

val release : resource -> unit
(** Idempotent: runs the release function once; later calls are no-ops. *)

val revoke_scope : scope -> int
(** Releases every live resource in [scope] in reverse registration order
    and returns how many were released. *)

val snapshot : unit -> info list
val leak_count : unit -> int
(** Number of registered (unreleased) resources at call time. *)
