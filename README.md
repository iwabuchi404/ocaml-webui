# ocaml-webui

OCaml applications with a typed, traceable WebView boundary.

The repository now contains a directly owned `Webui_raw` Windows implementation
at the API-freeze-candidate stage. All Phase 1 spikes run on this binding;
`owebview` remains reference material only.

## Design

- [`Webui_raw`: OCaml WebView raw binding design](docs/webui-raw-binding-design.md)
- [`Webui_raw`: OCaml WebView raw binding設計（日本語）](docs/webui-raw-binding-design.ja.md)
- [`Webui_raw` implementation status（日本語）](docs/webui-raw-implementation-status.ja.md)
- [Dependency provenance](docs/dependencies.md)

## Prerequisites

- Windows 10 or 11 with the WebView2 runtime
- opam 2.5 or later
- the project-local OCaml switch (`opam switch create . 5.4.1`)
- dune and the matching MinGW-w64 C++ toolchain
  (`opam install dune conf-c++ conf-mingw-w64-g++-x86_64`)

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
```

The resource-safety probe deliberately finalizes one live Window to verify leak
detection. It may emit a WebView2 cleanup warning while still exiting with
success. Use `--iterations 100` for the slower close soak test.

The migrated Phase 1 evidence can be rerun with:

```powershell
opam exec -- dune exec spikes/phase1-threading/main.exe -- --auto
opam exec -- dune exec spikes/phase1-domain-dispatch/main.exe -- --auto
opam exec -- dune exec spikes/phase1-window-close/main.exe
```
