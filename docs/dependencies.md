# Dependency provenance

Date: 2026-07-19

This document records the native and build dependencies used by the Windows
implementation. Project licensing has not yet been selected; dependency
licenses remain governed by their respective license files.

## Upstream webview

- Project: `webview/webview`
- Repository: <https://github.com/webview/webview>
- API version: `0.12.0`
- Pinned revision: `0.12.0-55-gcbbdee4`
- Commit: `cbbdee44afff22867de9fd88a9fc8350d9bdd399`
- Local path: `vendor/webview`
- License: MIT (`vendor/webview/LICENSE`)
- Role: pinned C/C++ WebView abstraction used directly by `Webui_raw`

The project owns the OCaml FFI, lifecycle, dispatch queue, callback roots, and
response state. It does not fork or reimplement the WebView backend.

The released `0.12.0` commit was evaluated first, but its Windows WebView2
environment creation loop could stall indefinitely in the local MinGW setup.
The pinned post-release revision contains upstream's bounded retry delay fix
(`922a796`) while retaining the 0.12 C API. The exact commit is recorded so the
dependency remains reproducible despite the lack of a newer upstream release.

## Microsoft WebView2 SDK headers

- Version: `1.0.1150.38`
- Local path: `vendor/webview2-sdk-1.0.1150.38`
- License: `vendor/webview2-sdk-1.0.1150.38/LICENSE.txt`
- Role: header required by the pinned webview 0.12 Windows backend

The Microsoft Edge WebView2 Runtime is a system prerequisite and is not
distributed by this repository.

## owebview reference

- Project: `korkorran/owebview`
- Commit: `57e78514bd9e4f32dcd99f1e8cacece69c25327c`
- Local path: `vendor/owebview`
- License: `vendor/owebview/LICENSE`
- Role: reference implementation during `Webui_raw` migration

owebview is not the long-term binding dependency. The Phase 1 spikes still
copy its stub temporarily; Step 7 removes that dependency after the owned
binding passes the same probes.

## Windows build toolchain

- OCaml: `5.4.x`, project-local opam switch
- Dune: `>= 3.18`
- C compiler: MinGW-w64 matching the OCaml switch
- C++ compiler package: `conf-mingw-w64-g++-x86_64`
- Required Windows libraries: `advapi32`, `ole32`, `shell32`, `shlwapi`,
  `user32`, and `version`

The selected compiler, include paths, and link flags are encoded by the shared
`lib/raw/dune` build rule. The older focused spikes retain their local build
configuration only as historical verification artifacts.
