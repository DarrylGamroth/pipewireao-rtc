# Independent REVOLT Julia package — 2026-10-08

Baseline: shared root-layout commit `3101c5a`, on
`codex/julia-package-root-20261008`. Instrument destination: independent sibling
`REVOLTRTC.jl`, branch `codex/revolt-package-split-20261008`. The source extraction
preserves the shared package name and UUID. REVOLT owns its graphs, HIL resources,
recipes, HEART adapters and scientific environments; it has no GUI dependency.

## Implemented boundary

- Shared native clients, acquisition driving, parameter descriptions, file-copy
  helpers and one-shot systemd/session tools remain in `PipeWireAODeployment`.
- REVOLT uses those bindings directly. Its parameter type is the same shared
  type; its staging entrypoint is a local forwarding function, allowing isolated
  test substitution without changing shared behavior.
- Fresh SDKs contain distinct `julia/` and `revolt/` projects. Pkg resolves the
  relative shared dependency before sealing. The resolver child sets its own
  `JULIA_LOAD_PATH=@:@stdlib`, preserving the selected exported environment.
- Instrument startup checks the instrument runtime identity, source/resource
  closure and commands before shared installation and WirePlumber admission.
- Source evidence includes both projects with distinct prefixes. Capture checks
  both source roots; replay loads both projects. Shared templates stay shared.
- Current usage guides invoke instrument commands from the independent project.
  The obsolete fault-preparation helper referencing retired coordinators is
  removed; its historical evidence links the original source revision.

## Verification scope

Direct software suites passed 1,557 shared assertions and 1,362 instrument
assertions. Both strict `Pkg.test(allow_reresolve=false)` runs passed with
Julia 1.12.7 and the pinned operational dependencies.
The 85 package assertions and six cold-bridge assertions cover independent
loading, composed provenance, export, relocation through paths containing spaces,
installed re-export, identity/version/missing-source/wrapper rejection and source
preservation. Isolated Pkg execution additionally exposed missing test dependency
declarations and an inherited subprocess load path; retained failure logs and
the final rerun distinguish those fixes from successful direct execution.

Expected caught diagnostics for non-Git provenance and duplicate YAML keys remain
in the software logs. They do not constitute live session failures.

No services were started, old sealed SDKs modified or scientific matrices
regenerated in this split. HEART source is unchanged. Existing scientific
acceptance failures remain. Live installed session/calibration, steady-state
allocation, timing and hardware qualification are separate outstanding gates.

See [review dispositions](REVIEW.md) and [byte-preservation receipt](receipt.json).
Current delivery status belongs to [the roadmap](../../roadmap.md#current-work).
