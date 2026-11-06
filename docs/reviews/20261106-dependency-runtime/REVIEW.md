# RTC as an application dependency — 2026-11-06

Baseline: `c9a180c`, branch `codex/julia-session-policy-20261104`, dedicated
worktree `pipewireao-rtc-cleanup`. The only pending work at the start was the
authorized deployment cleanup. The user clarified NEC-05: use the RTC package as
a dependency instead of copying an SDK. No live services, instrument sources,
published registries or unrelated environments were changed.

## Design and removal

Application `Project.toml` declares PipeWireAORTC and the scientific packages it
selects. Its sealed `Manifest.toml` selects registry versions and source trees.
Launchers load the shared implementation with `using PipeWireAORTC` through that
application environment. Installed applications carry their declarations,
generated runtime configuration, calibration data, launchers and installation
metadata; they do not carry a copied RTC implementation or development test tree.

The source checkout keeps `[workspace] projects = ["test"]` for development.
Julia resolves a registered dependency independently of that package's development
workspace. The cold selector verifies that the application manifest contains no
`Test` entry. A registry's package source archive may itself contain tests; that
does not make their dependencies part of the application environment or copy
them into the exported application.

Commit `9b26249` removes the source copier and inventory, SDK-only validation,
redundant copying helpers, legacy wrapper generator, copied-`julia/` launch and
analysis fallbacks, and their obsolete tests. Generic file/tree copying remains
for instrument data and calibration staging. New install/start paths require a
registered runtime and sealed environment. Application workspaces, `[sources]`
and manifest path/repository overrides are rejected. Offline preparation can
still produce an unsealed application without resolving packages; it is not
installable until an explicit registered manifest has been supplied.

`ScienceExport.stage_rtc` owns only the generated `rtc/bin` launcher. It preserves
authored `rtc/configuration.yaml`, mirror controls and other RTC data, checks its
owned directory for unexpected entries, and replaces only the launcher file.
There is no second runtime implementation, resolver or source fallback.

## Instrument repository integration

The read-only source inspection used the clean
`adaptive-optics-simulations-shared-handoff` worktree at `7eed0543`.
`instrument.yaml` owns physical identity and geometry;
`simulation/definition.yaml` owns model/settings declarations; and
`rtc/configuration.yaml` owns RTC dimensions and references to mirror controls,
graphs, profiles and calibration data. Shared `tools/build.jl` invokes
`InstrumentExport.prepare` to compile and stage those declarations.

This data staging remains necessary. RTC Julia code comes from the application
dependency rather than the instrument source or an exported SDK. Classic already
declares a registered runtime and has no `[sources]`, but selects RTC `=0.4.4`
with an older scientific dependency cohort and the old `@PREFIX@` launcher
declaration. Its pins and launcher must be updated together when the corresponding
package cohort is released. This change does not silently migrate those sources
or claim that the existing Classic build runs the new implementation.

## Verification

Julia 1.13.3. The root Project and Manifest were unchanged:

| Input | SHA-256 |
| --- | --- |
| `Project.toml` | `cb5d71438646a626b5b1f491b18af1099a57d9a6b6943b580193fe99b869d997` |
| `Manifest.toml` | `8ca7b517cf48bb3a125f11f8cc1f7e8eabdba5e3b2f8f081587d8a31371b20ee` |

| Gate | Result | Log under `/tmp/` |
| --- | --- | --- |
| Full core suite, explicit PipeWireAO artifact prefix | 10,859 assertions in 505 testsets; exit 0 | `rtc-dependency-core-final-20261106.log` |
| Deployment/package/composition/export structural checks | 469 assertions; exit 0 | `rtc-dependency-structural-final-20261106.log` |
| Bootstrap mailbox test-double repair | 161 assertions; exit 0 | `rtc-bootstrap-owner-fixture-final-20261106.log` |
| Cold registered export/install/software relocation, including 9 offline preparation assertions | 277 assertions; exit 0 | `rtc-dependency-cold-final-20261106.log` |

Core command from the package root:

```sh
julia --startup-file=no --project=. -e 'using PipeWireAO;
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir);
include("test/runtests.jl")'
```

The first core run exposed stale bootstrap test doubles from the preceding
endpoint consolidation. Commit `ba622c9` moves them to the canonical Endpoint
interface without changing runtime behavior. The complete rerun passes. Its
`git cat-file` diagnostic belongs to the deliberately invalid-object rejection
test, not a failed gate.

### Cold registered installation and relocation

`test/runtime_install.jl` runs actual `InstrumentExport.prepare`, resolves a new
application from its Project alone, stages the resolved manifest, installs it,
executes the installed client and loads the dependency in a fresh process after
moving the application directory. It checks source immutability, retained authored
RTC data, artifact seals, absence of copied `julia/` and `test/` trees, absence of
workspace/source overrides and `Test` dependencies, registry tracking, and loading
from the depot rather than the application. The relocated installer source must
match the selected development source byte for byte.

The validation uses a temporary depot and a private copy of the local registry.
Only that copy registers RTC version 0.5.0 at commit `9b26249`, tree
`8d9968f6c45d547344b96574561f6b6937d555f2`. Its metadata is generated from this
Project's direct/weak dependencies and compatibility ranges. The package repo
points at the local Git repository, so Pkg retrieves the committed tree without
a `[sources]` or manifest path override. Existing package/artifact caches are
read-only inputs through per-entry links; new downloads and compilation stay in
the temporary depot. This is registry-resolution evidence for the exact changed
source, not evidence that this tree has been published under that version.

The first attempt failed before installation because `JULIA_PKG_SERVER=''` made
Pkg ignore the compressed General registry. Extracting that same registry into
the temporary depot restored discovery without changing dependency constraints
or production code. The failure remains in `rtc-dependency-cold-20261106.log`.

The selected compatible SDK is
`/tmp/pipewire-command-endpoint-native4-sdk-20261104`. After preparing the isolated
registry, the successful command was:

```sh
JULIA_DEPOT_PATH=/tmp/rtc-dependency-validation-20261106-Jer06B/depot \
JULIA_PKG_SERVER='' JULIA_PKG_PRECOMPILE_AUTO=0 \
PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104 \
julia --startup-file=no --project=. test/runtime_install.jl
```

The successful cold log has SHA-256
`0af873a87e898858fdcf781eee4f60adfeae1ab389921810fe6a840d10614832`.
The test creates no core,
graph owner or service. Software-environment relocation is separate from moving
an installed systemd unit or client launcher: those contain installation-specific
absolute paths and must be regenerated by installation at the new destination.
No hardware, science-cohort, live lifecycle or deadline qualification follows.

## Review

Independent source review identified three issues before the implementation
commit: launcher staging could remove authored `rtc/` data, composition still
accepted the retired runtime path, and the exporter needed an explicit parent
module binding. All were corrected and covered by focused checks. The final
source review reported no blocking findings. JuliaFormatter 2.14.8 checks preserve
syntax/literals and are idempotent; documentation checks preserve requirement IDs
and existing historical links (720 assertions in
`rtc-dependency-doc-checks-20261106.log`).
