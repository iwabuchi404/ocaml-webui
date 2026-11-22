# ocaml-webui

[日本語版 README](README.ja.md)

An OCaml application runtime for desktop WebView UIs — typed commands,
structured errors, cooperative cancellation, and a single trace spanning
JavaScript → OCaml → workers.

> **Status: documented prototype (v0.1).** APIs are not frozen, and this is
> not yet a general-purpose framework. The typed-command generation path
> below is the intended way to use it; everything else is reference material
> or internals.

## What it is

You define Commands once — as a restricted-OCaml-syntax declaration
file (`commands.ml`; a JSON manifest input is also supported) — and
`ocaml-webui.command-gen` generates both sides of the bridge:

- OCaml: a `handlers` record (missing a handler is a **compile error**),
  codecs, and the registration list.
- TypeScript: typed `CommandDescriptor`s.
- A canonical JS client (`--emit-client`) implementing protocol v1 with
  `invokeCommand`, `cancelCommand`, `ProtocolError`, and `ApplicationError`.

One `traceId`/`requestId` follows each call through the JS invoke, OCaml
handler, worker domains, and external processes — one unified trace, not
per-layer logs.

## Quickstart

```bash
opam switch create . 5.4.1
opam install . --deps-only   # or pin per below
cd examples/typed-hello/web && npm ci && cd ../..
opam exec -- dune exec examples/typed-hello/bin/main.exe
```

`examples/typed-hello` demonstrates the full intended path:

| Command       | Shows                                              |
|---------------|----------------------------------------------------|
| `hello.ping`  | sync ATD Command, typed validation errors           |
| `work.count`  | async Command on a worker domain, JS cancel, timeout watchdog |
| `trace.recent`| raw_json Command reading the unified trace ring buffer |

`examples/minimal` is the same boundary with no npm and no code generation
— a hand-built protocol v1 envelope calling a passthrough codec. Read it
to see the wire shape; don't copy it for real apps.

To consume as a library, see [docs/getting-started.md](docs/getting-started.md).
Input formats: [docs/commands-manifest.md](docs/commands-manifest.md) (JSON manifest) and [docs/getting-started.md](docs/getting-started.md) (`commands.ml` declarations, used by `examples/typed-hello`).

## Platform support

| Platform | Backend   | Status                                  |
|----------|-----------|-----------------------------------------|
| Windows 10/11 | WebView2 | Verified; concurrent windows supported |
| Linux (Ubuntu 24.04 / WSL2) | WebKitGTK 4.1 | Verified; **one live window at a time**, `Window.create` must run on the process initial thread |
| Linux (non-WSL) | WebKitGTK 4.1 | Expected to work; not yet gated         |
| macOS    | —         | Not implemented                         |

## Public libraries

| Library                    | Purpose                                                        |
|----------------------------|----------------------------------------------------------------|
| `ocaml-webui.raw`          | Owned native WebView binding: window lifecycle, bindings, calls |
| `ocaml-webui.bridge-atd`   | Typed Command bridge — the main path                            |
| `ocaml-webui.async`        | Domain-based async work, cancellation tokens, parallel results  |
| `ocaml-webui.trace`        | Unified trace events + ring buffer                              |
| `ocaml-webui.exec`         | One-shot external process execution (timeout/cancel/limits)     |
| `ocaml-webui.worker`       | Persistent supervised NDJSON workers                            |
| `ocaml-webui.resource`     | Lifecycle-scoped resource management                            |
| `ocaml-webui.command-schema` | ATD schema shared by spikes; reference                        |
| `ocaml-webui.bridge-baseline` | Handwritten bridge — **reference/comparison only**, not the recommended path |
| `ocaml-webui.command-gen`  | Executable: manifest → OCaml + TS codegen                       |

## Repository layout

```
lib/            public libraries
js/webui_client.ts   canonical TS client (emitted by --emit-client)
tool/command_gen/    manifest code generator
test/         headless unit/integration tests (dune runtest)
spikes/       interactive WebView probes (dune exec)
examples/     user-facing samples (minimal, typed-hello)
docs/         design docs and references
```

## Installing with opam (git pin)

> **Important:** `opam pin add <pkg> git+https://...` does **not** initialize
> git submodules. `vendor/webview` (upstream headers required by the C++
> stubs) is a submodule, so a plain URL pin fails to build. Clone with
> `--recurse-submodules` and pin the local path instead — this is the
> recommended flow for early adopters.

```bash
git clone --recurse-submodules https://github.com/iwabuchi404/ocaml-webui.git
cd ocaml-webui
opam switch create . 5.4.1
opam pin add ocaml-webui .
opam install ocaml-webui
```

Consumers of only the OCaml libraries do not need node; the esbuild path is
required only to build `examples/typed-hello` and the TS probes.

## Prerequisites

### Windows

- Windows 10 or 11 with the WebView2 runtime
- opam 2.5 or later, project-local OCaml 5.4.1 switch
- dune and the matching MinGW-w64 C++ toolchain
  (`opam install dune yojson conf-c++ conf-mingw-w64-g++-x86_64`)

### Linux portability verification

- OCaml 5.4.x and Dune 3.18 or later
- Yojson 3.0 or later
- a C++14 compiler and `pkg-config`
- GTK 3 and WebKitGTK 4.1 development packages

On Ubuntu 24.04 / WSL2:

```bash
sudo apt update
sudo apt install -y build-essential pkg-config opam \
  libgtk-3-dev libwebkit2gtk-4.1-dev
```

## Development / probes

Headless tests run via `dune runtest` without a display. Probes that open
real WebView windows run manually:

```powershell
opam exec -- dune build @all
opam exec -- dune exec test/raw/lifecycle_probe.exe
opam exec -- dune exec test/raw/dispatch_probe.exe
opam exec -- dune exec test/raw/binding_probe.exe
opam exec -- dune exec test/raw/window_close_stress.exe -- --iterations 20
opam exec -- dune exec test/raw/multi_window_stress.exe -- --cycles 10 --dispatches 40
opam exec -- dune exec test/raw/pending_call_stress.exe -- --cycles 10 --calls 48
opam exec -- dune exec test/raw/abnormal_cleanup_probe.exe
opam exec -- dune exec test/raw/native_close_probe.exe
opam exec -- dune exec test/raw/resource_safety_probe.exe
opam exec -- dune exec test/bridge_atd/install_probe.exe
opam exec -- dune runtest test/bridge_baseline
```

The async Command probe exercises `define_async` end to end — worker-domain
execution, JS cancel, OCaml/JS timeouts, close-while-pending — against a
real WebView2 window:

```powershell
opam exec -- dune exec spikes/async-command/main.exe
```

Phase spikes (kept as evidence):

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
opam exec -- dune exec spikes/phase1-window-close/main.exe
opam exec -- dune exec spikes/phase2-handwritten-bridge/main.exe
opam exec -- dune exec spikes/phase3-atd-command/main.exe   # requires npm ci in web/phase3-atd-command/
```

The resource-safety probe deliberately finalizes one live Window to verify
leak detection and may emit a backend cleanup warning while still exiting
successfully. WSLg may emit EGL/Zink fallback warnings that do not affect
the result.

## Design docs

- [`Webui_raw`: OCaml WebView raw binding design](docs/webui-raw-binding-design.md)
- [`Webui_raw`: OCaml WebView raw binding設計（日本語）](docs/webui-raw-binding-design.ja.md)
- [`Webui_raw` implementation status（日本語）](docs/webui-raw-implementation-status.ja.md)
- [Handwritten bridge baseline design（日本語）](docs/handwritten-bridge-baseline.ja.md)
- [Command SSOT Phase 0 inventory（日本語）](docs/command-ssot-phase0-inventory.ja.md)
- [Dependency provenance](docs/dependencies.md)
