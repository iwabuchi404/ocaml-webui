# ocaml-webui

OCaml applications with a typed, traceable WebView boundary.

The repository now contains the first directly owned `Webui_raw` implementation
through the binding and one-shot call stage. The earlier Phase 1 spikes are
retained as technical evidence and migration inputs.

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
opam exec -- dune exec test/raw/window_close_stress.exe -- --iterations 100
```
