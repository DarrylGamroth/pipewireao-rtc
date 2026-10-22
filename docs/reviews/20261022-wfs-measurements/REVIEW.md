# Headless WFS measurements and generic X/Y — independent review

Date: 2026-10-22. Disposition: **accepted for the finite CPU software/transport
gate and the scoped live CPU deployment check**. WFM-003/004 are corrected and
verified at GUI revision 44c9190; managed validation passes 2618/2618. Live
receipts establish matching published measurements and active subscriptions,
not rendered operator or timing qualification. No blocking finding remains.

## Scope and source state

- JuliaFilterGraph worktree `JuliaFilterGraph-sh-summary`, commits
  `02a8ad1` through `12e8949`: the transport-neutral
  `ShackHartmannSummaryF32` algorithm, schemas, and numerical/graph tests.
- GUI worktree `/tmp/pipewireao-gui-wfs-xy`, changes relative to `758a6b3`,
  final reviewed revision `44c919030e4905f8eb66d1a027d400510c42d16c`:
  five-member observation cohorts, native SHWFS summary decoding and display,
  generic X/Y configuration, presentation, source selection, and tests.
- Application worktree `revolt-classic-rtc-wfs`, revision
  `7989bcf8e0f521cf288b50a45902ef32a44d2a06` relative to `9d855c7`:
  summary graph branch, queue, deployment links, and operator views.
- RTC worktree `pipewireao-rtc-wfs`, based on `a4f4fce`:
  `test/integration/classic_wfs_summary.jl`, final SHA-256
  `74fea8a83e7eef80485efce5396de502242699c5d6e60f9e291eadcecad0226d`
  independently matches the managed result receipt.

This reviewer inspected source and test obligations without running builds,
services, GPU code, or concurrent test jobs. The only repository mutation by
this reviewer is this artifact. Runtime results reported by other agents are
not treated as independently inspected evidence until their retained receipts
are checked below.

## Findings and dispositions

### WFM-001 — Summary mathematics and units match the declared diagnostic

Severity: informational. Confidence: high. Classification: source-derived.
Disposition: accepted; focused numerical tests and managed results inspected.

Affected code: FilterGraphAlgorithms
`src/algorithms/wavefront_sensor/shack_hartmann_summary.jl`, `src/schemas.jl`,
and the corresponding package and JuliaFilterGraph tests.

For validity-true rows, the algorithm accumulates flux, X/Y slopes and squared
slopes in Float64, then publishes eight Float32 fields: total count, valid count,
mean flux, uncentered X RMS, uncentered Y RMS, hypot(X RMS, Y RMS), mean X, mean Y.
It does not subtract a new reference, remove a mean from RMS, change units, or
infer a calibrated physical mode. The 1…2²⁴ preparation bound makes both counts
exact Float32 integers. Invalid rows are ignored; zero valid rows or any
nonfinite valid-row input yields six NaN aggregates while counts remain
validity-derived and processing succeeds. Output/input aliasing is rejected.

Tests cover an independent BigFloat reference, constant slopes, cancellation,
large finite values, nonfinite inputs, empty validity, recovery, unchanged
inputs, aliases/shapes, strided arrays, and warmed allocation checks. Graph
tests check successful NaN publication and output metadata inherited from the
same source frame. The application's mean-slope X/Y chart explicitly uses
detector-pixel units rather than claiming angular tip/tilt or focus calibration.

Numerical scope: Float64 intermediate sums cannot overflow for the declared
Float32 inputs and count bound. Final Float32 combined RMS can overflow for
finite inputs near Float32's maximum magnitude. The GUI rejects such infinite
packets rather than substituting a computed value. The current Classic
pixel-coordinate range is far below this extreme; no claim of finite outputs
for every finite Float32 input is made by this review.

### WFM-002 — Headless ownership and same-frame observation remain explicit

Severity: informational. Confidence: high. Classification: source-derived,
with observed finite CPU integration results. Disposition: accepted.

Affected code: application `graph.conf`, `core.conf.in`, `deployment.conf`,
`operator-views.toml`; GUI `sample_observation/groups.rs`,
`client/model/observation_group.rs`, and `view_panel/wfs_overlay/native.rs`.

The summary takes slopes, flux and validity from the existing measurement node;
its metadata follows slopes. It adds no input to the controller path. The new
observation queue uses one copied buffer and drop-oldest overflow. The summary
adds bounded CPU work to the headless graph, but downstream GUI consumption is
not a prerequisite for science execution. No timing or deadline qualification
follows from this source inspection.

GUI group admission requires four members, or exactly five when Summary is
requested, with distinct sources, current connection identity, role order, and
matching SPA Header sequence/PTS. Worker history remains four owned snapshots
per source, with a 66 ms matching window and per-member payload bounds. Retained
history copies release callback-pool ownership. Source replacement, schema/
format/shape changes, sequence regression, discontinuity and disconnect retire
affected cohorts. Scalar charts retain their independent source observations.

Native SHWFS readouts decode the published packet rather than reducing vectors
or pixels. The former GUI reduction and readout envelope are removed. A test
uses a deliberately distinct published combined RMS to ensure the GUI forwards
that field rather than recomputing hypot. Missing/malformed summaries remain
unavailable, including total and valid counts when the packet is absent;
all-NaN aggregates in a valid packet display unavailable numbers while
preserving its published counts. The final regression test
`missing_summary_readouts_are_all_unavailable_including_counts` checks all six
readout fields are unavailable when the summary is missing. Explicit preview values remain confined to preview data.

The managed test supplied the baseline argument and passed six-stream capture
over two reset generations, exact same-frame metadata, an independent summary
oracle, exact detector replay under the retained FFT contract, unchanged
baseline controller products, warmed allocation checks, and complete cleanup.
The final test source was inspected and its hash matches the result receipt.

### WFM-003 — X/Y display offers visibility controls it does not honor

Severity: low. Confidence: high. Classification: confirmed source behavior.
Disposition: **closed; corrected and verified at GUI 44c9190**.

Affected code: GUI `view_panel/time_series/input.rs` (`channel_settings`) and
`view_panel/time_series/plot.rs` (`plot_xy`).

The initial shared Channels table exposed a Show checkbox for each axis
channel, while `plot_xy` ignored those selections. The correction removes the
visibility column for X/Y charts; time charts retain their Show controls.
Source inspection confirms the header/cell offsets and column counts are
consistent. `xy_settings_hide_time_chart_channel_visibility_controls` verifies
the rendered table includes Index but no Show control; its passing result is
present in the retained final GUI test log.

### WFM-004 — Restoration omits configured-axis membership validation

Severity: low. Confidence: high. Classification: confirmed source behavior.
Disposition: **closed; corrected and verified at GUI 44c9190**.

Affected code: GUI `view_panel/time_series.rs` (`restore`).

The initial restoration checked axis membership only when a saved axis
override was present, allowing a malformed saved channel list to omit a
configured axis. The correction validates effective saved-or-configured axes
against effective saved-or-configured channels. Source inspection confirms
this check runs before presentation adoption. The retained test
`restored_xy_axes_require_both_effective_channel_indices` rejects missing axes
both with and without a saved axis override and accepts a valid restoration.

## Validation and remaining limits

GUI evidence independently inspected under
`/tmp/pipewireao-wfs-gui-handoff/`:

- `receipt.json` identifies final GUI revision 44c9190.
- `wfs-gui-test-all.log`: 576 library, 276 binary, and 12 integration checks
  passed; one library and 15 opt-in binary checks were ignored. The three
  follow-up regression tests above are explicitly present and passing.
- WASM and browser-host compilation logs finish successfully; browser dependency
  exclusion checks pass. These are compilation checks, not browser runtime
  or GPU-renderer validation.
- `wfs-gui-julia.log`: 151 Julia checks passed (45 + 47 + 27 + 8 + 24).
- The external application operator profile parser test passed.
- All-target Clippy completed with the two reported baseline lint classes
  allowed; unrestricted strict Clippy is not claimed clean.
- Built artifact SHA-256 independently matches the receipt:
  `6c595f54ca06d4a6d0d8096244a3b4e224adc663a77194700744e2419d2483bb`.

The following repository receipts under
`docs/validation/wfs-measurements-20261022/` were independently inspected:

- `sh-summary-deployed-tests.log`: 651 focused package/graph closure checks
  passed. The log includes a precompilation cache warning; subsequent bounded
  checks and managed execution succeeded without a reported runtime fault.
- `sh-summary-bounded-count-tests.log`: 427 bounded-count, numerical, catalog,
  and graph checks passed, including the final exact-Float32 count bound.
- `managed.log`: **2618/2618 passed** over two reset generations.
- `wfs-summary-result.json`: complete, CPU, reset/restart and cleanup complete;
  all six streams retain 32 frames in each generation. Exact detector, demanded
  command, and WFS product replay and baseline comparison pass in both. All
  64 current-graph and 64 baseline warmed processing measurements are zero bytes.
- `gpu-audit.json`: no GPU mappings in the graph, parameters, simulator, RTC,
  or core owners. The test also checks loaded GPU modules/libraries.
- `final-launch.json`: stopped, service success, cleanup complete, unit files
  removed, and no reported error. Passing test assertions additionally cover
  the controller and every owner's exact process identity and empty cgroup.

Raw evidence root:
`/home/dgamroth/workspaces/codex/worktrees/wfs-measurements-20261022/managed-final`.
This reviewer independently compared all six saved identity and PTS arrays
within each generation and verified their payload SHA-256 values against
`observation.json`. Generation changes from 1 to 2 and sequence restarts at 1.
The installed manifest hash matches the result receipt:
`fe7eae3e8c5c252023477355ece00a16cb8d006fa35f1842c48aa3a4281f80fc`.
It pins registered FilterGraphAlgorithms 0.7.1 to immutable tree
`f455990e23cdd3193f707a9e8c8cb2ce3aaf92f8`.
The FFT witness has 20 retained plan paths, FFTW 3.3.11, Julia 1.13.2, one
FFT/BLAS thread, and two native Julia threads. Its wisdom hash independently
matches `861e01049cfe210c2e81ee437601860b35498210ed86b5a10553de835a4377a6`.

The primary agent observed the baseline application at 9d855c7 during the run
and fast-forwarded it only after the passing gate. This reviewer independently
verified that revision's graph hash is
`7fc51058799bccd60ccf8034652bd4df5faa9fb22d0c2c52caea573ac8bf6f2a`.
The managed receipt records baseline comparison but not its contemporaneous
graph hash; the checkout-at-run provenance is therefore the primary agent's
observation, not an independently retained baseline snapshot.

An earlier launch attempt was rejected by the fresh-stage precondition before
services started; the harness's premature stage-directory creation was removed.
Final acceptance uses the successful `managed-final` receipt above.

## Live deployment evidence

The repository live receipts and their generating read-only observation checks
were inspected. The deployed native session is
`pipewireao-session@e94c3bddc883.service`, application 7989bcf, RTC 0.2.4,
CPU backend, with the reviewed calibration identity. The software GUI binary
is revision 44c9190 with the previously verified artifact hash. Its launcher
selects Mesa llvmpipe and a session-local workspace directory.

- `live-readouts-check.json`: 32 matched detector/slopes/flux/validity/summary
  cohorts; identical acquisition identities and PTS; bit-exact eight-field
  summary oracle; GUI PID 1504870 subscribed to all five sources while SHWFS
  was rendering.
- `headless-progress.json` and `headless-observation.json`: the GUI unit was
  stopped and GUI nodes absent; the CLI observer received 16 distinct summary
  frames, generation 1, sequences 6422…6437. Native status before and after
  remained Running. This establishes GUI independence with a CLI observer
  present, not an all-observers-absent or cadence gate.
- `live-wfs-check.json`: after GUI relaunch as PID 1509138, another 32 matched
  cohorts and exact summaries passed. The final selected tabs subscribed to
  summary and slope charts. Detector/flux/validity subscriptions were absent
  because SHWFS was not rendering; `all_readout_views_required=false` makes
  that scope explicit. It does not supersede the earlier five-source proof.
- Final raw `live-observation.json` contains 32 distinct samples on each of
  all five CLI-observed streams, generation 1, sequences 7848…7879.
- Both live GPU audits cover graph, parameters, simulator, RTC, core, and the
  corresponding GUI PID. Every listed GPU driver mapping/device-handle set
  is empty. These receipts concern those owned processes at audit time.
- The original global workspace and its retained copy independently hash to
  `c24495cb8d543ed9b3a8456f861269838e70dae1cc1f5ffef77de9d3ccd656ed`, matching
  `workspace-selection.json`. Only the session-local copy changed selection.

The initial source-Props progress probe used a last-acknowledged snapshot as
continuous telemetry. Its zero cursor was not evidence of a stalled source.
Acceptance relies on the subsequent delivered summary frames above. The GUI
and CPU session remain running by design; managed-test cleanup evidence does
not claim the live deployment was stopped.

No screenshot or manual rendered-operator acceptance was available. The
reviewed JSON receipts identify their phases and GUI PIDs explicitly. The
curated `live-readouts.log`, `live-reconnected.log`, and `headless.log` agree
with those respective phases.

No GPU execution, hardware, physical modal calibration, cadence, latency,
or rendered-operator acceptance is claimed. X/Y points are
paired values from one owned sample; source changes use raw units and PTS and
clear history, while returning to the configured source restores its declared
channels, units and model period.
