# Explicit runtime export checks

Date: 2026-10-08. Starting revision: `b345823`, clean `main`.
Changes are in the commit carrying this record, prepared in
`/tmp/pipewireao-rtc-package-boundaries-20261008` on
`work/rtc-package-boundaries-20261008`.

## Observed regression and correction

Before the change, `ScienceExport.copy_deployment_runtime` included an unrelated
`unrelated-build-probe.tmp` placed at the loaded Julia package root. The assertion
that it should be absent from the export failed with
`AssertionError: unrelated package-root file was exported`. The same command
passed after replacing whole-root recursion with explicit runtime entries.
The temporary probe was removed in `finally`; it was confined to the owned
implementation worktree.

To reproduce from the repository root with the instantiated tooling environment:

```sh
julia --startup-file=no --project=deployment/julia -e '
using PipeWireAODeployment
P = PipeWireAODeployment
probe = joinpath(P.package_root(), "unrelated-build-probe.tmp")
ispath(probe) && error("probe path already exists")
try
    write(probe, "not runtime content")
    mktempdir() do destination
        sdk = P.ScienceExport.copy_deployment_runtime(destination)
        @assert !ispath(joinpath(sdk, basename(probe)))
    end
finally
    rm(probe; force=true)
end'
```

Run only in a disposable source checkout; installed sealed packages are not
modified for this experiment. Maintained tests use a copied source tree.

## Software validation

```sh
julia --startup-file=no --project=deployment/julia deployment/julia/test/runtests.jl
```

The final suite passed **2725/2725 assertions across 97 test sets**.
The focused helper/relocation checks and unchanged fail-before/pass-after probe
also passed. Expected Git revision lookups in temporary non-repository test
inputs print diagnostics and return no revision; they did not fail tests.
Checks include:

- Explicit entries omit unrelated build and instrument directories; declared
  bytes remain equal and parent directories are preserved.
- Missing/traversing/absolute/duplicate entries, symlink entries/parents,
  dangling destinations and overlapping destinations are rejected.
- Extracted helpers load independently of operational/scientific packages.
  Existing ScienceExport copy-function bindings remain unchanged.
- Installation validates declared entrypoints/assets; missing selected files
  reject validation and restoring them permits it.
- Existing named-package, compiled relocation and installed re-export checks
  pass, as do the existing configuration/export/calibration client regressions.

Independent Astra source review found no blocking correctness issue in the
explicit closure, helper containment, caller bindings or installed re-export.
Its review is source evidence, separate from the software results.

## Scope

No live RTC/HIL session was launched or modified for these checks. The existing
GUI/HIL service remained active with MainPID `1632744`. No HEART, FGN, JFG or AOS
algorithm source, native protocol record or scientific calibration artifact was
changed. No new numerical, hot-path allocation, deadline or latency claim follows.
The SDK still includes current instrument modules and selected recursive
source/test/scientific-resource directories. Independent instrument projects,
Julia interaction acquisition and the root-package move remain migration work.
