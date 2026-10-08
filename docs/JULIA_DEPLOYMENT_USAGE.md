# Julia deployment and calibration entrypoints

Operational calibration preparation and acquisition clients use Julia ≥ 1.12.
WirePlumber owns session policy; systemd owns process supervision. The numerical estimators and probe bases remain
in AdaptiveOpticsCalibration. Detector acquisition and graph algorithms retain
their existing owners. The migration does not change illumination, noise,
matrices, gains or scientific acceptance.

The Julia DeploymentRunner and supervisor launchers are retired. Use the
one-shot WirePlumber session tools described in the [repository quickstart](../README.md#launch-a-sealed-session-package).
The native session client controls admission and graph operations; local owner
interfaces retain calibration acquisition actions. The new SDK includes sealed
WirePlumber assets and rejects a missing session runtime before installation.
Scientific campaign qualification under this replacement remains separate from
the recorded Copper complete-frame lifecycle checks.

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

Install a sealed exported package using the one-shot CLI:

```sh
julia --startup-file=no --project=deployment/julia deployment/julia/wireplumber_cli.jl install \
  --package /absolute/sealed-package \
  --destination /absolute/fresh-installation \
  --pipewire-prefix /opt/pipewireao
```

The installed `bin/pipewireao-rtc-session` invokes that package's one-shot tools.
Calibration/export wrappers retain their own Julia project and packaged modules.
They do not run a persistent supervisor. The old Rust coordinator binary,
`pipewireao-rtc-deploy` and coordinator service templates are excluded.

Use optional `--julia-executable /absolute/path/to/julia` during installation to
select the runtime. The default is the executable running the installer.
Installation validates Julia ≥ 1.12 and < 2 and resolves juliaup selection to its
managed runtime. Generated wrappers record that absolute executable; reinstall
to a fresh destination to select another runtime.

All campaigns require a sealed scientist-authored complete-frame base package.
The selected WirePlumber binary, modules and Lua scripts must be sealed with the
scientific assets. Calibration exports copy and validate those assets before
hashing. Existing Python generators/audits remain development tools and are not
invoked by operational Julia campaigns. Historical Python producer records retain
their original scope.

## systemd session and owner services

`WirePlumberSessionRuntime.start!` installs a fresh exact instance of
`pipewireao-session@.service`, prepares separate scientific owner services, and
returns only after the admission hook completes. `ActiveState=active` alone
never proves scientific readiness. The manager verifies native owners and held
acquisition; the one-shot admission hook checks their actual placement.

The preparation helper renders ordinary user service files and an owner target.
It starts the private core, verifies its socket, then starts the FGN/JFG cohort
through one target transaction. It performs no frame processing and exits before
WirePlumber runs. HEART retains its necessary controller-PID launch stage.
See [startup and cleanup](SYSTEMD_SESSION_STARTUP.md) for identity checks and
ingress-first removal of the generated runtime units.

Clients send native session controls. Normal `shutdown!` requires a correlated
Quit→Offline acknowledgement and then observes exact systemd/owner cleanup.
Emergency `stop!` is a distinct process-cleanup operation; it cannot establish
successful public shutdown. Unknown Quit outcomes prohibit another Quit.
The same retained invocation is used to reconcile cleanup without replay.

Owner services use fresh names and `Restart=no`. Restart the session as a new
whole cohort; do not restart a required owner in place. Retained runtime files
are diagnostic receipts and never live readiness authority. Delete them only
after exact process/cgroup cleanup. Functional placement checks do not qualify
scheduler latency or a host cpuset restriction.

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
