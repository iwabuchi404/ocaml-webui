# docs index

Current specifications and usage guides vs. design plans and historical
records. Dates in filenames are plan-time, not implementation-time.

## Current reference

| Doc | Contents |
|---|---|
| [getting-started.md](getting-started.md) / [ja](getting-started.ja.md) | Consuming ocaml-webui: `commands.ml` → generated bridge |
| [commands-manifest.md](commands-manifest.md) / [ja](commands-manifest.ja.md) | JSON manifest fields (`--manifest` input, the shared IR) |
| [command-ssot-phase2-comparison.ja.md](command-ssot-phase2-comparison.ja.md) | Input-format comparison + the `commands.ml` declaration syntax actually implemented |
| [command-decl-compile-consideration.ja.md](command-decl-compile-consideration.ja.md) | Pending: making `commands.ml` compileable (Merlin/typecheck) — problem, options, trade-offs |
| [dependencies.md](dependencies.md) | Where each dependency comes from |
| [webui-raw-binding-design.md](webui-raw-binding-design.md) / [ja](webui-raw-binding-design.ja.md) | `Webui_raw` lifecycle/state-machine design |

## Plans and history

Kept as design rationale; not current specifications.

| Doc | Contents |
|---|---|
| [webui-raw-binding-design.ja.md](webui-raw-binding-design.ja.md) | Raw binding design draft |
| [webui-raw-implementation-status.ja.md](webui-raw-implementation-status.ja.md) | Raw binding status as of 2026-07-20 — predates async/trace/worker/resource/exec layers |
| [handwritten-bridge-baseline.ja.md](handwritten-bridge-baseline.ja.md) | Hand-written bridge baseline (superseded by generated path) |
| [phase0-packaging.ja.md](phase0-packaging.ja.md) / [phase0-results.ja.md](phase0-results.ja.md) | opam packaging plan + results |
| [command-ssot-phase0-inventory.ja.md](command-ssot-phase0-inventory.ja.md) | Pre-generation duplication baseline |
| [async-timeout-cancel-plan.ja.md](async-timeout-cancel-plan.ja.md) | Async/cancel/timeout design |
| [trace-layer-plan.ja.md](trace-layer-plan.ja.md) | Unified trace design |
| [worker-layer-plan.ja.md](worker-layer-plan.ja.md) | Worker layer design |
| [resource-layer-plan.ja.md](resource-layer-plan.ja.md) | Resource layer design |
| [exec-layer-plan.ja.md](exec-layer-plan.ja.md) | One-shot process exec design |
| [review-scope-phase5-6.ja.md](review-scope-phase5-6.ja.md) | Worker+Resource review scope |
| [atd-command-ssot-execution-plan.ja.md](atd-command-ssot-execution-plan.ja.md) | ATD SSOT execution plan |
| [atd-command-ssot-finalization-plan.ja.md](atd-command-ssot-finalization-plan.ja.md) | ATD SSOT finalization plan |
| [atd-command-ssot-implementation-review.ja.md](atd-command-ssot-implementation-review.ja.md) | First review (issues fixed) |
| [atd-command-ssot-followup-review.ja.md](atd-command-ssot-followup-review.ja.md) | Follow-up review (issues fixed) |
| [atd-command-ssot-results.ja.md](atd-command-ssot-results.ja.md) | ATD SSOT results |
