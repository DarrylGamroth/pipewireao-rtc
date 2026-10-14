# Core package registration receipt

Date: 2026-10-14. Julia 1.12.7, Linux x86_64. Scope: the shared operational package
and its existing PipeWireAO dependency. This is not the registered Classic
scientific application.

## Immutable releases

| Package | Version | Git tree | Source commit |
|---|---|---|---|
| PipeWireAORTC | 0.1.1 | `8f609ff2ca5940e2516a9ed7d6dcee4ff0878741` | `db9ebe7a18b255b2337edae23995c24faf151400` |
| PipeWireAO | 0.6.17 | `4b859fef04b1b77e3a6451d1c22b2a3e0e5bc5ee` | `1417b69656b94e146e600c7201bc4d3b34d2cea4` |

PipeWireAORTC retains UUID `a3e2c7da-f73f-4284-8482-36ac422b34e6`.
LocalRegistry generated the entries from clean committed source. No dirty
scientific snapshot was published and REVOLTClassicSim was not registered.

Registry commits are `3fcf7f6ad186efe049dcdc79b777badf0205ea12` (initial core and
PipeWireAO entries) and `28d363f8d14b495c89947b76ff13afc925948afe` (0.1.1 patch).
The installed `/home/dgamroth/.julia/registries/DarrylGamrothRegistry` was advanced
by fast-forward to the latter commit and is clean. Its original entries remain.
The immutable 0.1.0 entry is retained; its test-only permissions defect and repair
are recorded in [validation](README.md#registered-copy-test-boundary).

Published review branches:

- `DarrylGamroth/pipewireao-rtc`: `codex/pipewireaortc-implementation-20261014`.
- `DarrylGamroth/PackageRegistry`: `codex/pipewireaortc-registration-20261014`.

Remote default branches were not changed. The installed Local Registry includes
these entries; other hosts using the remote default registry branch require its
reviewed promotion before ordinary registry updates discover them. Registry
installation does not add packages to or change the user's default Julia Project.

The release tree above is fixed even if later documentation commits advance the
implementation branch. Do not reregister that version from a different tree.

## Installation and verification

An isolated depot began empty, with `JULIA_DEPOT_PATH` containing only that depot.
The core package was added by registered name/version, together with FITSIO for
the preparation check. It loaded from the depot, prepared a nonsquare FITS image
with explicit axes, and created no packed artifact files. The resolved test
environment has no `path` entries and no Project `[sources]` overrides.

The same isolated depot was then updated to the immutable 0.1.1 release, retaining
cached dependencies. A new process verified the exact registered tree and ran:

```julia
using Pkg
Pkg.test("PipeWireAORTC")
```

Result: **PASS, exit 0; 53 testsets, 1,850 assertions**. The package test code ran
from Julia's installed, read-only package directory. [Complete registered-copy
output](registered-0.1.1-Pkg.test.log), [resolved Project](application.Project.toml)
and [Manifest](application.Manifest.toml) preserve the exact environment. These
files describe a core verification environment, not a Classic deployment.

The initial checkout run passed 1,848 assertions. Registered-copy testing exposed
the read-only temporary-copy assumption; version 0.1.1 adds two regression
assertions and fixes that test without changing production implementation.
The earlier [failed run](registered-0.1.0-Pkg.test.log) remains recorded.

## Preserved state and remaining gates

The original shared and scientific worktrees retain their pre-existing changes.
The original GUI and RTC services retain their observed PIDs and invocation IDs.
The WirePlumber malformed-parameter fix remains separately reviewed at `63f2df2`;
it was not installed into those services.

Hsm and Agent are deferred. Scientific dependency releases, public graph
introspection, package-owned JFG/AOS entrypoints, exact configuration/FITS-driven
simulation, the small relocated Classic application and isolated lifecycle/science
qualification remain open in [the migration contract](../../REGISTERED_RTC_MIGRATION.md).
CTW-01/02, resource/latency and physical hardware qualification remain unresolved;
the core package tests do not establish them.
