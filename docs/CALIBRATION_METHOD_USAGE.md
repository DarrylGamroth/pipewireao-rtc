# Selectable Classic calibration acquisition

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
