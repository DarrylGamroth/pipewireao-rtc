# Julia deployment package structure review

Review date: 2026-10-03. Scope: package structure and loading; no new RTC,
scientific, timing or accelerator qualification.

## Baseline and authority

- Source: `5be3741869c17cea08867967747da78effad9466`, clean `main`.
- Review branch: `work/julia-package-structure-20261003`.
- Review checkout: `../pipewireao-rtc-package-audit`.
- Authority: RTC-ARCH-020 through RTC-ARCH-023, RTC-DEV-020 through RTC-DEV-029,
  and the selected [Julia migration](JULIA_CALIBRATION_MIGRATION.md).
- The [migration validation](JULIA_CALIBRATION_MIGRATION_VALIDATION.md) remains
  historical evidence for its exact sources and installed artifacts.

The runner owns configuration, supervision and control. Scientific Algorithms,
graphs, the simulator and calibration mathematics remain in their respective
packages. This review does not move those responsibilities into deployment code.

The reference is the official [Pkg package guidance](https://pkgdocs.julialang.org/v1/creating-packages/),
including its Julia 1.12 test-workspace recommendation. A Julia application
environment without a package name is valid; reusable libraries benefit from
named package loading and the standard source/test layout.

## Observed structure

`deployment/julia/Project.toml` declares runtime dependencies and Julia 1.12
compatibility. Its committed `Manifest.toml` records Julia 1.12.7 and the resolved
application dependencies. `PipeWireAODeployment.jl` includes thirteen component
modules. CLI wrappers and installed launchers load it using `include`.

| Surface | Observation |
| --- | --- |
| Package identity | No name, UUID or version; this is an application environment |
| Source entry | `deployment/julia/PipeWireAODeployment.jl`, without `src/` |
| Tests | Seven `test_*.jl` scripts, without `test/Project.toml` or `test/runtests.jl` |
| Optional simulation dependencies | Separate `deployment/hil/Project.toml`; GPU backend preparation belongs there |
| CLI boundary | Thin outer wrappers invoke component `main` functions |
| Installed resources | Julia assets include deployment templates, HIL helpers and the user-service template |
| Provenance | Campaigns hash orchestration source, environment and resource files |
| Production language | Operational modules and entrypoints are Julia; historical Python evidence remains separate |

Source import inspection found declarations for the external runtime packages
JSON3, StructTypes, YAML and OrderedCollections, and the used SHA, Sockets, TOML
and UUIDs standard libraries. No runtime test, benchmark or profiler dependency
was found in this environment. `Dates` is declared but not directly imported by
the deployment modules; it is also a transitive dependency of JSON3/YAML.

## Findings

### RTC-JPS-001 — Reusable deployment code has no named package interface

Severity: medium improvement. Confidence: high. Evidence class: observed.

Evidence: `deployment/julia/Project.toml:1`,
`deployment/julia/PipeWireAODeployment.jl:1`, `deployment/deploy.jl:2`, and
`deployment/julia/deploy.jl:997–1024`.

The current application is valid and its include-based loading works. It cannot
be consumed through ordinary `using PipeWireAODeployment` and package-manager
identity as currently structured. A named package would provide a normal Julia
loading/precompilation boundary for reuse by Julia applications and tooling.
This is a structure improvement, not evidence of an RTC delivery failure.

Remediation: give the deployment module a stable package identity, move its
module entry and implementation into `src/`, and make CLI wrappers load that
package. Keep the application dependency lock and separate simulation
environment. Registration is a separate decision and is not required for local
or installed package use.

Compatibility impact: preserve the CLI commands, installed wrappers and sealed
artifact checks. Treat existing include entrypoints explicitly if compatibility
is retained; avoid loading duplicate module instances.

Disposition: recommended next implementation increment. No filesystem move or
package version publication was performed by this audit.

### RTC-JPS-002 — Portable checks have no standard Pkg test entrypoint

Severity: medium improvement. Confidence: high. Evidence class: observed.

Evidence: the seven `deployment/julia/test_*.jl` files, project metadata and the
portable-suite record in [migration validation](JULIA_CALIBRATION_MIGRATION_VALIDATION.md).

The recorded script checks exist and were qualified during migration. They are
not currently a package-owned `Pkg.test()` suite. They also introduce module and
constant bindings in their own script scope, so merely concatenating their
contents into one `runtests.jl` is not a safe conversion.

Remediation: alongside RTC-JPS-001, add `test/Project.toml` with Test and all
direct test imports, the package as an explicit dependency, a parent path source
and a Julia 1.12 workspace. Add `test/runtests.jl`, isolate suite namespaces, and
load the actual package in package-level checks. Preserve deliberately isolated
export fixtures where they test a component boundary. Keep process/live and
systemd qualification separate from portable checks.

Disposition: coupled to RTC-JPS-001; prior script evidence is retained.

### RTC-JPS-003 — Source relocation affects installed resource and hash contracts

Severity: medium migration constraint. Confidence: high. Evidence class: observed.

Evidence: `science_export.jl:7–9,68–85`,
`calibration_campaign.jl:160–179,361–362`, `calibration_method.jl:121`, and
`heart_export.jl:148–150,192–194` within `deployment/julia/`.

Source-relative paths currently identify the application root, resource tree,
CLI, native executable, source inventory and evidence-copy destinations. Those
paths are coherent with the current layout. Moving implementation into `src/`
without updating these contracts would change what gets copied, executed and
hashed. Source-root enumeration is currently flat; it would miss a newly nested
implementation if left unchanged.

Remediation: define package and resource roots centrally, make installed resource
discovery safe for precompiled package relocation, and enumerate the complete
implementation recursively. Copy the package source, environment and required
assets together; preserve the existing scientific-owner boundary. Verify that
the source inventory includes every operational source and excludes test-only
or development artifacts. Do not substitute new hashes into old evidence.

Required validation for that increment: named package loading/precompilation,
isolated portable suites, source inventory, installed export/installation and
relocation, followed by selected cold CLI, foreground and systemd owner checks.
Old installed SDKs remain identified by their original hashes.

Disposition: required constraint for RTC-JPS-001, not an existing confirmed
relocation defect.

## Proposed layout

```text
deployment/julia/
  Project.toml                package identity, runtime dependencies, test workspace
  Manifest.toml               retained application/SDK dependency lock
  src/
    PipeWireAODeployment.jl   module entry
    common.jl                component implementation files
    ...
  test/
    Project.toml             package and direct test dependencies
    runtests.jl              isolated portable suites
    ...
  assets/                    deployment resources, included in installed exports
```

Keep thin deployment CLI entrypoints outside reusable implementation. Do not
turn each internal component module into a separate package or require the
scientist to understand deployment packaging. Do not add Aqua, JET or other
personal development tools as runtime dependencies.

## Checks performed and limits

Observed fresh-process check with Julia 1.12.7 and
`--startup-file=no --compiled-modules=existing --project=deployment/julia`:
including the module succeeded, resource discovery selected this checkout's
`deployment/`, and `CalibrationCampaign.orchestration_sources()` returned
40 existing source/resource identities.

Metadata, direct imports, wrappers, installation, copy paths and provenance code
were inspected. No tests were added or run in this audit, and no live process,
GPU, scheduler, numerical or real-time behavior was qualified. The package-layout
implementation and its qualification remain open; current deployment code and
its resolved dependencies were preserved.
