# Julia deployment and calibration entrypoints

Operational calibration preparation, acquisition orchestration and process
supervision use Julia ≥ 1.12. The numerical estimators and probe bases remain
in AdaptiveOpticsCalibration. Detector acquisition and graph algorithms retain
their existing owners. The migration does not change illumination, noise,
matrices, gains or scientific acceptance.

## Source entrypoints

Instantiate the cold orchestration environment once:

```sh
julia --startup-file=no --project=deployment/julia -e 'using Pkg; Pkg.instantiate()'
```

Run a wrapper with the same project, for example:

```sh
julia --startup-file=no --project=deployment/julia deployment/copper_reference.jl \
  --base-package /absolute/path/to/sealed-copper-base \
  --output /absolute/path/to/fresh-candidate \
  --recipe /absolute/path/to/recipe.json \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration.jl \
  --rtc-binary /absolute/path/to/pipewireao-rtc \
  --calibration-binary /absolute/path/to/rtc-calibrate \
  --runtime /short/absolute/path/to/fresh-runtime
```

`calibration_campaign.jl` uses these options for Classic. `copper_quality.jl`
also requires `--reference-candidate`. `calibration_method.jl` also requires
`--method` and uses `--prefix` for the PipeWire prefix. The other campaign
wrappers use `--pipewire-prefix`; the supported prefix is `/opt/pipewireao`.
See the maintained Copper reference and quality usage documents for recipes
and product contracts. Output and runtime directories must be new.

## Package and resources

The cold orchestration project is the named package `PipeWireAODeployment`
(v0.1.0, Julia ≥ 1.12), loaded with `using PipeWireAODeployment`. Modules live in
`deployment/julia/src`; the test workspace lives in `deployment/julia/test`.
Run portable verification with:

```sh
julia --startup-file=no --project=deployment/julia -e 'using Pkg; Pkg.precompile(); Pkg.test()'
```

Source wrappers keep their existing command lines. The source checkout uses
`deployment/hil`, `deployment/templates` and the service template as resources.
Every exported SDK embeds these resources under `julia/assets/deployment`, along
with its package project, lock, source, CLI and test workspace closure. Resource
paths are resolved from the loaded package at runtime, including after SDK
relocation and precompilation. Operational provenance inventories exclude test
and Python development files.

Installation verifies the sealed incoming artifacts, package identity/version
and resource completeness before copying an SDK. Generated service units use
that SDK's embedded template. Installation writes the unit but does not enable
or start it. Keep legacy include-loaded SDKs with their original launcher;
export a new SDK to adopt this package format. The new installer rejects the old
format instead of replacing sealed code.

## Installed entrypoints

Install a sealed exported package with `deployment/deploy.jl install`, supplying
`--package`, `--destination` and `--pipewire-prefix`. Its `bin` directory contains
`pipewireao-rtc-deploy`, `calibration_campaign`, `calibration_method`,
`copper_reference`, `copper_quality`, `export_calibration`, `export_hil` and
`export_heart_hil`. The wrappers
select the package's Julia project and load its packaged modules. Packages carry
their cold export resources separately from the resolved simulator environment;
preparing another package does not replace its plant or local dependencies.

Use optional `--julia-executable /absolute/path/to/julia` to select the runtime.
The default is the executable of the Julia process running the installer.
Installation validates Julia ≥ 1.12 and < 2 before creating the destination and
resolves juliaup selection to its reported managed runtime. Each generated
wrapper records the same absolute executable, so foreground and generated user
units work with a `PATH` that excludes Julia. Retain the selected runtime on the
host. Reinstall to a fresh destination to choose another runtime. Unsealed
installed wrappers are regenerated; incompatible sealed wrappers are rejected
with instructions to export a fresh SDK. The user manager environment requires
no changes.

All four campaigns require a sealed scientist-authored complete-frame
`--base-package`. Existing Python generators and audits remain development
tools for creating or inspecting those inputs. They are not invoked by the
operational Julia workflow. Legacy Python command lines in historical evidence
identify the original producer and must not be relabeled.

Foreground launch and the generated systemd user service use the same deployment
owner. The service sends SIGINT for bounded graceful cleanup. Placement admission
checks the configured CPU envelopes, worker policies and resource limits;
the supervisor pins every existing Julia native thread before starting children.
This is functional deployment behavior, not a scheduler-latency qualification.

## Separate systemd owner services

New SDK exports also install `systemd/pipewireao-rtc-systemd@.service`. This opt-in
unit starts a headless coordinator and separate transient user services for the
private core, source, optional Julia graph, WirePlumber and RTC runner. Native
GUI/CLI controls and scientific configurations remain the same. Installation
does not link, enable or start a service. The default `pipewireao-rtc@.service`
and foreground command retain direct process ownership.

Install the package at `~/.config/pipewireao-rtc/<instance>`, link its opt-in
template with `systemctl --user link`, reload the user manager, then explicitly
start `pipewireao-rtc-systemd@<instance>.service`. Stop or restart the coordinator
unit as a whole; independently restarting an owner under the same unit name is
unsupported. A restart creates and validates a fresh scientific cohort.
The coordinator verifies its exact cleanup executable and arguments before
starting any owners. `ActiveState=active` alone does not establish RTC admission.

The unit preserves its private runtime directory for final reports and uncertain
cleanup diagnostics. Remove a stopped instance's retained runtime only after its
owner cgroups are empty. The initial backend verifies actual per-thread placement;
this host's accepted `AllowedCPUs` property is insufficient to establish a cgroup
cpuset restriction. See [design and qualification scope](SYSTEMD_OWNER_DESIGN.md).

## Qualified scientific dependencies

Scientific source inputs must form a compatible set. The selected CPU HEART
qualification uses adapter `277d822` and seals the actual supplied AOS and
PipeWireAO files. It does not infer source equality from a Git revision alone.
Adapter `39efcf5` requires an AOS graph-calibration boundary absent from the
selected AOS checkout and fails import before admission. Select compatible
`--aos-root` and `--adapter-root` inputs when exporting; the
[migration record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md) binds the tested
files and preserves that failed attempt.

## Failure and scientific boundaries

Requests and captures are correlated by run, serial, probe and exposure identity.
Completed batches are copied and verified before another figure is adopted.
Known rejections permit bounded restoration; unknown mutation outcomes remain
held or faulted. Shutdown, release, restoration and owned-process cleanup are
reported separately. A partial campaign cannot replace active calibration.

HEART uses its unchanged native executable with the SPA stdWfs/stdDM bridge;
its Julia owner handles placement and public lifecycle commands. Accelerator
selection in an HIL export does not establish CUDA or AMDGPU cadence.
Migration qualification is recorded separately from interaction-matrix
precision, physical suitability and correction acceptance.
