# ocaml-webui

OCaml applications with a typed, traceable WebView boundary.

The repository now contains a directly owned `Webui_raw` implementation at the
cross-platform API-freeze-candidate stage. Windows/WebView2 and Linux/
WebKitGTK use the same OCaml API. All Phase 1 spikes run on this binding;
`owebview` remains reference material only.

## Design

- [`Webui_raw`: OCaml WebView raw binding design](docs/webui-raw-binding-design.md)
- [`Webui_raw`: OCaml WebView raw binding設計（日本語）](docs/webui-raw-binding-design.ja.md)
- [`Webui_raw` implementation status（日本語）](docs/webui-raw-implementation-status.ja.md)
- [Handwritten bridge baseline design（日本語）](docs/handwritten-bridge-baseline.ja.md)
- [Dependency provenance](docs/dependencies.md)

## Prerequisites

### Windows

- Windows 10 or 11 with the WebView2 runtime
- opam 2.5 or later
- the project-local OCaml switch (`opam switch create . 5.4.1`)
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

The build discovers platform flags automatically. Linux compile, lifecycle,
dispatch, binding, native-close, shutdown stress, and all three Phase 1 probes
pass under Ubuntu 24.04 on WSL2/WSLg. A regular non-WSL Ubuntu run remains the
final Linux portability gate.

The current Linux backend requires `Window.create` on the process initial
thread and supports one live Window at a time. A second live Window or a create
from another Domain returns `Create/Invalid_state`; a new Window may be created
after explicit destroy. Windows continues to support concurrent Windows on
separate owner Domains.

Clone with submodules:

```powershell
git clone --recurse-submodules <repository-url>
```

Build every project-owned target:

```powershell
opam exec -- dune build @all
```

Focused non-interactive tests:

```powershell
opam exec -- dune runtest test/raw
opam exec -- dune exec test/raw/lifecycle_probe.exe
opam exec -- dune exec test/raw/dispatch_probe.exe
opam exec -- dune exec test/raw/binding_probe.exe
opam exec -- dune exec test/raw/window_close_stress.exe -- --iterations 20
opam exec -- dune exec test/raw/multi_window_stress.exe -- --cycles 10 --dispatches 40
opam exec -- dune exec test/raw/pending_call_stress.exe -- --cycles 10 --calls 48
opam exec -- dune exec test/raw/abnormal_cleanup_probe.exe
opam exec -- dune exec test/raw/native_close_probe.exe
opam exec -- dune exec test/raw/resource_safety_probe.exe
opam exec -- dune runtest test/bridge_baseline
```

The resource-safety probe deliberately finalizes one live Window to verify leak
detection. It may emit a backend cleanup warning while still exiting with
success. WSLg may also emit EGL/Zink fallback warnings; these are distinct from
GTK critical warnings and do not change the probe result. Use `--iterations
100` for the slower close soak test.

The migrated Phase 1 evidence can be rerun with:

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
opam exec -- dune exec spikes/phase1-window-close/main.exe
```

The Phase 2 handwritten Command bridge comparison baseline can be rerun with:

```powershell
opam exec -- dune exec spikes/phase2-handwritten-bridge/main.exe
```

It exercises one manually coded `text.analyze` Command through one native
binding, including request/trace identity, structured errors, async Domain
completion, duplicate response prevention, close cancellation, and root
cleanup. It is intentionally named `bridge-baseline`; the later ATD-generated
bridge will replace its manual codecs and client boilerplate.
