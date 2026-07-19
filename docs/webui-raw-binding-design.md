# Webui_raw: OCaml WebView raw binding design

Status: Draft for implementation

Date: 2026-07-19

Target: Windows / OCaml 5.4 / WebView2 first

[日本語版](webui-raw-binding-design.ja.md)

## 1. Name and position

The component is named **Webui_raw**.

- OCaml module: `Webui_raw`
- Dune public library name: `ocaml-webui.raw`
- Source directory: `lib/raw/`
- Native stub prefix: `ocaml_webui_raw_*`

The name deliberately includes `raw`. Application code should eventually use
the higher-level `Webui` runtime and Typed Command API instead of depending on
this library directly.

`Webui_raw` replaces the OCaml binding supplied by owebview. It does **not**
replace the browser engine or reimplement WebView2. The dependency chain is:

```text
Application / Typed Command runtime
                |
                v
            Webui_raw       <- owned by this project
                |
                v
  upstream webview C/C++ API <- pinned dependency
                |
                v
       Windows WebView2 Runtime
```

## 2. Why the binding must be owned now

Phase 1 established the following facts on Windows/WebView2:

1. A binding callback shares the native UI thread and blocks native UI work.
2. A separate OCaml Domain can return through a short UI dispatch closure.
3. A response requires one-shot ownership to prevent duplicate completion.
4. Window close must stop new responses, join workers, and precede destroy.
5. Binding and dispatch closures require explicit GC-root ownership.
6. owebview's trampolines released the runtime lock before `CAMLdrop`, causing
   a reproducible Windows access violation `0xC0000005` during Domain dispatch.
7. owebview's build skeleton does not support the Windows toolchain used here.

The current spikes patch a generated copy of owebview's C++ stub. That was the
right way to isolate a hypothesis, but it is not an acceptable production
dependency boundary. All later bridge, cancellation, and trace work would rest
on this safety-critical layer, so ownership moves here before the handwritten
bridge baseline.

## 3. Sources used as references

The implementation may reuse ideas, not the unsafe lifecycle assumptions, from:

- `vendor/owebview/lib/webview.mli`
- `vendor/owebview/lib/webview.ml`
- `vendor/owebview/lib/webview_stubs.cpp`
- `vendor/owebview/lib/dune`
- `vendor/owebview/vendor/webview.h` (webview 0.12)
- `spikes/phase1-threading/`
- `spikes/phase1-domain-dispatch/`
- `spikes/phase1-window-close/`

owebview remains a reference-only submodule during migration. After feature
parity and regression tests pass, it is removed as a build dependency. The
upstream `webview` library is then pinned directly, with its license and exact
revision recorded.

## 4. Goals

`Webui_raw` must provide a small, reviewable, Windows-first binding with these
properties:

- explicit UI-thread ownership;
- explicit and observable window lifecycle;
- no WebView access after closing/destroy;
- thread-safe worker-to-UI dispatch;
- one-shot JavaScript call completion;
- deterministic binding, dispatch, and pending-call root release;
- no OCaml exception crossing a C callback boundary;
- typed native errors rather than generic `Failure` strings;
- explicit shutdown, with no native destruction from a GC finalizer;
- diagnostics that can prove root and queue invariants in tests;
- a build that succeeds from the repository root on the supported toolchain.

## 5. Non-goals

The raw binding does not implement:

- Typed Command schemas or ATD generation;
- JSON parsing, validation, or application error codecs;
- Call ID / Trace ID policy above the native JavaScript call ID;
- Eio, Lwt, or another asynchronous runtime integration;
- worker-process supervision;
- capability or permission checks;
- resource URLs or a custom WebView2 scheme;
- a general WebView2 COM wrapper;
- macOS and Linux support in the first implementation;
- automatic native destruction from a GC finalizer.

These belong above the raw binding or in later platform-specific work.

## 6. Required feature set

### 6.1 Required for the first usable version

| Area | Functions / behavior |
|---|---|
| Lifecycle | create, run, request close, destroy, inspect state |
| Window | set title, set size |
| Content | navigate, set HTML, init script, eval script |
| Binding | bind, unbind, copy request data, track binding lifetime |
| Call response | resolve JSON, reject JSON, cancel, reject duplicates |
| Dispatch | enqueue from any registered OCaml Domain, run on UI thread |
| Error | typed operation and native error code |
| Version | report pinned upstream webview version |
| Diagnostics | state, binding roots, dispatch roots, pending calls |

### 6.2 Restricted or deferred API

- `get_window` and `get_native_handle` live under `Webui_raw.Unsafe_platform`.
- Embedding into an existing native window is deferred.
- Arbitrary user data on native callbacks is internal only.
- Direct `webview_return` by string ID is not exposed. Callers receive a
  one-shot `Call.t` token instead.
- Direct native calls from worker Domains are rejected; workers use dispatch.

## 7. Proposed OCaml API

This is a design contract, not final syntax.

```ocaml
module Error : sig
  type code =
    | Missing_dependency
    | Cancelled
    | Invalid_state
    | Invalid_argument
    | Duplicate
    | Not_found
    | Unspecified
    | Unknown of int

  type operation =
    | Create | Run | Request_close | Destroy
    | Set_title | Set_size | Navigate | Set_html | Init | Eval
    | Bind | Unbind | Dispatch | Respond

  type t = {
    operation : operation;
    code : code;
    message : string;
  }
end

module Window : sig
  type t

  type state =
    | Created
    | Running
    | Closing
    | Stopped
    | Destroyed

  type size_hint = Initial | Minimum | Maximum | Fixed
  type config = { debug : bool }

  val create : config -> (t, Error.t) result
  val state : t -> state
  val run : t -> (unit, Error.t) result
  val request_close : t -> (unit, Error.t) result
  val destroy : t -> (unit, Error.t) result

  val set_title : t -> string -> (unit, Error.t) result
  val set_size :
    t -> width:int -> height:int -> size_hint -> (unit, Error.t) result
  val navigate : t -> string -> (unit, Error.t) result
  val set_html : t -> string -> (unit, Error.t) result
  val init : t -> string -> (unit, Error.t) result
  val eval : t -> string -> (unit, Error.t) result

  val dispatch : t -> (unit -> unit) -> (unit, Error.t) result
end

module Call : sig
  type t

  type completion =
    [ `Sent
    | `Already_completed
    | `Window_closing ]

  val request_json : t -> string
  val resolve_json : t -> string -> completion
  val reject_json : t -> string -> completion
  val cancel : t -> completion
end

module Binding : sig
  type t

  val create :
    Window.t ->
    name:string ->
    (Call.t -> unit) ->
    (t, Error.t) result

  val remove : t -> (unit, Error.t) result
end

module Diagnostics : sig
  type snapshot = {
    window_state : Window.state;
    binding_roots : int;
    dispatch_roots : int;
    pending_calls : int;
    queued_dispatches : int;
  }

  val snapshot : Window.t -> snapshot
end
```

The first version uses JSON strings at this boundary. JSON validity and typed
codec behavior belong to the higher-level bridge. `Call.t` still owns response
state so an invalid caller cannot respond twice or respond after shutdown.

## 8. Layering inside Webui_raw

```text
webui_raw.mli
  Public low-level OCaml contract

webui_raw.ml
  Typed errors, state checks, result conversion, safe wrappers

webui_raw_native.ml
  Private external declarations only

webui_raw_stubs.cpp
  C++ context, runtime lock, roots, upstream webview calls

platform/windows/
  WebView2 headers, link flags, Windows-only diagnostics/test helpers
```

The public module does not expose native pointers or `external` declarations.
All unsafe calls stay in the private native module.

## 9. Native context and ownership

Every `Window.t` owns a native context conceptually equivalent to:

```text
window_context
  native webview handle
  lifecycle state
  UI owner thread identity
  mutex
  active bindings by name
  pending calls by native call ID
  dispatch queue
  native wakeup scheduled flag
  diagnostic counters
```

The context is stored behind an abstract OCaml custom block. The native WebView
is destroyed only by explicit `Window.destroy` on the owner thread.

The custom-block finalizer must never invoke WebView APIs because it can run on
the wrong Domain/thread. After explicit destroy it may free the inert context.
If a live context reaches finalization, debug builds report a lifecycle leak;
they do not attempt unsafe automatic cleanup.

## 10. Threading contract

### 10.1 UI-owner-only operations

The following must run on the thread that created the window:

- run and destroy;
- binding creation/removal;
- title, size, navigation, HTML, init, and eval;
- draining dispatch work and sending JavaScript responses.

The native context records the owner thread and rejects invalid calls in debug
and test builds. The production API returns `Invalid_state` rather than relying
on undocumented backend behavior.

### 10.2 Operations allowed from worker Domains

- `Window.dispatch`;
- `Call.resolve_json`, `Call.reject_json`, and `Call.cancel` because they first
  claim one-shot ownership and then enqueue UI work;
- `Window.request_close`, implemented as a thread-safe request rather than a
  direct arbitrary-thread WebView call.

No other native operation is callable from a worker Domain.

### 10.3 Runtime lock rules

The C++ implementation follows these invariants:

1. `webview_run` releases the OCaml runtime before blocking and reacquires it
   before allocating, raising, or returning to OCaml.
2. A WebView callback acquires the runtime before touching any OCaml value.
3. `CAMLdrop` executes **before** `caml_release_runtime_system`.
4. A root is registered and removed only while the runtime is held.
5. `caml_callback*_exn` is used at C callback boundaries; an OCaml exception
   never unwinds through C++ or WebView.
6. If a backend invokes a callback on a thread unknown to OCaml, the thread is
   registered before acquiring the runtime and unregistered afterward.
7. No C++ RAII object with a required destructor remains live across an OCaml
   raise, because OCaml exceptions may bypass C++ stack unwinding.

## 11. Lifecycle state machine

```text
Created -------> Running -------> Closing -------> Stopped -------> Destroyed
   |                |                 ^               |
   |                +-- close/error --+               |
   +---------------- setup failure -------------------+
```

Rules:

- Configuration operations are allowed in `Created` or `Running` as specified.
- New bindings and dispatches are rejected once state becomes `Closing`.
- `run` returning changes `Running` or `Closing` to `Stopped`.
- Pending calls and queued dispatches are cancelled before destroy.
- Destroy is allowed from `Created` after setup failure or from `Stopped`.
- Destroy is idempotent at the OCaml API: a second call reports `Destroyed`
  without invoking the native destructor again.
- Native handles are cleared before the state becomes externally `Destroyed`.

The C++ context is the authority for native safety state. Higher runtime layers
may mirror it, but cannot bypass it.

## 12. Call response state machine

```text
Pending ---> Dispatch_queued ---> Responded
   |               |
   +-------------> Cancelled
   |
   +-------------> Failed
```

Claiming a response and checking the Window state must be one synchronized
transition. The Phase 1 pattern of reading lifecycle and dispatching in two
separate operations is not sufficient because close can occur between them.

Required behavior:

- exactly one resolve, reject, cancel, or failure wins;
- duplicate completion returns `Already_completed` without native work;
- closing wins over a response that has not yet been queued;
- queued responses can be cancelled during shutdown before native destroy;
- a dispatch enqueue failure moves the call to `Failed` and releases its root;
- a JavaScript response is emitted only on the UI owner thread.

## 13. Dispatch design

Do not pass one independently allocated OCaml closure directly to every
upstream `webview_dispatch` call. That design makes queued closure ownership
ambiguous if the window closes before the native callback runs.

`Webui_raw` instead owns a per-window queue:

1. A worker registers the closure root and pushes a queue item under the
   context mutex.
2. At most one native UI wakeup is scheduled while the queue is non-empty.
3. The wakeup receives the stable window context, not an individual closure.
4. The UI trampoline swaps/drains accepted items without holding the mutex
   while user code runs.
5. Each closure root is removed exactly once after execution or cancellation.
6. Closing rejects new items and cancels queued items before destroy.

No mutex is held while calling an OCaml closure or a native API that can call
back, raise, or block. This avoids lock inversion and callback deadlocks.

## 14. Binding and callback design

Each binding owns:

- the window context;
- its unique name;
- one registered generational global root for the OCaml handler;
- an active/removed state.

The binding trampoline:

1. acquires/registers the OCaml runtime as required;
2. copies native call ID and request JSON immediately;
3. creates a pending `Call.t` owned by the Window;
4. invokes the OCaml handler with `caml_callback_exn`;
5. converts an uncaught handler exception to an internal failed-call event;
6. drops local roots before releasing the runtime.

Unbind and destroy remove native bindings before releasing their OCaml roots.
Root removal is idempotent and represented in diagnostics.

The raw layer reports callback exceptions to a configurable diagnostic hook.
The higher bridge decides the stable application error schema.

## 15. Error model

The upstream webview 0.12 errors map to `Error.code`:

| Native code | OCaml code |
|---|---|
| `WEBVIEW_ERROR_MISSING_DEPENDENCY` | `Missing_dependency` |
| `WEBVIEW_ERROR_CANCELED` | `Cancelled` |
| `WEBVIEW_ERROR_INVALID_STATE` | `Invalid_state` |
| `WEBVIEW_ERROR_INVALID_ARGUMENT` | `Invalid_argument` |
| `WEBVIEW_ERROR_DUPLICATE` | `Duplicate` |
| `WEBVIEW_ERROR_NOT_FOUND` | `Not_found` |
| `WEBVIEW_ERROR_UNSPECIFIED` | `Unspecified` |
| any future integer | `Unknown n` |

The FFI may raise one private internal exception to escape a C primitive, but
the public OCaml wrapper catches it and returns `(value, Error.t) result`.
Generic `Failure` is not part of the public contract.

Every C++ exception is caught at an `extern "C"` boundary and converted while
the runtime is held. No C++ exception crosses into OCaml or WebView.

## 16. Build and dependency policy

Initial support is deliberately Windows-only.

- OCaml: 5.4.x project-local opam switch
- Dune: current project version or newer compatible release
- C++: MinGW-w64 toolchain compatible with the OCaml switch
- Upstream webview: pinned direct revision corresponding to 0.12 initially
- WebView2 SDK header: version required by the pinned upstream webview
- WebView2 Runtime: system dependency checked at create time

The root build must not recursively build owebview examples or configuration.
A root Dune stanza marks reference/vendor sources as vendored or excluded.

The current known-good manual C++ object rule can bootstrap Windows support,
but the compiler must not remain an unexplained hard-coded executable. A small
configuration step records the selected C++ compiler and link libraries.

The repository gains an opam package definition that records OCaml/Dune build
dependencies. Native prerequisites and exact setup commands are documented.

## 17. Diagnostics and invariants

Debug/test builds expose a snapshot, not mutable internals. Required counters:

- active binding roots;
- queued/running dispatch roots;
- pending calls by state;
- lifecycle transitions;
- rejected post-close operations;
- callback exceptions;
- dispatch enqueue/drain/cancel counts.

Assertions in tests enforce:

- no root is registered or removed twice;
- no root remains after destroy;
- no user callback runs while the context mutex is held;
- no native call other than the permitted wakeup path comes from a worker;
- no dispatch is accepted after `Closing`;
- no call completes more than once;
- no native handle is used after it is cleared;
- destroy is invoked at most once.

Diagnostics are routed through a hook. The library does not write directly to
stdout in normal operation.

## 18. Source layout

```text
lib/
  raw/
    dune
    webui_raw.mli
    webui_raw.ml
    webui_raw_native.ml
    webui_raw_stubs.cpp
    platform/
      windows/
        dune
        webview2_config.ml

test/
  raw/
    state_machine_test.ml
    root_lifecycle_test.ml
    dispatch_stress.ml
    window_close_stress.ml

vendor/
  webview/                 # pinned direct upstream dependency
  webview2-sdk-<version>/

spikes/
  phase1-*                 # migrated to Webui_raw, retained as evidence
```

## 19. Seven-step implementation plan

### Step 1: Repository and dependency foundation

Deliverables:

- pin upstream `webview` directly;
- isolate/remove owebview from the normal Dune workspace;
- add root opam/build metadata;
- make `dune build @all` succeed before binding code is added;
- document compiler, WebView2 SDK, runtime, and license provenance.

Exit criterion: a clean checkout can run the root build without entering
owebview's examples or requiring undeclared OCaml libraries.

### Step 2: API skeleton and pure state machines

Deliverables:

- `Error`, `Window.state`, `Call` completion state, and private native API;
- pure unit tests for every valid and invalid transition;
- thread-affinity and result-returning API contracts in the `.mli`.

Exit criterion: state transition tests cover duplicate response, close-before-
response, response-before-close, setup failure, and double destroy.

### Step 3: Native context and basic window lifecycle

Deliverables:

- native context custom block;
- create, title, size, HTML/navigation, run, request close, and destroy;
- owner-thread checks and typed native error conversion;
- correct runtime release around `webview_run`;
- no callback or binding support yet.

Exit criterion: create/run/close/destroy works repeatedly, and setup failures
leave no native window or context leak.

### Step 4: Owned dispatch queue

Deliverables:

- per-window synchronized queue and single native wakeup;
- root ownership for queued closures;
- callback exception capture;
- queue rejection/cancellation during close;
- diagnostics for enqueue, drain, cancel, and roots.

Exit criterion: the Phase 1 threading dispatch probe uses `Webui_raw`; worker
dispatch and close races leave zero roots.

### Step 5: Binding and one-shot Call tokens

Deliverables:

- bind/unbind root registry;
- copied request JSON and abstract `Call.t`;
- resolve/reject/cancel state machine;
- structured callback-exception hook;
- no public raw response-by-ID API.

Exit criterion: Domain success, exception rejection, duplicate response, and
dispatch enqueue failure all finish once and release every root.

### Step 6: Shutdown and concurrency hardening

Deliverables:

- coordinated Closing -> Stopped -> Destroyed path;
- randomized close timing around response claiming and dispatch draining;
- concurrent pending calls and more than one Window;
- CPU-bound and allocation/GC stress;
- abnormal `run`/callback/dispatch failure cleanup.

Exit criterion:

- at least 100 randomized close iterations pass;
- queued-before-close and enqueue-during-close cases are observed explicitly;
- multiple pending calls cancel deterministically;
- diagnostics are zero after destroy;
- no crash, hang, duplicate completion, or post-destroy native access occurs.

### Step 7: Migration and freeze of the raw contract

Deliverables:

- all three Phase 1 spikes run against `Webui_raw` without patch scripts;
- owebview is removed as a build dependency;
- public `.mli`, lifecycle diagram, and supported-thread table are reviewed;
- the handwritten bridge baseline starts only after this gate.

Exit criterion: root build and focused runtime tests pass from a clean checkout,
and no code under `spikes/` copies or patches owebview stubs.

## 20. Test matrix

| Test | Required observation |
|---|---|
| Blocking callback | native UI dispatch waits; renderer result is recorded |
| Domain success | callback returns quickly; response runs on owner thread |
| Domain failure | exactly one reject; exception does not cross C boundary |
| Duplicate response | second completion is rejected without native work |
| Close before work ends | response cancels; worker joins; roots reach zero |
| Close while enqueueing | either queue ownership or close wins atomically |
| Close after queueing | queue drains or cancels before destroy, never leaks |
| Native enqueue failure | root rolls back and Call becomes Failed |
| CPU-bound Domain | UI remains operational under real multicore load |
| Allocation/GC stress | registered closures remain valid, then release |
| Concurrent calls | independent one-shot states and deterministic shutdown |
| Multiple Windows | lifecycle, roots, and dispatch remain window-scoped |
| Repeated create/destroy | no process growth, stale handle, or double destroy |

The automated close test randomizes timing rather than always closing 500 ms
into a 3000 ms task. Four successful deterministic runs are evidence for the
basic path, not sufficient evidence for the race boundary.

## 21. Risks and mitigations

### Upstream callback guarantees

Risk: a native dispatch callback may be queued while shutdown begins.

Mitigation: own the closure queue, pass only the stable context to the native
wakeup, stop new queue items at `Closing`, and drain/cancel before destroy.
Verify the pinned upstream behavior with stress tests before freeing context.

### OCaml 5 Domains and shared native registries

Risk: assumptions based on one global runtime lock are invalid with multiple
Domains.

Mitigation: UI-thread confinement for window/binding mutations, an explicit
mutex for the cross-Domain queue, and root operations only under the OCaml
runtime. Never treat runtime ownership as a C++ container mutex.

### Explicit destroy can be omitted

Risk: a forgotten destroy leaks a native window/context and registered roots.

Mitigation: provide higher-level `with_window`/application scope helpers later,
emit a debug lifecycle-leak diagnostic, and make root counts test-visible. Do
not trade a detectable leak for unsafe finalizer-thread destruction.

### Build portability

Risk: the known working MinGW object rule becomes an undocumented Windows-only
special case.

Mitigation: encode toolchain discovery and native prerequisites, keep platform
rules isolated, and defer macOS/Linux claims until their own runtime tests pass.

## 22. Open questions deliberately deferred

- Whether the higher runtime uses Eio, Lwt, or a minimal Domain scheduler.
- The stable structured application error schema.
- Vite/hot-reload integration and schema handshake.
- Whether custom schemes require descending to WebView2 COM APIs.
- macOS/Linux build and callback-thread behavior.
- Public exposure of platform-native handles.

None of these questions blocks ownership of the minimal safe Windows binding.

## 23. Decision summary

1. Build `Webui_raw` now, before the handwritten bridge baseline.
2. Own OCaml FFI, lifecycle, roots, dispatch queue, and one-shot Call tokens.
3. Continue using a pinned upstream `webview` implementation and WebView2.
4. Keep JSON/Typed Command/Trace/Eio/Lwt above or outside this layer.
5. Use explicit destroy; never destroy a native window from a GC finalizer.
6. Treat close versus response dispatch as a synchronized state transition.
7. Require clean root-build and randomized shutdown stress before Phase 2.

