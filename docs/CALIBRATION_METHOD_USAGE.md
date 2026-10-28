# Instrument calibration

## Built-application calibration bundles — 2026-10-26

`PipeWireAORTC.InstrumentCalibration` provides one shared API for calibration
procedures selected from a built instrument application:

- `calibrate_system(application, fresh_bundle; target=...)` reads the compiled
  instrument recipe and dispatches to the declared sensor procedure.
- `validate_system(application, bundle, fresh_report; target=...)` checks that
  the selected recipe matches the bundle before finite model validation.
- `stage_calibration(source, application, bundle, fresh_destination)` verifies bundle and
  source identities, then copies the authored source and selects the calibrated startup context
  in a fresh destination.

The version-1 bundle contains `result.yaml`, `context.yaml`, concrete
`graph.conf` and typed FITS files in `artifacts/`. The result hashes context,
graph and artifacts. Git retains earlier selections and provenance; staging
does not copy archive directories or create `history_sha256` manifests.

Calibration context uses the existing FITS binding terms: a `kind: fits` entry
declares `path`, `hdu`, `axes`, logical `shape`, `type`, `sha256` and
`storage_order: row-major`. Paths are relative to `context.yaml`. Cold preparation
checks one bounded file snapshot and resolves it to a flat typed row-major
vector. Boolean values must be exactly zero or one. The context remains a small
declaration; GPI2 construction and runtime use the same `pupil-mask.fits` bytes.
RTC configuration selects `calibration/context.yaml`, without a duplicate
`rtc/calibration.yaml`. The regular instrument graph still supplies topology.
Generated YAML writes short numeric vectors inline, including coordinate pairs,
shapes, axis orders, limits and filter sections. Vectors exceeding eight elements
or 80 characters remain block lists. This changes presentation and byte hashes,
not parsed values; bundle writers calculate hashes after serialization.

The current built-application procedures run simulation calibration in process;
they are not a deployed, native event-driven calibration campaign. That campaign
still needs a command-only probe input through the regular graph's existing
completion and constraint chain, plus confirmation of actual command adoption
before exposure. Frame-driven offset updates and their submission replies do not
supply that confirmation. GPI2 additionally needs coherent held probes across
named correctors; multi-WFS capture needs explicit association across required
sources. Existing bundle integrity and finite numerical checks do not qualify
those missing transport capabilities.

An explicit import retains its original source prescription under
`imported_source_prescription_identity` when adopting a changed model or metadata.
`source_prescription_identity` associates the selected, replay-verified bundle
with its current prescription. The receipt's origin and Git source record must
distinguish adoption/replay from a new acquisition; an identity update alone
does not establish scientific equivalence.
`read_bundle` verifies these bytes without loading a sensor or accelerator;
sensor procedures own array interpretation and optical checks. Authored recipes
live in the instrument source at `calibration/recipe.yaml`. Its `graph_source`
selects the retained authored graph template; `graph` selects the compiled
execution graph for typed contracts. Both are carried in the built application,
and calibration
consumes the built application. CLI commands follow the same flow:

```sh
julia --project=/path/to/environment tools/calibrate.jl APPLICATION FRESH_BUNDLE [cpu|cuda|amdgpu]
julia --project=/path/to/environment tools/validate-calibration.jl APPLICATION BUNDLE FRESH_REPORT.yaml [cpu|cuda|amdgpu]
julia --project=/path/to/environment tools/stage-calibration.jl SOURCE APPLICATION BUNDLE FRESH_DESTINATION
```

The modal-only API names and CLIs and the active Classic TOML result loaders
have been removed. Imported selected bundles retain historical source identity
and support startup/integrity checks; import does not rebind them for the new
validation/staging sequence. Fresh acquisition supplies that sequence's
matching source and recipe. Staging requires the authored source separately:
expanded session, GUI and host files in a build are not reversible authoring. Use a source-validation environment containing the
matching RTC implementation until its coordinated registered release is
available. Application environments continue to use registered package
releases. The [2026-10-26 migration evidence](validation/standard-calibration-20261026/README.md)
records the validation results and limits.

## Simulation modal temporal coefficients

The optional pyramid recipe `temporal` block selects a first-order low-pass
filter for the existing tip/tilt temporal cascade:

```yaml
temporal:
  tiptilt:
    kind: lowpass
    cutoff_frequency_hz: 25
```

Unknown fields in either temporal object are rejected. Omitting `temporal`
preserves the identity filter. Modal coefficients retain their identity default.
The command sample rate is `1 / frame_period_s` from the simulation declaration;
the stage and woofer execute at that common rate. The calibration receipt records
the declared period, derived sample rate and selected tip/tilt filter.

`InstrumentCalibration.lowpass_coefficients(Float32; cutoff_frequency_hz,
sample_rate_hz)` prepares coefficients without recalculating optical matrices.
`Float64` is also supported. It returns FGA's five normalized coefficients
`(b0, b1, b2, a1, a2)`, with denominator `1 + a1*z⁻¹ + a2*z⁻²` and `a0 = 1`.
For cutoff f꜀ and sample rate fₛ, the prewarped bilinear transform is:

```text
k = tan(π f꜀ / fₛ)
a1 = (k − 1) / (k + 1)
b0 = b1 = (1 + a1) / 2
b2 = a2 = 0
```

The numerator is normalized after the pole is rounded to the requested
precision, retaining unity DC gain. Before rounding, the magnitude at f꜀ is
1/√2 (−3.0103 dB). Both frequencies must be finite and positive, with f꜀ < fₛ/2;
a pole that rounds onto the unit circle is rejected. A representable pole near
that boundary can still shift the cutoff through finite precision.

The instrument graph owns command allocation: filtered tip/tilt correction is
clamped, its actual command minus its offset is projected into woofer coordinates,
and that projection is subtracted from the woofer demand. Before constraints,
the temporal paths sum as H(z) + (1 − H(z)) = 1; clipping spills unmet stage
correction into the woofer command. This command identity does not establish
optical equivalence, feedback stability or hardware bandwidth.

## Simulation command response

A simulation declaration may attach a response to an existing named vector
input. This compiles to an ordinary native AOS node before the original input
destination; it does not introduce another executor or a slower command loop.

```yaml
responses:
  tiptilt:
    kind: second_order
    natural_frequency_hz: 250
    damping_ratio: 0.7
    schema: {$ref: /schemas/tip_tilt_opd_coefficients_m/id}
```

The name selects a declared production graph input. Its binding supplies the
coordinate count; `frame_period_s` supplies the sample period. The vector must
be Float32 and retain the same scientific schema. Unknown fields, absent input
names and conflicting generated node names are rejected. Omitting `responses`
preserves the ideal plant. The example values are provisional assumptions,
not a measured transfer function or a generic instrument default.

AOS advances y″ + 2ζωₙ y′ + ωₙ²y = ωₙ²u using exact zero-order-hold
discretization. The output is the position at the end of each hold interval;
there is no additional pure delay. Position and velocity reset to zero without
replacing storage. The configured period must match the simulation and native
application cadence before execution.

The calibration graph deliberately retains its static optical response. This
reuses a unity-DC spatial calibration and does not measure temporal dynamics.
Production prescription identity includes the added response node; an old
calibration receipt must not be silently relabelled as a new measured model.
Controller command clipping bounds demanded inputs. Inertial overshoot of the
simulated response is distinct from command clipping and is not implicitly
clamped. Adopted-command observations also remain distinct from achieved
mechanical response; offline validation records both separately.

## Scope

`REVOLTRTC.jl/bin/calibration_method.jl` acquires one declared probe basis through the
same deployed, completion-driven Classic CPU DM/WFS path as the zonal campaign.
It publishes an **unaccepted response candidate**. It does not select a
reconstructor, update the controller or establish scientific equivalence.
AdaptiveOpticsCalibration owns probe construction and numerical estimation;
Julia owns export, session launch and evidence collection; WirePlumber owns
session lifecycle and systemd supervises processes. The former Python
entrypoint is retained only in [Git history](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/deployment/calibration_method.py);
historical evidence below retains its original producer.

The existing campaign recipe supplies reference, physical amplitudes, exposure
count, settling, detector seed/settings and timeouts. The input must be a
maintained recorded-input Classic CPU package with explicit finite background,
reference slopes and active mask. Retain the same qualified startup inputs when
comparing methods. No missing calibration input is replaced by zero.

## Method declaration

A version-1 JSON object requires `version`, positive integer `run`, and `order`
(`forward` or `reverse`). Optional `probe_basis` selects one of:

| Kind | Required additional fields | Estimated coordinates |
| --- | --- | --- |
| `zonal` | None | Physical actuators |
| `hadamard` | None; recipe supplies physical amplitudes | Physical actuators, complete decoder cycle |
| `modal` | `positive_commands`, `mode_amplitudes` | Supplied mode directions |
| `spatial_sine` | `actuator_positions`, `spatial_frequencies`, `mode_amplitudes`, `normalization`, `minimum_sampled_peak` | Sampled sine/cosine directions |

Omitting `probe_basis` preserves the original zonal client behavior. Modal
`positive_commands` is a JSON array of rows: one positive physical delta per
mode, in the exact 277-actuator command order. Values and mode amplitudes are
in µm OPD. Spatial geometry has 277 rows of two coordinates; frequency rows
contain two components in cycles per geometry coordinate unit. The public
constructor emits sine/cosine pairs in declared frequency order. Preserve the
geometry units and physical order in the input method file.

Example for complete Hadamard acquisition:

```json
{"version":1,"run":101,"order":"reverse","probe_basis":{"kind":"hadamard"}}
```

For Classic's 277 physical coordinates, a complete Hadamard decoder requires
512 positive and 512 negative batches. A partial set cannot use that decoder.
Modal/spatial outputs are measured directional secants. They are not a measured
full physical interaction matrix. Their actual rounded command basis and
coordinate labels accompany the result; rank, representation and linearity
checks remain separate scientific gates.

## Run

Use new output and runtime paths outside the source package and AOC checkout:

```sh
julia --startup-file=no --project=../REVOLTRTC.jl ../REVOLTRTC.jl/bin/calibration_method.jl \
  --base-package /path/to/qualified-classic-recorded-package \
  --recipe /path/to/shared-recipe.json \
  --method /path/to/method.json \
  --output /path/to/new-method-evidence \
  --runtime /path/to/new-runtime \
  --aoc-source /path/to/AdaptiveOpticsCalibration.jl
```

The maintained launcher currently uses `/opt/pipewireao`. Parent CPU affinity
must admit every configured process/thread placement. Exclude CPU 0/1 through
the deployment placement and an encompassing parent mask, rather than pinning
the whole launcher to one helper core. Cold reduction is outside the RTC path.

## Outputs and failure behavior

The owner copies input recipes, method declarations and orchestration sources;
it freezes source/package identities, canonical and chronological plans,
permutation and helper/client hashes before acquisition. It checks unchanged
identities again after restoration, release and public shutdown. Receipts are
validated in acquisition order before numerical response rows are reordered.

`method-result.json` retains preparation, startup readiness, acquisition,
shutdown, reduction and total durations. Failed preparation/acquisition remains
recorded and cannot publish a successful candidate. `candidate-response.json`
binds a measurement-by-estimated-coordinate ROW_MAJOR F32_LE payload, units,
actual basis, canonical order, source identities and completion records. It
labels acceptance as none. Matrix dimensions and a finite result alone are not
scientific acceptance.

[Method review and comparison design](CALIBRATION_METHOD_COMPARISON.md) records
software review, pilot evidence and the remaining method-selection gates.
[Quality validation](CALIBRATION_QUALITY_VALIDATION.md) records the independently
qualified baseline against which methods will be compared.

## Qualification record

This section records the earlier Python-owned workflow. Current Julia migration
qualification is tracked in the
[migration record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md).

The maintained owner completed a Classic FGN CPU reverse-modal smoke on
2026-10-03: two declared physical directions, four signed batches, 16 accepted
frames per batch. Chronological order `[4,3,2,1]` was validated before canonical
estimation. The candidate is 376×2, explicitly `mode_direction`, and unaccepted.
Restoration, release, public shutdown and launcher exit 0 all passed.

Preparation took 5.861 s, startup readiness 49.269 s, acquisition 12.182 s,
shutdown 1.005 s and cold reduction 4.076 s (total 72.451 s). These are one
CPU simulation/integration run, not an estimator performance ranking or a
calibration cadence guarantee. Startup includes cold compilation. An earlier
attempt deliberately retained as failed evidence was rejected before launch
because the encompassing affinity mask admitted only CPU 5; it emitted no
frames. Eight focused Python tests and 56 Julia assertions passed independently;
the complete deployment suite ran 163 tests: 161 passed and two were skipped
because their external fixtures were unavailable.

Evidence is retained under `~/.cache/rtc-calibration-quality-20261003/` in
`method-smoke-reverse-v2/`, `method-smoke-reverse/` and `method-owner/`.
The evidence ledger binds their material inputs, outputs and failed prelaunch
record. This qualifies the finite workflow and ordering behavior. Subsequent two-sweep
zonal, complete Hadamard, 221-coordinate controller-modal and 64-mode spatial
runs also completed through this entry point. Their finite prediction, energy
and timing results are in [method measurements](CALIBRATION_METHOD_VALIDATION.md).
Candidate completion does not select a new method or inverse; fresh common
validation and a locked test remain necessary for that decision.

## Optical branch calibration and generated selection

`InstrumentCalibration.calibrate_optical(upstream_built, optical_built,
fresh_bundle; concrete_graphs, contexts, recipe="calibration/optical.yaml",
target=...)` consumes sealed built applications and explicit concrete branch
graphs/contexts. The shared optional calibration extension owns numerical
acquisition and AOC inversion. The callback path uses the actual native
`PupilOutput.pack!` orientation, then packet `[quantity,y,x]` planes, for the
external optical input. A direct GPI `[x,y]` copy is not equivalent.

Publication emits one standard bundle per branch and a `calibration.yaml` index.
The index hashes each branch result and the common command projection P, physical
to modal inverse Q, and optional upstream reconstructed-reference response C.
Each branch measures the full shared mode response before applying its authority.
A deployable result passes rank, derivative, reconstruction and held-out gates,
plus the native UInt16 upstream reference checks when selected. Diagnostic
results retain `diagnostic: true`, `deployable: false`; optical acceptance alone
does not produce a deployable matched-feedback calibration. Camera, ADC and
simulator effective settings are part of the selected C provenance. Changing
brightness, readout settings, frontend nodes or their FITS bindings requires
matching calibration. Neither a relaxed gate nor a diagnostic dither is an
implicit production selection.

`InstrumentExport.materialize_calibration(source, built, accepted_bundle;
graphs, provenance, prefix, destination="generated/calibration",
rtc_configuration="rtc/configuration.yaml",
simulation_configuration="simulation.conf", recipe="calibration/optical.yaml",
zero_command="physical-offset-zero.fits")` selects those accepted bundles in
an authored instrument source. All validation precedes writes. It checks the
sealed built input, recipe/source/provenance hashes, branch acceptance and shared
identities, then verifies that the context reproduces each authored graph.
The generated destination must be fresh. Standard branch bundles are copied
unchanged; a shared context, exact-zero Float32 physical command and selection
receipt are generated there. The supported writer updates the authored RTC's
selected calibration path and identity. The optical recipe stays authored and
unchanged. Generated bundles, contexts, FITS headers and recorded hashes are
never edited by hand.

A selected numerical result still has `application_accepted: false`. Rebuild the
application from that source with a named profile and explicit host declaration,
then use [feedback preparation](JULIA_DEPLOYMENT_USAGE.md#sealed-composition-and-feedback-preparation).
Native cohort, simultaneous-loop and failure acceptance follow separately.
