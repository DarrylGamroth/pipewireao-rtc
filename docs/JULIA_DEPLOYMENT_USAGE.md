# Julia deployment and calibration entrypoints

Operational calibration preparation and acquisition clients use Julia ≥ 1.12.
The headless RTC owns application session policy; systemd owns process supervision. The numerical estimators and probe bases remain
in AdaptiveOpticsCalibration. Detector acquisition and graph algorithms retain
their existing owners. The migration does not change illumination, noise,
matrices, gains or scientific acceptance.

The Julia DeploymentRunner and supervisor launchers are retired. Use the
one-shot RTC session tools described in the [repository quickstart](../README.md#launch-a-sealed-session-package).
The native session client controls admission and graph operations; local owner
interfaces retain calibration acquisition actions. The new SDK includes sealed
headless RTC and libwireplumber assets and rejects a missing session runtime before installation.
Scientific campaign qualification under this replacement remains separate from
the recorded Copper complete-frame lifecycle checks.

## Open and close correction

Application Start/Stop controls acquisition. The scientific controller's
runtime `closed` Boolean independently holds or resumes correction. The native
RTC property transaction is shared by the GUI, CLI and Julia; there is no
additional loop-control wire protocol. For an explicitly selected session:

```julia
using PipeWireAORTC
session_id = "SELECTED-SESSION-UUID"
graph = "gpi2-jfg-frame-graph"
target = "closed-loop-correction:closed"
opened = PipeWireAORTC.SessionCLI.control_session(session_id,
    ["property", graph, target, "bool", "false"])
observed = PipeWireAORTC.SessionCLI.control_session(session_id,
    ["properties", graph])
# An explicit operator action can close again with the same target and "true".
```

Opening retains the committed correction and mathematical integrator state;
it does not stop acquisition, disconnect command ports, set gain to zero or
restore a mirror flat. Reclosing resumes the normal feedback recurrence from
retained state. Downstream filters and physical responses keep evolving.
Existing startup behavior remains closed unless explicitly configured open.
Do not use this as a device-safe-state operation.

The owner must publish the writable Boolean capability. A `Submitted` response
does not prove active adoption; inspect the outcome and requested/active
generations and query the owner. An unknown outcome is never automatically
retried. Ordinary CPU JFG owners accept runtime property updates; captured JFG
owners retain their prepare-a-new-owner requirement for property changes.

For RTC-owned Hsm adoption tracking, add these two arguments to the ordinary
Julia graph owner's `argv` in `rtc/application.yaml`:

```yaml
- "--correction-property"
- "closed-loop-correction:closed"
```

Repeat for each declared loop. Operational admission and status require RTC
0.2.13 and FilterGraphPipeWire 0.1.9. The owner validates the Boolean and initial applied
readback before admission. `Open`/`Closed` describe confirmed adoption;
`Opening`/`Closing` describe accepted changes awaiting it; inconsistent facts
latch `Unknown`. Ordinary read-only graph properties publish the state, fault
and requested closure under `pipewireao.correction-control.NODE:PROPERTY`.
The existing `NODE:PROPERTY` Boolean is the applied value, with existing node
requested/active generations. These values are available to every client through
the existing `properties` query, and to generic advertised-property displays.
Start/Stop, reset and controller state remain unchanged.

The native RTC refuses a loop change unless its session, execution group and
owner are running and fresh status confirms the expected owner, stable loop
state and completed previous adoption. A refused row rejects its whole scalar
transaction before any values change. A refusal does not fault a healthy session.

The default adoption timeout is 5000 ms. An optional owner argument
`--correction-timeout-ms N` accepts 1–60000 ms. In RTC 0.2.14, state entry arms
a native PipeWire timer and state exit cancels it. The timer wakes owner-thread
publication, so expiration does not need frame traffic or another client query.
Hsm still runs only on the graph control thread; remote native queries may read
cached Props. Expiration or unavailable observation latches `Unknown` for that
owner incarnation, without retry, reset,
opening or flattening. A late readback cannot silently clear it. Generation
equality proves plan adoption, not the first processed frame or physical motion.

In `gui/operator-views.yaml`, declare presentation references under the existing
session binding (the label must match the selected RTC session):

```yaml
session:
  label: gpi2
  graphs: [gpi2-jfg-frame-graph]
  correction_loops:
    - id: correction
      title: Correction
      graph: gpi2-jfg-frame-graph
      property: "closed-loop-correction:closed"
```

The RTC Session panel provides Open loop, Close loop and Refresh controls;
published Boolean values supply Open/Closed observations. Missing values or an
unresolved update show Unknown. The binding does not create authority or infer
capabilities from instrument names. GPI's coupled controller exposes one
coordinated loop; independent corrector closure requires an allocation policy.

## Headless WFS measurements

An optional analysis graph uses the ordinary `shack-hartmann-summary-f32`
Algorithm with `slopes`, `flux` and `validity` from observation queues. Configure
the subaperture count, export `summary`, and connect it to an exclusive
capacity-one copy/drop-oldest observation queue. Numerical work stays in the
analysis graph; the RTC's required controller has no diagnostic reduction.

The F32 vector has shape `(8,)` and schema
`pipewireao/shack-hartmann-summary-f32/1`. Zero-based fields are total count,
valid count, mean valid flux, X slope RMS, Y slope RMS, combined RMS, mean X
slope and mean Y slope. RMS is uncentered. Flux and slopes retain their input
units. Mean slopes do not establish calibrated physical tip/tilt or focus.
Invalid subapertures are excluded; no valid rows or nonfinite valid inputs
produce NaN aggregates while retaining the counts.

The scientific schema owner declares named channels. FilterGraphPipeWire
publishes their catalog once as the read-only native String Props parameter
`pipewireao.ndarray.channels`. This describes the same complete summary packet;
no channel metadata is repeated in frames. The source's exact output Port,
schema, representation and shape bind each catalog entry. Consumers resolve
the source through current exact links when observing a queue output.

Optional analysis configuration accepts `channel-units`, a bounded mapping from
public output Port to channel name to units. For example:

```yaml
channel-units:
  summary:
    mean_x_slope: detector pixel
    mean_y_slope: detector pixel
    mean_flux: summed calibrated ADC
```

These are source declarations, independent of GUI profiles. Counts have fixed
`count` units; inherited flux and slope units remain unknown unless explicitly
declared. Unknown output/channel names and invalid or conflicting units fail
before publishing the analysis Node. The annotation does not convert values or
change Algorithm configuration. Its bounded configuration accepts at most 64
Ports and 64 channels per Port, with valid UTF-8, nonempty control-free text up to 255
bytes. The complete published catalog must fit 16384 bytes. Changing these units
requires a new source Node. Existing analysis configurations remain valid.

Standalone FilterGraphIsland and RTC GraphOwner launches can use repeated
`--channel-unit PORT CHANNEL UNITS` arguments for the same source annotation.
The authoritative channel meanings and publication contract remain with
JuliaFilterGraph's `schemas/catalog.toml` and `docs/source-channels.md`.

The current REVOLT Classic profile computes this packet in a separate optional
JFG analysis process. The required WFS/controller graph remains unchanged. Its
three inputs come from capacity-one copy/drop-oldest queues, and its summary
uses a separate capacity-one copy/drop-oldest output queue. The analysis graph
joins slopes, flux and validity by exact acquisition identity and PTS before
computing a summary. It uses ordinary CPU scheduling on CPUs 6/7, outside
required-owner admission; Classic's required control graph remains on its
existing CPUs. The initial profile has one analysis process, which can contain
several Algorithm nodes. Add more analysis processes when process isolation is
needed; each needs its own exclusive output queue.

The RTC submits the optional service under a locked invocation after checking
its own native Ready state and active invocation identity. The optional unit
uses systemd `Requisite` and `PartOf` relationships to the RTC, with no
`After=` ordering edge. Its ordinary CPU scheduling and separate lifecycle
keep it outside required-owner admission.

The GUI overlay's optional `native_products.summary` binding consumes the
same eight-element packet for its existing readouts and charts. It uses the
same summary schema and source; generic readouts and charts are unchanged.
Missing products make readouts unavailable; the GUI does not recompute them.
Scripts can subscribe to the same queue without any GUI connection. To omit
analysis, remove both `analysis` and `client.analysis` from the deployment
profile and reseal it. The supported recovery after an analysis failure is to
restart the RTC deployment. Manually restarting the optional systemd service
changes its retained invocation identity, so RTC cleanup fences that service
from cleanup.

This deployment uses locally registered JuliaFilterGraph 0.4.1, FilterGraphPipeWire
0.1.6 and PipeWireAORTC 0.2.5. See the [optional analysis validation scope](validation/optional-analysis-20261022/README.md)
and [independent review](reviews/20261022-optional-analysis/REVIEW.md) for
current evidence and limitations. The finite CPU gate passes 3,944 assertions
across normal, suspended, resumed, crashed and preparation-failure cases.
Existing sealed core queue modules remain stable for an invocation;
SDK factory creation is not atomic against manual queue replacement.

A `time_series` view can declare `xy_axes` with `x_index`, `y_index`, axis titles,
units and `equal_axes`. Both coordinates come from one admitted ndarray sample;
history, source selection and bounds reuse the ordinary time-series machinery.
Classic selects summary channels 6/7 for its WFS mean-slope trajectory, and
channel 2 for mean-flux history. Other RTCs declare their own matching sources
and schemas in their view profiles; no instrument-specific GUI handler is used.

Small frame reductions can fit existing graph owners. Expensive spectra,
long-run statistics, recording and calibration/reconstructor generation
belong in optional consumers behind bounded observation queues. The Classic
summary is now an optional separate analysis process. Such workers need no
additional RTC lifecycle authority, GUI dependency or data scheduler in the
runner. Device control and scientific feedback remain with their established
owners.

An optional observation service is a future integration point for shared
discovery, subscription delivery limits and a browser/WebSocket bridge.
PipeWire's registry remains authoritative, and existing bounded queues remain
the transport boundary. Observation delivery limits must preserve whole
measurement cohorts and their original sequence/PTS; they do not change the
control loop's sample rate. This service has not been implemented and is not a
new session owner or a prerequisite for native GUI operation.

## Optional simulator wavefront images

### Headless RMS measurements

With `optical_observation = true` and an atmospheric graph declaring both
`:atmosphere_opd` and `:pupil_opd`, the shared observer publishes
`simulator-wavefront-rms` (media
`wavefront-rms`). Its row-major F32 array has shape `(1, 2)` and schema
`org.calculon.ao.pupil-opd-rms.nm.f32/1`. Zero-based channel 0 is uncorrected
atmospheric pupil OPD RMS; channel 1 is corrected pupil OPD RMS. Both are spatial
population RMS in nm after subtracting pupil piston, using the same transmitting
pupil mask; tip/tilt remain included. This comparison includes all modeled
corrections in `:pupil_opd`. The atmospheric reference excludes any additional
non-atmospheric aberrations a future plant might introduce.

The producer captures both graph outputs before advancing the model. One bounded
cohort stays owned until both snapshots are transferred and consumed. Both RMS
values travel in one sample with the originating sequence, PTS and acquisition
generation, so independent observer drops cannot mispair the curves. No zero-DM
run, changed controller gain or second atmosphere simulation is used. The RMS
calculation runs in the optional headless optical worker, not the GUI or required
controller callback. Scripts and GUI clients can observe the same measurement
stream through an ordinary capacity-one copy/drop-oldest queue.

The RTC declares the immutable `pipewireao.ndarray.channels` source metadata for
this two-value packet. Its zero-based channels are
`uncorrected_atmosphere_rms` (title “Uncorrected atmosphere RMS”) and
`corrected_pupil_rms` (title “Corrected pupil RMS”); both declare `nm OPD`.
These names identify the existing values without changing their calculation or
frame representation. A graph without an atmospheric reference has no RMS
source and publishes no channel catalog.

Graphs without an atmospheric output retain their ordinary optical images and
do not advertise this comparison stream. No uncorrected value is synthesized.
The diagnostic is sampled at most 20 times per wall-clock second and is not a
full-rate telemetry recorder or cadence guarantee. Generic GUI time-series views
can select the declared channels. Source Header PTS gives wall-clock elapsed
time; a declared fixed model period times Header sequence differences gives
simulation elapsed time. The CPU development session advances model time more
slowly than wall time; the graph must label which basis it uses.

### Pupil image

`optical_observation = true` enables the shared AOS optical observer. It uses
the declared guide-sensor aperture and the completed `pupil_opd` graph output;
the GUI needs no instrument-specific rendering code. Alongside the ideal
focal photon-rate image, it publishes `simulator-residual-wavefront` with media
name `residual-wavefront` and schema
`org.calculon.ao.residual-pupil-opd.nm.f32/1`.

The optional `imaging` section in `simulation/definition.yaml` selects a named
entry from `sources` for ideal direct imaging. It can set `zero_padding` (integer
1–16; default 2). For example:

```yaml
sources:
  science:
    source_band: H
    source_magnitude: 2.0
    source_wavelength_m: 1.65e-6
    source_separation_arcsec: 0.0
    source_position_angle_deg: 0.0
imaging:
  source: science
  zero_padding: 2
```

Source photometry and wavelength are independent of the guide sensor. Imaging
uses the same completed pupil OPD, so its source direction must match the guide
source; a different line of sight requires a separately rendered pupil OPD.
Finite source height is not admitted by this declaration. With no `imaging`
section, the observer retains the exact guide source and padding 2. Both modes
publish cell-integrated focal photon rate, without detector exposure/noise,
long-exposure accumulation or a Strehl estimate. Cold session contracts use the
selected padding, so rebuilding updates ordinary focal-image port shapes.

The Float32 image contains pupil OPD in nm after subtracting the mean over
transmitting pupil samples. Tip/tilt remain included. Obscured and outside-pupil
pixels contain NaN. The generic ndarray viewer excludes these pixels from
scaling and measurements; its whole-image RMS is therefore the pupil
piston-removed wavefront error, with uniform sample weighting. This is simulated
optical truth, not a wavefront reconstructed from the detector.

Both images originate from the same bounded snapshot and carry its acquisition
generation, sequence and original WFS PTS. Each image source may drop snapshots
independently. Slow or absent GUI consumers cannot gate the WFS/control exchange.
Observation is capped at 20 snapshots per wall second and runs outside PipeWire
callbacks; the diagnostic is not a recording or timing qualification.

The application declares its ordinary image queue, source/sink shapes and link,
then places an existing ndarray view in the Simulator navigation group:

```toml
[[view]]
id = "residual-wavefront"
kind = "ndarray"
group = "simulator"
title = "Residual wavefront · nm OPD"
source = { node_name = "simulator-residual-wavefront-queue-output", media_name = "residual-wavefront" }

[view.egui]
open_on_start = true
preserve_square_elements = true
colormap = "viridis"
measurements = { scope = "whole_image", selected = ["root_mean_square"] }
```

The view group is presentation only. Array transport, metadata, rendering and
measurement selection use the existing interfaces for every simulator.

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
`session_*.jl` scripts are thin package entrypoints. REVOLT entrypoints
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
julia --startup-file=no --project=. session_cli.jl install \
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
The selected native RTC executable, application modules/scripts and generic
libwireplumber dependencies must be sealed with the
scientific assets. HIL and HEART exports select these assets from the installed
`--pipewire-prefix` by default (`/opt/pipewireao` on this host). Development builds
can supply both `--wireplumber-build` and `--wireplumber-source`. See the
[installed runtime](INSTALLED_RUNTIME.md) for build and validation details.
Calibration exports copy and validate the base package's sealed assets before
hashing. Python tools have been removed from this repository. Historical producer
records retain their original scope and Git source provenance.

## systemd session and owner services

For generic shared packages, `SessionRuntime.start!` installs a
fresh exact instance of `pipewireao-session@.service`, prepares separate scientific owner services, and
returns only after the admission hook completes. `ActiveState=active` alone
never proves scientific readiness. The manager verifies native owners and held
acquisition; the one-shot admission hook checks their actual placement.

The preparation helper renders ordinary user service files and an owner target.
It starts the private core, verifies its socket, then starts the FGN/JFG cohort
through one target transaction. It performs no frame processing and exits before
the headless RTC runs. HEART retains its necessary controller-PID launch stage.
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

## Streaming statistics and acquired artifacts

`array-statistics-f32` is an ordinary FilterGraphAlgorithms declaration for an
optional headless analysis graph. It accepts a complete Float32 array and
publishes equally shaped `mean`, `variance` and `stddev`, plus `(1,)` outputs
`sample-count` (UInt64), `complete` and `variance-valid` (Bool). Use the existing
pixel-calibration node to convert UInt16 camera data before statistics. Declare
the quantity at that boundary: calibrated pixels and raw camera codes are not
interchangeable. No calculation depends on GUI visibility.

The graph node has three modes:

| Configuration | Meaning | Cost for P elements and W frames |
|---|---|---|
| `mode = finite`, `window_samples = W` | Accumulate W accepted frames, freeze until reset | O(P) per frame; O(P) storage |
| `mode = sliding`, `window_samples = W` | Reconstruct statistics of the latest W accepted frames, including warmup | O(PW) per frame and storage |
| `mode = exponential`, `time_constant_s`, `sample_period_s` | EWMA and central exponentially weighted population variance | O(P) per frame and storage |

Finite/sliding variance uses N−1; `variance-valid` is false before two samples.
Exponential variance initializes to zero with the first sample and is a weighted
population variance, with no unbiased correction. Its fixed accepted-sample
weight is `α = −expm1(−sample_period_s / time_constant_s)`; this is not a
timestamp-aware estimator for irregular arrivals. Configure the nominal accepted
cadence explicitly. Nonfinite inputs or unrepresentable outputs reject before
adopting history. The current implementation is CPU-only. Storage is preallocated
and bounded by `max_state_bytes` (default 256 MiB). Sliding reconstruction avoids
cancellation after large level changes; prefer finite acquisition or exponential
tracking for large images when retaining/revisiting W images is too expensive.

For example, place this node in a native SPA-JSON analysis graph, deriving
`size` from the instrument as for the existing WFS analysis declarations:

```text
{ type = ndarray name = statistics label = array-statistics-f32
  config = {
    size = { "$ref" = "/instrument/wavefront_sensors/shwfs/layout/detector_shape" }
    mode = finite
    window_samples = 512
    input_schema = "site/calibrated-detector-f32/1"
    mean_schema = "site/detector-mean-f32/1"
    variance_schema = "site/detector-variance-f32/1"
    stddev_schema = "site/detector-stddev-f32/1"
  }
}
```

The `site/` identifiers are illustrative quantity contracts, not new built-in
schemas. Use the source/target declarations' actual identifiers. Mean/stddev
retain the input units; variance has squared units. Explicitly export the six
outputs. Existing ndarray panels can display the published arrays; scalar or
named-vector reductions can feed existing charts. No instrument-specific renderer
is needed. Window changes rebuild this optional graph; reset starts a new window.

To register a finite acquisition automatically, add `capture` to the existing
analysis YAML. The following fragment assumes all outputs retain their names:

```yaml
capture:
  label: Detector mean candidate
  scope:
    session_label: selected-instrument
    graph: selected-controller
    parameter: background
  products:
    mean: mean
    variance: variance
    stddev: stddev
  units:
    mean: adu
    variance: adu^2
    stddev: adu
  sample-count: sample-count
  complete: complete
  variance-valid: variance-valid
```

Set scope, schema and units to match the declared parameter exactly. Mean is
required; variance/stddev registrations are optional. A finite graph's outputs
must come directly from the same statistics node, including named export aliases.
Sliding/EW outputs cannot masquerade as a completed finite acquisition. `complete`
must arrive at exactly the declared count. Snapshots are limited to 64 MiB total.
The observer copies once and releases an immutable snapshot to a control task;
FITS creation, Git and SQLite run outside frame processing. There is no automatic
application, sign change, unit conversion or startup selection. Each product is
a separate registration; partial failures preserve successful IDs in the receipt
and are not automatically retried.

Registered results appear through the existing catalog, including its GUI helper.
Reload the catalog, select a compatible artifact for a transaction target, and
submit through the normal RTC path. Variance/stddev use their own schemas and
units and are not compatible reference vectors. FITS BUNIT is preserved so GUI
unit checks use the same preparation contract as file imports. Mean gradients
that already have a reference subtracted are residuals; they are not an absolute
replacement reference without the existing calibration procedure's baseline and
sign treatment. Registration alone does not establish scientific acceptance.

Acquisition counts accepted analysis frames, not guaranteed contiguous camera
exposures: observation queues deliberately copy/drop-oldest rather than block
the controller. The artifact records source endpoints, graph hash, first/last
source sequence, sequence gaps, count and available acquisition domain/generation.
Missing/mismatched headers, reset/invalidation during collection, nonmonotonic
sequences, or changed identity reject capture. No invalid/missing samples are
silently counted as zero. General per-element validity masks are not implemented;
select/qualify the intended finite input upstream.

After completion, the graph republishes its frozen result with the current
input's header; that header does not describe the whole aggregation window.
Use the captured artifact metadata for window provenance. One capture is allowed
per analysis owner incarnation. The ordinary Julia entrypoint remains:

```julia
using PipeWireAORTC
PipeWireAORTC.Analysis.main(["--config", analysis_configuration,
    "--remote", private_pipewire_socket])
```

Use existing optional-service configuration to launch it with separate CPU
placement and copy/drop-oldest observation queues. There is no new calibration
protocol or GUI acquisition wizard. A configured capture writes
`NAME-capture.json` under `PIPEWIREAO_RUNTIME_DIR` with `registered`, `rejected`,
`incomplete` or `registration_failed`, plus any retained artifact IDs. Existing
analysis configurations without `capture` retain their behavior.

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
    units=reconstructor_units,
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

New `SessionConfiguration` configurations include the RTC-owned asynchronous
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

## Simulator startup settings and rebuild

`PipeWireAORTC.SimulatorConfiguration` is the headless implementation used by
Julia scripts, the CLI and generic GUI Simulator Settings. The plant package
declares `describe_hil_settings()` metadata for its strict startup builder.
The selected application's pinned environment supplies that declaration and
performs physical validation; the GUI contains no instrument prescriptions.

For an explicitly selected managed session:

```julia
using PipeWireAORTC: SimulatorConfiguration

settings = SimulatorConfiguration.describe(session_id)
proposal = deepcopy(settings["settings"])
proposal["atmosphere"]["r0"] = 0.20
proposal["atmosphere"]["wind_speed"][1] = 8.0
receipt = SimulatorConfiguration.start_rebuild(session_id,
    settings["configuration_sha256"], proposal; resume_running=true)
progress = SimulatorConfiguration.job(receipt["id"])
```

Preparation first verifies the original sealed assets and warms the candidate
on its declared backend. Invalid values leave the old session running. Only
then does the one-shot job request native RTC Quit, verify exact cleanup,
and start a fresh installation/invocation. A completed receipt names the exact
replacement discovery locator. Select it through the ordinary native session
client; a saved receipt does not prove that the session is still available.

Cold replacement resets controller and simulator state and reloads saved startup
gains and calibration. It does not preserve unsaved live property/artifact edits.
Profile and pupil resolution are read-only in this atmosphere-editing increment;
changing those requires corresponding calibration and a separate deployment.

For the native GUI, set `PIPEWIREAO_SIMULATOR_COMMAND` to the JSON argv array
that runs Julia in the same registered application environment:

```julia
using JSON3
command = [Base.julia_cmd().exec[1], "--startup-file=no", "--project=" * application,
    "-e", "using PipeWireAORTC; PipeWireAORTC.SimulatorConfiguration.serve()"]
println(JSON3.write(command))
```

Mark the simulator's existing `node_properties` view with
`simulator_settings = true` in its operator-view declaration. Its Display remains
status/metadata; Settings contains the declared scalar controls and per-layer
array table, drafts, Apply and restart, progress and explicit reconnect.
Other instrument packages opt in through the same declaration and builder
contract; no GUI handler is selected by instrument name.

Jobs are owned by finite systemd user oneshots and survive GUI/helper exit.
Their bounded records default to `~/.local/state/pipewireao/simulator-settings`
(or `$XDG_STATE_HOME/pipewireao/simulator-settings`); an explicit
`PIPEWIREAO_SIMULATOR_ROOT` selects an isolated root. Each retains the old exact
identity, immutable request, candidate, preflight logs, shutdown/startup receipts
and final result. A failed/unknown effect is never retried or rolled back
automatically. Use the retained original application for explicit recovery.
Archive completed records explicitly before reaching the 256-record limit.
The saved Git artifact catalog and SQLite journal are not changed by this tool.

## Managed external-pupil applications

`AOSOwner.main` accepts a version-4 `mode: external-pupil` configuration through
its ordinary native bootstrap. The strict fields are `version`, `mode`,
`plant: {definition, settings, chopping?}`, `pupil_node`, `sensor_nodes`, `backend`, `device`,
`instrument`, `rtc_configuration`, `calibration_identity` and
`prescription_identity`. `sensor_nodes` names every physical optical path.
The instrument has zero deformable mirrors and empty mirror controls; it does
not acquire a synthetic DM or controller command boundary. CPU uses device 0;
AMDGPU uses an explicit positive device ordinal. Export prepares port contracts
on the CPU, without importing a GPU package.

The source publishes Preparing before optional scientific imports, then Prepared
and Connected through the existing bootstrap. Connected starts held. Native
SourceControl run/pause/reset and bootstrap Quit retain their existing meanings.
Reset requires a held source and serialized input processing; it clears pending
transport admission, partial exposures and detector history, increments output
generation and permits a new input domain. No second session supervisor is used.
For a composed session the native authority holds all sources before reset,
starts consumers, then auxiliary sources, and starts the primary source last.

`InstrumentExport.external_pupil_port_contracts(definition; settings)` supplies
cold pupil/sensor shape, element type and schema declarations. The pupil is one
row-major Float32 `(quantity,y,x)` packet: OPD in metres, then relative amplitude.
GPI's `PupilOutput.pack!` converts its native `[x,y]` arrays into this packet;
a direct copy of those arrays changes orientation. Sensors use their own exposure
cadences and acquisition metadata. Relative-intensity schemas include a
prescription/branch/sampling/shape hash before the final `/1`; node properties
retain wavelength, bandpass, sampling, axes and exposure units. Declared detector
responses keep their explicit frame schema. Input model time owns exposure
integration; the external-pupil source has no wall-pacing field.

An optional `plant.chopping` mapping explicitly selects an alternate static graph
for each chopped physical path:

```yaml
plant:
  definition: generated/simulation.yaml
  settings: {}
  chopping:
    scc:
      unfringed_graph: scc_unfringed
      initial_phase: fringed
      trigger_high_is_fringed: true
```

The ordinary branch graph is fringed. AOS selects the two static graphs at its
model exposure boundaries and reports the completed exposure's actual optical
kind. RTC maps that kind through the explicit trigger polarity into Acquisition
Version 3. It never derives optical kind from received-frame parity. Missing
whole windows remain visible: for these chopped outputs only, acquisition and
Header sequence equal `pts / duration + 1`, requiring aligned, nonnegative model
time and positive duration anchored at zero. AOS's emission counter remains
internal. Ordinary sensor sequence and Version 2 behavior are unchanged.

Authored `simulation/definition.yaml` may declare `preparation.variants` as
`{name: {branch, settings}}`. The shared Zemax generator prepares each variant
through its physical branch and records `optical_model.variants` in generated
execution data. Settings are reapplied to the base branch before the authored
variant override. Generated graph/provenance files remain generator-owned.

The SCC graph owner selects `--acquisition-version 3` and
`--chopped-warmup PATH`. This bounded version-1 YAML declares `input`,
`exposure_duration_ns` and `trigger_high_is_fringed`. Its unpublished F/U/F
sequence requires exactly `SccPixelResidualIncompletePair`, then two successful
physical outputs. Preparation ends with pair history reset and outputs
unavailable; the first live exposure must prime again. Retained last-product
metadata is inspection history, not evidence of publication. This CPU graph
preparation does not qualify cadence, GPU graph execution or a coupled loop.

### Managed clocked pupil source

A version-5 `mode: pupil-source` simulation configuration selects a named,
non-HIL AOS graph through `plant: {definition, graph, settings}`. It declares
`command_input`, the physical `mirror`, integer model `rate`, independent
`pacing_rate_hz`, and explicit `backend`/`device`. The ordinary exporter fills
`instrument`, `rtc_configuration`, `calibration_identity` and
`prescription_identity` from the selected source and RTC declarations. The
command input must bind that existing physical mirror's `pdm_command` in metres
OPD. Its count and command-order identity come from the physical description;
they are not inferred from another stream. Its array binding must be exclusive
to that input, including graph parameters, delayed initial values and node
construction bindings. The declared pupil is either that
mirror's direct surface OPD, or the existing additive pupil composition with a
direct mirror surface input and an independent residual dependency closure,
including delayed links. Scaling, transpose or further propagation on that
route requires separate calibration. Exact transfer checks concern the physical
DM operator; residual-plus-surface subtraction is subject to Float32 rounding.
No camera, full GPI frontend or CAL2 mirror is created.

The existing AOS owner requires `--physical-offsets PATH`, three default Julia
threads and an explicitly placed pupil-output worker. It owns the named graph,
model clock and physical command buffer. A version-2 receiver contract contains
only `version`, `command_limit_m`, `projection`, `inverse`,
`calibration_identity`, `command_order` and `branches`. P/Q use the existing
hashed, typed FITS descriptors; branch schema, explicit disjoint modes, command
and coefficient limits, model age, wall silence and optional acquisition version
retain their version-1 meanings. No C matrix or receiving graph parameter is
invented. Loading this adapter needs HIL, without loading FGA, FGP or JFG.

Preparing warms a real graph step and pupil packing without publication, then
resets the graph, command and model phase. Ready holds zero. Run polls each
branch without waiting, expires invalid contributions, sums the admitted
absolute vectors on the source task and advances its own model clock. Missing
controller output, including chopped priming, does not stall the source.
Snapshots carry the actual source sequence and model interval; a busy serializer
may leave a visible publication gap. Pause freezes new steps at its acknowledged
committed cursor. An already committed snapshot or packet at or below that
watermark may finish; Run resumes the same generation and clock. Held Reset
flushes inputs/output, fences old branch cohorts, clears commands and starts a
new source generation at model time zero. Quit closes the existing owned streams
and worker. This is a simulation owner, not physical device qualification.

Optional `applied_command_observation: true` reuses the existing
`simulator-<mirror>-applied` source and
`pipewireao/applied-dm-command-opd-um-f32/1` schema. After each successful model
step it publishes the adopted total in micrometres OPD with that tick's actual
model interval and source identity. A preallocated conversion and owned staging
copy do not borrow a concurrently changing command. Its fixed three-buffer pool
supports the existing capacity-one copy queue; absent or slow observers never
gate the model. This observes model input adoption, not mechanical settling.

The v4 external-pupil owner accepts optional `sensor_buffers: 2` (integer 2:64).
Omission retains its two-buffer sensor pools. Capacity-one observation queues
require at least three producer buffers; select `sensor_buffers: 3` explicitly
for both optical outputs. The pupil input and scientific pupil output pools keep
their existing allocation contracts.

The v4 external-pupil owner also admits an explicitly selected CUDA device
(ordinal zero or higher); AMDGPU ordinals start at one and CPU uses zero.
Metadata parsing and hash checks do not import accelerators. Backend availability
and the actual optical/DM algorithms remain execution-time checks.

### Sealed composition and feedback preparation

Portable instrument profiles may select `application: rtc/standalone/application.yaml`.
The default remains `rtc/application.yaml`. The selected YAML file must remain
inside the instrument source; its sibling `modes.yaml` and `core.conf` define its
application modes and native core modules. Asset references remain relative to
the instrument root. Owner lists start from the selected application, so an
alternate application need not inherit the default controllers or queues.
The generated runtime declaration remains `rtc/application.conf`.

`InstrumentExport.compose(base, component, fresh_output; namespace, roles,
links, overrides, prefix, owner_arguments=Dict(), sinks=[], node_owners=Dict())`
combines fully sealed built applications. The base retains its core, session,
primary source and instrument definition. Component files remain byte-for-byte
under `components/<namespace>`; mapped component owners join the base session,
with its source declared as an auxiliary source. Owner asset arguments and
bootstrap identities are rebased; the selected registered runtime remains
shared. Nonempty explicit asset overrides and optional complete base-owner
argument replacements are recorded in the final seal and composition receipt.
Project/Manifest replacement, including a nested runtime project, is prohibited;
the final registered dependency closure is revalidated before publication.
This API does not compile a graph variant or launch processes.

Component nodes explicitly owned by their private `core`, including native
telemetry queue endpoints, retain the shared `core` owner after composition.
Both input applications and the merged result validate those names against
their native core declarations. External owners still require an exact `roles`
mapping. Explicit queue endpoint names must remain unique across merged queues
and native context objects; identical shared declarations are deduplicated.

`InstrumentExport.prepare_feedback(base, component, fresh_output, recipe;
prefix, profile=nothing)` performs the scientific preparation before composition.
Its authored recipe selects the receiving graph template, added FITS bindings,
physical-offset contract, owner/thread arguments, component roles and exact links.
The component already contains an accepted generated calibration selection and
an exact-zero startup command. Preparation checks every branch's identity,
acceptance, diagnostic/deployable flags and shared P/Q/C hashes. It matches C's
upstream effective settings, ADC configuration, simulator graph identities,
frontend dependency closure and original FITS hashes to the actual base.
The component's generated RTC descriptor binds its file hash, calibration context
and identity to the source owner's actual `simulation.conf` selection and the
accepted index. The lifecycle selector uses the same cold validation.
It binds physical command order from the declared mirror layout and units.
The staged final graph is prepared with all typed FITS mappings, then
`PhysicalOffsets.prepare` verifies factors, sign, offset route and zero startup.
Only a passing staged application becomes the requested output.

Each receiving branch may explicitly select `acquisition_version: 2` or `3`;
omission preserves Version 2. This must match its actual native producer. A
chopped SCC graph forwards Version 3 to its physical-offset output, so its
receiver selects 3 while ordinary LLOWFS may retain 2. Admission remains exact;
the receiver does not downgrade or reinterpret metadata versions.

The receiving graph uses three default Julia threads: native graph execution,
bootstrap monitoring and the offset pump. An explicit preparation profile
selects the already-built component CPU or AMDGPU backend/device, primary-source wall
pacing and each receiver branch's monotonic silence limit. It does not select
controller gains or accept a rejected calibration. Source `pacing_rate_hz` accepts
finite rates from zero to model rate, including fractional rates; zero disables
wall pacing. Integer-rate rounding is retained. Model sample rate, PTS and
exposure duration remain independent of wall pacing. Model-age limits and
monotonic silence limits remain separate.

Version-1 profiles may independently select the already-built primary producer
with `upstream: {backend: cpu, device: 0}`. Without `upstream`, the root backend
and device must match both applications, preserving existing profiles. Both
selections permit CPU/device 0, CUDA/a nonnegative device ordinal, or AMDGPU/a
positive device ordinal. The
actual producer must still satisfy the selected reference calibration's backend
qualification; Host expected-reference calibration requires CPU upstream.
For example, an AMDGPU optical consumer with a CPU producer selects:

```yaml
version: 1
backend: amdgpu
device: 1
upstream: {backend: cpu, device: 0}
pacing_rate_hz: 1
silence_ns:
  llowfs: 10000000000
  scc: 30000000000
```

This selects existing sealed execution configurations; it does not change either
backend or import GPU packages during validation. The shared registered runtime
must already supply every component direct dependency with identical compatibility
bounds and frozen Manifest records. An AMDGPU consumer therefore needs AMDGPU in
the shared runtime Project and Manifest, even though its CPU producer does not
load that package.

The ordinary build host profile can explicitly request `runtime-backends:
[amdgpu]` alongside `simulation: {backend: cpu, device: 0}`. This uses the existing
generated-Project writer to promote the source's declared optional AMDGPU package
without changing the simulation selection. The list admits distinct `cuda` and
`amdgpu` names only. Every explicitly requested package must already have its
canonical UUID and nonempty compatibility declaration in source metadata; missing
or conflicting declarations reject. Omitting the list retains ordinary backend
selection. The supplied registered Manifest must resolve the promoted dependency;
the build neither resolves missing packages nor imports an accelerator merely to
prepare this environment. Use the same frozen registered GPU dependency closure
for the CPU producer and AMDGPU component before feedback composition.

The instrument repository's `tools/calibrate-optical.jl`, `tools/compose.jl`,
`tools/prepare-feedback.jl` and `tools/materialize-calibration.jl` are thin clients
of these shared APIs. An optical-calibration mode can first seal the model and
authored branch templates without selecting controller graphs or FITS bindings.
The calibration publisher resolves those templates using its measured masks and
real matrices; accepted materialization then enables the ordinary controller build.
These tools prepare fresh artifacts; they do not install or start a session. A composed
application is software preparation, not evidence of a running native cohort,
closed-loop acceptance or deadline performance. See
[optical calibration selection](CALIBRATION_METHOD_USAGE.md#optical-branch-calibration-and-generated-selection).

A standalone composition selects `receiver.kind: pupil-source` with exactly
`owner`, `mirror`, `rtc_configuration`, `simulation_configuration`, `template`
and `configuration`; graph-template, parameter and C fields are absent. The
shared `prepare_feedback` entry point validates every selected CAL2 branch and
its P/Q hashes. It reconstructs the original calibrated mirror/settings and
requires exact Float32 OPD equality at zero and every accepted P column, with
matching physical description/order, pupil contract, amplitude and support.
Cross-prescription reuse requires the original definition and recorded executed
settings; the new source prescription identity remains distinct.

Preparation makes an intermediate sealed base with a generated selection under
`generated/physical-offset-calibration`, retaining the original deployment,
simulation, RTC and publication bytes. The selected RTC, publication and source
configuration explicitly use the accepted P/Q calibration identity. The final
normal composition binds that selected descriptor plus the original descriptor
hash, both prescription identities and response comparison in its receipts.
The generic compositor continues rejecting arbitrary publication overrides.
This prepares a reviewable application and launches no process. Matched noisy
loop, accelerator and physical-device qualification remain separate gates.
