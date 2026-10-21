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

## REVOLT instrument entrypoints

The Classic and Copper exporters and acquisition commands belong to the
independent [REVOLT Julia project](../../REVOLTRTC.jl/README.md). From this
repository root, instantiate that app environment once:

```sh
julia --startup-file=no --project=../REVOLTRTC.jl -e 'using Pkg; Pkg.instantiate()'
```

Run its wrapper with the same project, for example:

```sh
julia --startup-file=no --project=../REVOLTRTC.jl ../REVOLTRTC.jl/bin/copper_reference.jl \
  --base-package /absolute/path/to/sealed-copper-base \
  --output /absolute/path/to/fresh-candidate \
  --recipe /absolute/path/to/recipe.json \
  --aoc-source /absolute/path/to/AdaptiveOpticsCalibration.jl \
  --runtime /short/absolute/path/to/fresh-runtime
```

`../REVOLTRTC.jl/bin/calibration_campaign.jl` uses these options for Classic.
`copper_quality.jl` also requires `--reference-candidate`.
`calibration_method.jl` also requires
`--method` and uses `--prefix` for the PipeWire prefix. The other campaign
wrappers use `--pipewire-prefix`; the supported prefix is `/opt/pipewireao`.
See the maintained Copper reference and quality usage documents for recipes
and product contracts. Output and runtime directories must be new.

## Package and resources

The cold orchestration project is the named package `PipeWireAORTC`
(v0.1.1, Julia ≥ 1.12), loaded with `using PipeWireAORTC`. Modules live in
`src`; the test workspace lives in `test`.
Run portable verification with:

```sh
julia --startup-file=no --project=. -e 'using Pkg; Pkg.precompile(); Pkg.test()'
```

Reusable operational implementations live in package modules under `src`; root
`wireplumber_*.jl` scripts are thin package entrypoints. REVOLT entrypoints
are under `../REVOLTRTC.jl/bin` and use that app's project. The shared package
source checkout uses `assets/deployment/hil`, `assets/deployment/templates` and
the service template as resources.
Every exported SDK embeds these resources under `julia/assets/deployment`, along
with its package project, lock, source, CLI and test workspace closure. Resource
paths are resolved from the loaded package at runtime, including after SDK
relocation and precompilation. Operational provenance inventories exclude tests.
The repository's maintained scripts use Julia.

Installation verifies the sealed incoming artifacts, package identity/version
and resource completeness before copying an SDK. Generated service units use
that SDK's embedded template. Installation writes the unit but does not enable
or start it. Keep legacy include-loaded SDKs with their original launcher;
export a new SDK to adopt this package format. The new installer rejects the old
format instead of replacing sealed code.

## Installed entrypoints

Install a sealed exported package using the one-shot CLI:

```sh
julia --startup-file=no --project=. wireplumber_cli.jl install \
  --package /absolute/sealed-package \
  --destination /absolute/fresh-installation \
  --pipewire-prefix /opt/pipewireao
```

The installed `bin/pipewireao-rtc-session` invokes that package's one-shot tools.
Calibration/export wrappers retain their own Julia project and packaged modules.
They do not run a persistent supervisor. The old Rust coordinator binary,
`pipewireao-rtc-deploy` and coordinator service templates are excluded.

Start an exported REVOLT instrument package through the instrument preflight,
which verifies both the shared and instrument package closures and the sealed
instrument wrappers before delegating to the shared one-shot session runtime:

```sh
julia --startup-file=no --project=../REVOLTRTC.jl -e '
    using REVOLTRTC
    println(REVOLTRTC.Installation.start!(ARGS[1], ARGS[2]))
' /absolute/sealed-package /absolute/fresh-stage
```

Use optional `--julia-executable /absolute/path/to/julia` during installation to
select the runtime. The default is the executable running the installer.
Installation validates Julia ≥ 1.12 and < 2 and resolves juliaup selection to its
managed runtime. Generated wrappers record that absolute executable; reinstall
to a fresh destination to select another runtime.

All campaigns require a sealed scientist-authored complete-frame base package.
The selected WirePlumber binary, modules and Lua scripts must be sealed with the
scientific assets. HIL and HEART exports select these assets from the installed
`--pipewire-prefix` by default (`/opt/pipewireao` on this host). Development builds
can supply both `--wireplumber-build` and `--wireplumber-source`. See the
[installed runtime](INSTALLED_RUNTIME.md) for build and validation details.
Calibration exports copy and validate the base package's sealed assets before
hashing. Python tools have been removed from this repository. Historical producer
records retain their original scope and Git source provenance.

## systemd session and owner services

For generic shared packages, `WirePlumberSessionRuntime.start!` installs a
fresh exact instance of `pipewireao-session@.service`, prepares separate scientific owner services, and
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

## Headless artifact registration and shared update history

`PipeWireAORTC.ConfigurationStore` owns a local bare Git repository and SQLite
catalog. GUI, CLI and Julia scripts use this implementation. The default root is
`$XDG_STATE_HOME/pipewireao/configuration`, or
`~/.local/state/pipewireao/configuration`. Pass an explicit root for isolated
experiments. Registration is independent of live session attachment and never
applies a value.

A calibration script can register a generated host array directly:

```julia
using PipeWireAORTC: ConfigurationStore

store = ConfigurationStore.Store()
record = ConfigurationStore.register!(store, reconstructor;
    label="Reconstructor candidate",
    scope=Dict("session_label" => session_label,
        "graph" => graph_name, "parameter" => "reconstructor"),
    schema=reconstructor_schema,
    metadata=Dict("generator_revision" => generator_revision))
artifact_id = record["id"]
```

`record["id"]` is the Git object ID of the canonical preparation manifest.
`content_oid` identifies the original FITS bytes, and `commit_oid` pins the
manifest and FITS together under `refs/artifacts/<id>`. Labels, target scope,
schema, preparation rules and provenance are part of the manifest identity;
registration does not make the artifact active.

For an existing FITS file use `Artifacts.FITSArtifact(path; hdu=1, axes=...)`,
with an explicit logical axis permutation for multidimensional data, plus the
target element type and shape. `register!` validates one captured FITS snapshot,
records its original bytes and scientific preparation manifest, pins their Git
commit, then inserts the catalog reference. Registration does not infer units,
transposition, scientific acceptance or compatibility with another instrument.

`list_artifacts(store)` returns a bounded catalog page.
`get_artifact(store, artifact_id)` verifies and returns the exact record.
`materialize!(store, artifact_id; storage_order="row-major")` prepares an
explicit-layout transport payload from the retained FITS. It returns its path,
shape, element type, schema and digest. The caller still validates the exact
parameter declaration and sends the existing native session parameter operation.
Selection or preparation alone never applies the artifact. The materialized
files are a bounded rebuildable transport cache, not a second artifact authority;
they persist across frontend exits so an unresolved native request cannot lose
its payload. Capacity exhaustion refuses preparation; maintenance is explicit.

The command-line frontend accepts the same management operations as bounded
JSON-lines requests and responses. For example, from the package checkout:

```sh
julia +1.13 --startup-file=no --project=. configuration_store_cli.jl serve
```

Send one JSON object per line:

```json
{"protocol":"pipewireao.configuration/1","op":"list","arguments":{"limit":50}}
{"protocol":"pipewireao.configuration/1","op":"history","arguments":{"limit":50}}
```

`register` accepts the FITS path, type, shape, one-based HDU, axes, label, scope,
schema and metadata. `get` accepts an artifact ID and optional `layout`.
`root` optionally selects an explicit local store. This management interface
performs catalog/import/history work only. It does not provide another live
control protocol, calibration orchestrator or remote browser service.

The native GUI's `PIPEWIREAO_CONFIGURATION_COMMAND` is a JSON array of executable
and arguments for this helper. `PIPEWIREAO_CONFIGURATION_ROOT` optionally selects
the root. The helper runs off the UI thread; the GUI does not open SQLite or Git.
Without a helper the GUI reports the catalog unavailable while existing native
controls remain usable. Browser/WASM presentation compilation does not establish
a live browser management transport.

New `WirePlumberConfiguration` session configurations include the asynchronous
`ao-journal` module. The `configuration_store_root` keyword selects its store;
`nothing` explicitly produces an unjournaled configuration for an older isolated
runtime. The exporter and installer require the matching journal module. Existing
sealed sessions are unchanged; no earlier history can be reconstructed.

`ConfigurationStore.history(store; session_id=nothing, limit=50)` queries the
shared journal. Its entries include the proven controller identity/name, native
session and endpoint incarnation, token, requested property values or parameter
binding, and correlated completion. All clients using the journal-enabled session
endpoint contribute, even when the GUI is closed. Direct writes bypassing that
endpoint are outside this history. Read-only queries are not update events.

For a registered artifact, select its target and catalog entry in the GUI, load
it to prepare a verified read-only transport payload, then explicitly apply it.
The current native parameter request carries the prepared file path. The
headless history query correlates that path with the retained catalog mapping
and returns the exact Git manifest ID in `artifact_id`; the GUI displays it in
the selected update. The native journal retains the original request and reply.
An immediate Submitted result is preserved even when a later
`parameter-generation` query confirms equal requested and active sequences.

Requested operations lacking terminal evidence remain unknown. A submitted
parameter is not necessarily active; an SQLite transaction and a Git commit do
not make several scientific changes atomic. Existing owner generation/status
queries remain the source of current adoption evidence. Reopening the journal
never retries an operation or restores an old value.

Backups must preserve both a consistent SQLite snapshot and the Git repository,
including all retained artifact refs. Git maintenance must preserve registered
objects. Do not place the SQLite WAL database on a network filesystem or copy a
live database file without its consistent snapshot. Backup/restore automation
and scientific stream recording are separate work.
