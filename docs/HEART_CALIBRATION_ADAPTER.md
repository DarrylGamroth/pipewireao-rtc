# Unchanged HEART calibration telemetry adapter

Status: actual native held calibration is complete for the scoped Copper
deferred-ingress cohort and the bounded Classic accepted-inverse transfer.
Both use unchanged HEART measurement/control sources, normal native DM probes,
strict exposure completion, retained payloads and public shutdown. Copper's
six training captures, own reference, selection and locked/spatial tests pass.
Classic's four frozen sparse/mixed directions pass the maintained transfer
replay. Copper normal active correction also passes two 256-frame windows,
a fresh native generation at reset, exact restoration, public shutdown and
direct-truth/zero-baseline utility. Classic's source-v10 successor also completes
two 256-frame normal CORRECT windows, fresh-generation reset, exact ADC/command/
truth reproducibility, restoration, public shutdown and positive replay utility.
Its raw flux dropouts remain visible under the declared normal response policy.
Prior failed attempts remain failed. Independent review accepts both actual
Classic windows, retained dropout classification, replay, reset and cleanup.
See [completed evidence and scope](CALIBRATION_COMPLETION_VALIDATION.md).
Ordinary Copper progressive ingress CCR-017 remains open. Neither this adapter
nor the finite completed fixtures qualify hardware or wall-clock cadence.

## Baseline and allocation

The governing scope is [RTC-ARCH-023](architecture.md#instrument-calibration-through-deployed-endpoints)
and [RTC-DEV-029](operations.md#rtc-dev-029--operational-interaction-calibration).
The RTC starting revision is `6f57ea48b2620fe13b9d09a08a02ee4aeca755ce`, branch
`work/calibration-completion-20261003`. The inspected HEART checkout is
`heart-copper-comparison`, revision
`6a5c06b11a8b934effeb6328a73a70895b2af94a`; it has unrelated untracked generated
files. No HEART source was changed or copied. The adapter independently reads
the public on-disk telemetry representation and extracts existing native WFS
output.

| RTC-DEV-029 obligation | Allocation | Evidence / gate |
| --- | --- | --- |
| Normal native DM probe emission | Public `DM_SHAPE`; native stdDM output | Actual Copper cohort and Classic transfer command/count witnesses pass |
| Actual probe adoption and clipping | Native DM bucket, exact stdDM receipt and AOS adoption of the relayed figure | Actual/requested figure, unit conversion and serialized adoption revalidated in completed captures |
| Normal native WFS measurement | Full-rate native gradient records; unchanged scientific frontend | Actual Copper 3,600 normalized pixels and Classic 376 interleaved slopes retained and decoded |
| Exposure association | One admitted exposure, raw ADC SHA and exact native bucket/sync | Completed retained native payloads and public means independently revalidated |
| Finite response budget | Count-derived file bounds, exact extents and unchanged finite deadlines | Actual bounded captures pass; partial/duplicate/overflow/deadline counterexamples remain covered |
| Stale/invalid exposure rejection | Positive source sequence, owned generation, native sync and raw bytes | Calibration remains strict; normal Classic retains finite, exactly classified flux dropouts; malformed/stale records and ordinary Copper streaming failures remain rejected |
| Settling, restoration, release, abort | Serialized public calibration coordinator and supervised owner | Completed calibration restoration/release/public shutdown pass; failed unknown outcomes stay failed |
| Compatible artifacts and correction | Explicit units, ordering, eligibility, maps and polarity | Copper own inverse passes locked/spatial and actual normal correction; Classic bounded accepted-inverse transfer and two normal correction windows pass retained utility/reset/shutdown checks; final actual Classic review pending |

## Public native interfaces and observed limitations

The selected `scaoTemplateCmdClient` exposes the implemented legacy application
path:

```text
scaoTemplateCmdClient -cmdName DM_SHAPE -address 127.0.0.1 -port 5001 \
  -configDmSelect 0 -configDmShape 1 -configDmFilename <absolute-shape.csv>
```

The shape is a physical actuator vector in micrometres, in native PDM order.
For 277 values the CSV header is `277 1 1 float`, followed by one value per row.
The native handler loads the file, applies clipping and the configured slew
retry policy, writes the normal DM command circular buffer and triggers the
standard DM output when enabled. It does not apply the ordinary reconstructor,
VDM extrapolator or static offsets to this absolute physical figure.

Source evidence: `source/template/src/scaoTemplateCmdClient.c` declares the
options; `source/template/src/hrtTemplateCmds.c` dispatches `DM_SHAPE`;
`source/blocks/src/hrtClwcBlock.c` implements file application and clipping;
`source/device/src/hrtStdDmHandler.c` documents micrometre input and emits the
stdDM packets. The [existing functional HIL evidence](HEART_HIL_VALIDATION.md)
records the SPA decoder conversion: Float32(Float64(native µm) × 10⁻⁶), without
permutation, and AOS scale 1.

`DM_APPLY` opcode 83 has a generated declaration in
`source/aoTypes/apiDef/hrtApi_DM_APPLY.yaml`, but the inspected native executor
registration in `source/rtcExec/src/hrtApiExec_gen.c` does not register it, and
there is no implementing executor. A declared modern API name must not be used
as implementation evidence. The legacy `CALIB_INTER` path is also unimplemented.

The native input, processing and output workers must remain operational while
ordinary integration is held. A global `IDLE/READY` command disables acquisition
and is not a measurement hold. The selected owner must use native `RUNNING`
and the declared controller flags to keep WFS processing and direct PDM output
enabled while integration input is disabled. Native command SUCCESS is not
effective flag readback. Observe the configuration through a bounded native
probe and frame sequence before accepting calibration evidence.

Native direct shape application copies `clwc.lastSyncCounter` to `cbDmCmd0`.
With the initial integration held this is zero; successive direct shapes can
retain zero. `hrtWcOutputBlock` forwards it as stdDM `idFrame`. The positive,
strictly advancing probe sequence in `adopt_pipewire_probe!` cannot be equated
to this native ID. A narrow public `NdArraySink` option to arm an exact zero
sequence can support reception; it must preserve explicit arm/receipt/ACK
behavior and reject other IDs. It cannot establish freshness by itself.

The external owner can receive that normal stdDM figure in a bounded slot,
correlate the next native `cbDmCmd0` bucket, then submit the received figure
through an ordinary Julia ndarray source using a positive, independent probe
token. The plant's existing public adoption method must acknowledge this exact
relayed figure. The owner must establish an exclusive, drained native command
path first; zero IDs and equal figure values do not distinguish delayed
duplicate commands. Unknown receipt or adoption outcomes fault the owner and
prevent reuse. No native ID is invented or rewritten inside HEART.

## Full-rate files and bounded reading

The calibration native configuration needs these file streams:

```text
CB:
  TELEMETRY_FILE_STREAMS: [
    { tagName: "cbHoPixelsRaw#", decimate: 0, pollPeriod: 0.001 },
    { tagName: "cbHoGrad#", decimate: 0, pollPeriod: 0.001 },
    { tagName: "cbDmCmd#", decimate: 0, pollPeriod: 0.001 }
  ]
```

Retain sufficient CB capacity for the declared admission and file polling
budget. Positive native file `decimate` configuration values are interpreted
as desired rates and converted from configured WFS FPS. Use zero to disable
decimation. Native file stream threads begin paused. Enable the selected base
names through the existing public command after setup:

```text
scaoTemplateCmdClient -cmdName SET_TELM_RECORD -address 127.0.0.1 -port 5001 \
  -configTelemEnable 1 -configTelemCbNames cbHoPixelsRaw0,cbHoPixelsCalib0,cbHoGrad0,cbDmCmd0
```

Source evidence: `source/template/src/hrtTemplate.c::setTelemetryForFile`,
`source/template/src/hrtTemplateCmds.c::hrtTemplateCmds_setTelemRecording`,
`source/util/include/hrtTelemetry.h`, and the public
`source/python/heart/util/{circbuf,telemetry}.py` representation declarations.
The Julia decoder does not invoke Python or load shared memory.

[heart_calibration_telemetry.jl](../deployment/hil/heart_calibration_telemetry.jl)
supports the selected little-endian CPU file representation: 1024-byte file
header, 128-byte CB specification, 64-byte revision-2 bucket header, and payload
padding to multiples of 64 bytes. The reader checks the requested tag, datatype,
extent, row-major layout, minor element size and padded payload size before
allocating a frame. It opens one file descriptor, bounds total file bytes and
rejects truncation, rewound committed counts and nonconsecutive record buckets.

For each attempt the reader checks the native `bucketsWritten` count and the
complete record's EOF extent. A partially published record returns no frame;
the bounded waiter polls file readiness and services interruption. File writer
chunking and polling delay may therefore consume the finite response budget.
Neither a sleep nor a timestamp proves native WFS completion. No retry after an
unknown operational outcome is authorized by the reader.

Example construction for Copper:

```julia
include("deployment/hil/heart_calibration_telemetry.jl")
using .HeartCalibrationTelemetry
measurement = TelemetryReader(native_pixels_path;
    tag="cbHoGrad0", datatype=8, shape=(3600, 1),
    maximum_bytes=UInt64(64 * 1024 * 1024))
frame = await_frame!(measurement; timeout_ns=UInt64(5_000_000_000), service=service_owner)
values = copper_response(frame).pixels
```

The owner must close readers during teardown. A restarted child requires fresh
files, readers and association state; never reconnect an old file to a new
native generation.

## Measurement representations

Classic `cbHoGrad0` uses datatype 13, shape `(188, 1)`. Each native subaperture
contains `state::Int32`, `x::Float32`, `y::Float32`, and `flux::Float32`. The
native states are disabled −1, inactive 0 and active 1. The decoder requires
an explicit destination-to-native subaperture permutation and an x/y unit
scale, then emits interleaved `[x₁,y₁,x₂,y₂,…]` and separate flux/validity arrays.
It does not guess an angular conversion. The order must be checked against the
deployed ROI declarations, coefficients, offsets and scientific measurement
contract; identity order is not automatically equivalent to another frontend.

Copper `cbHoGrad0` uses datatype 8, shape `(3600, 1)`. It contains the actual
native reconstruction pixels, with each pupil's 900 selected pixels contiguous
in native quadrant order. `copper_response` copies those finite values exactly;
it does not subtract a reference, shuffle pupils or renormalize from local
detector data. Its `valid` result rejects an all-zero output; it is a minimal
initialization check, not a complete optical-quality or scientific acceptance
criterion. The owner must retain the declared illumination, masks, pupil/ROI
mapping, threshold policy and settling history in provenance.

The native pixel frontend has stateful normalization. In
`source/wfsProc/src/hrtWfsProcPyr.c`, pixel output uses
`normalizationExternalScaleFactor`, and completing the frame updates that
factor from the full calibrated quadrant flux, including masked-out pixels.
The first frame is initialized with factor zero; the completed preceding frame
provides the factor for subsequent pixel output. Consequently one discarded
lamp exposure is needed to initialize a newly prepared frontend before an
illuminated response batch. A new dark-to-lamp transition also needs an explicit
normalization priming exposure. These native values cannot be represented as
an independently normalized current-frame pixel vector without proving the
requested frontend agreement.

`cbHoPixelsCalib0` is calibrated detector data, not this reconstruction vector.
`WFS_SLOPES_AVERAGE` and `WFS_PIXELS_AVERAGE` produce aggregates without the
complete contributing acquisition identity set. They cannot substitute for
per-frame association under RTC-DEV-029.

## Association and owner integration sequence

[`heart_calibration_owner.jl`](../deployment/hil/heart_calibration_owner.jl)
implements the existing `CalibrationServer` session dispatches. Its specialized
constructor requires an established `NativeHold` containing the fresh native
child PID/generation, the fresh startup CORRECT SUCCESS acknowledgement and
reply digest, a subsequent RUN SUCCESS acknowledgement, and the observed
zero-admission simulator cursor. This is native controller
integration hold; the generic controller-absent constructor is not used.
The first native DM bucket must be zero with sync zero, and the first WFS
bucket must be zero with sync one. A changed child or generation faults use.

Run this owner with the usual calibration options and `--transport heart`,
the paired `--controller-request` and `--controller-reply` paths, and:

```text
--heart-client <absolute-scaoTemplateCmdClient>
--heart-native-runtime <supervised-native-runtime>
--heart-probe-directory <fresh-absolute-private-directory>
--heart-telemetry-max-bytes <finite-U64-byte-budget>
```

For Classic, declare `--heart-classic-order <188-U32_LE-indices>` and
`--heart-slope-scale-x <finite-nonzero-scale>` /
`--heart-slope-scale-y <finite-nonzero-scale>` for the target convention.
Defaults preserve native order and units and do not claim frontend agreement.
The selected Copper owner supports four 30×30 ROIs from the native
`config/pwfsRoiOffsets_64.csv`, an empty native quadrant pixel mask, and native
pixel gradient mode. It derives diagnostic mean intensity from calibrated
telemetry while preserving the reconstruction vector exactly.

Link native `heart-dm-source:command` to
`heart-calibration-command:input_1`, and the adapter's
`heart-calibration-probe:output_1` to `simulator-command:input_1`.
Retain `simulator-wfs` to the native `heart-wfs-sink`. The native receive and
relay both use the public stdDM metre schema; the plant command scale is one.
The prepared PipeWireAO package must include the explicit exact-zero receive
option. No callback performs calibration coordination or telemetry parsing.

Native command ACK logs and immutable physical probe CSVs are retained in the
private probe directory. Successful adoption and exposure witnesses are
written to `native-evidence.jsonl` under the finite byte budget. The owner
report retains its path, count, byte size and SHA-256 instead of embedding
the growing record set in bounded control replies.

HEART's `hrtWfsInputBlock_process` increments an internal input-frame counter.
`hrtWfsInputBlock_setSyncCounters` assigns that counter to raw/calibrated
buckets, and WFS processing preserves it. It is not the incoming stdWfs frame
ID or the full AOS acquisition domain. Keep an explicit mapping.

The serialized owner integrates the collector in this order:

1. Prepare a fresh native child, normal stdDM/WFS links, the public zero-ID
   receive slot and the independent ndarray relay. Keep simulator frame
   admission closed. Establish native integration hold and exclusive probe
   ownership, enable the required full-rate telemetry, and drain/fence prior
   commands and frames. Retain observed baseline buckets and native sync.
2. Arm the native DM receive slot before submitting exactly one immutable
   physical shape file through `DM_SHAPE`. Await its acknowledged command,
   actual native transport receipt and next native DM telemetry bucket under
   the same remaining operation budget. Relay the received metres with a fresh
   positive probe token and await actual plant adoption. Use `confirm_probe`
   to compare that adoption/receipt against native micrometre telemetry and
   report the exact clipped figure. Do not resubmit an unknown outcome.
3. Apply the selected completion/model-time/discarded-frame settling rule.
   Native Copper priming frames still advance model time and acquisition
   identities and must be associated and completed before the next frame.
4. Before admitting each actual detector exposure, create the complete integer
   exposure record and call `arm_exposure!` with the actual packed ADC values.
   Admit one normal frame only. Await raw `cbHoPixelsRaw0` and measurement
   `cbHoGrad0` complete buckets, then call `associate!`. The routine requires
   exact next bucket counters, equal exact next native sync, stable acquisition
   domain/generation, next AOS sequence, a nonoverlapping model interval and the
   exact raw ADC digest. Native counter wrap requires a fresh session. Only
   after association acknowledge the plant's exposure completion.
5. Extract the native response and average only the accepted associated frames.
   Native optical-quality failure remains visible; invalid/incomplete native
   records or association disagreement fault acquisition and preserve the
   pending association. A raw hash match alone is insufficient when multiple
   indistinguishable frames are outstanding, so the admission fence is required.
6. On completion or known-outcome abort, fence outstanding work and restore
   the declared physical reference through the same native command, receipt,
   relay and plant-adoption path. Release only after that restoration and the
   settling completion are confirmed. Unknown receipt, cancellation,
   disconnect, timeout or restoration failure retains the hold or faults the
   deployment. Preserve the original failure and restoration disposition.

The collector does not implement these owner effects. The independent
positive relay token is a local correlation token; keep native DM IDs, native
bucket witnesses and full AOS exposure identities in the retained evidence.
Fresh processes, UDP paths and drains need observed support before accepting
this association argument. No timestamp comparison can supply the missing
cross-process acquisition domain.

## Verification

The public Julia package exposes
`PipeWireAODeployment.HeartCalibrationExport.export_package` and the
`export_heart_calibration.jl` CLI. This preparation path calls the normal
`HeartExport`, adds the four full-rate telemetry streams and exact relay
links, copies the selected exact-zero-capable PipeWireAO package, and seals
every resulting artifact hash. It selects the supplied Copper CPU 100× lamp
base, retains normal photon/readout noise, and freezes detector seed 700.

```sh
julia --startup-file=no --project=deployment/julia deployment/julia/export_heart_calibration.jl \
  --base-package <copper-fgn-cpu-base> --output <fresh-package> \
  --heart-root <unchanged-heart-checkout> --heart-source-config <matched-copper-yaml> \
  --calibration-root <native-calibration-root> --pipewireao-jl-root <exact-zero-package> \
  --rtc-binary <pipewireao-rtc> --calibration-binary <rtc-calibrate> \
  --pipewire-prefix <installed-prefix> --readout-us 0
```

After the normal public `Deployment.main(["run", ...])` admits the prepared
package, `HeartCalibrationExport.run_pilot(runtime, fresh_evidence_directory)`
performs a finite native protocol check. It adopts zero and physical actuator
139 at ±0.04 µm, discards one normal exposure after each adoption,
captures two accepted exposures per probe, verifies the standard capture
contracts, restores zero with one settling exposure, and releases ownership.
It retains final owner/ADC reports, native bucket evidence and full-rate files
before public shutdown deletes the instance. Command replies and final owner
reports also remain in the artifact-declared external owner evidence directory.
This pilot does not produce or
qualify an interaction matrix, inverse or correction result.

Run the focused software tests with:

```sh
julia --startup-file=no deployment/hil/test_heart_calibration_telemetry.jl
julia --startup-file=no --project=<prepared-hil-environment> deployment/hil/test_heart_calibration_owner.jl
julia --startup-file=no --project=deployment/julia/test deployment/julia/test/test_heart_calibration_export.jl
```

The tests use independently constructed public-format fixtures. They exercise
partial publication, tag/revision/extent checks, byte budgets, timeout,
duplicate telemetry buckets, Classic order/scale/state, exact native Copper
values, physical DM conversion and clipping, one pending frame, stale and
changed identities, model intervals, native sync disagreement and ADC mismatch.
These are synthetic protocol tests. They do not establish native command flag
effectiveness, live transport reception, process/frame drain behavior,
scientific response agreement, restoration or a real-time deadline.

Live acceptance must retain the source/config/artifact hashes, native command
ACKs, adopted physical figures and clipping, full native bucket-to-AOS identity
mapping, contributing measurement frames, restoration ACK/disposition and
absence of leaked owners. Then compare independently acquired Classic/Copper
interaction and reconstruction artifacts and demonstrate correction before
promoting the scientific calibration claim. Backend and rate characterization
remain separate gates.

## Native enable scope and pre-admission failure evidence

The normal `HeartOwner.start` strictly checks INIT, RUN, configured flag and
CORRECT replies before publishing successful generation-one status. Native
CORRECT calls the scoped endpoint enable helper and then enters correction.
The calibration owner validates that fresh successful status and bounded
startup CORRECT stdout/stderr, retains their digest and copies, and sends RUN
before any simulator exposure is admitted. Native RUN changes block state and
preserves endpoint enables. TFC has no running-state integration function.
This is the source-grounded hold path; effective hold still requires the live
pilot to show exactly four native DM records (three probes and restoration)
while ten native WFS frames are processed (three discarded and six accepted
probe frames, plus one restoration discard).

The standalone ENABLE_WFS_WC handler at the selected unchanged native source
revision calls the scoped helper, then enables the common fan-out without
initializing its outer command message (`hrtTemplateCmds.c:1065–1104`,
`1587`, `2860–2905`). The v3 deployment observed a failed standalone command
acknowledgement before admission; cleanup removed its reply log. The source
issue is observed, but its causal relationship to that reply remains
unconfirmed. The calibration owner uses the already successful startup
CORRECT scope rather than issuing the standalone command.

The exporter declares a fresh external `owner_evidence_directory` in sealed
provenance and supplies it as `--heart-probe-directory`. Its default is
`<package-output>-owner-evidence`; override it with
`--owner-evidence-directory <fresh-external-directory>`. Its parent must exist,
and it must be outside the immutable package. The owner creates it with mode
0700. Runtime shutdown does not delete this directory.

Each native command retains separate bounded stdout/stderr and JSON containing
argv, exit code, termination signal, failure reason and truncation status.
The acknowledgement test still requires successful process exit and both
ACCEPTED and SUCCESS markers. Its thrown error includes the bounded reply
text. A pre-admission failure also retains `owner-failure.json`, the native
owner status and bounded startup command/child log snapshots outside the
runtime. Software regression fixtures demonstrate a rejected command's exact
exit and stdout/stderr surviving deletion of the simulated runtime. These
fixtures do not establish native process behavior.

## Adoption progress and failure snapshots

The v4 pilot reached successful native DM_SHAPE acknowledgement but timed out
before any acknowledged adoption or exposure. Its retained evidence cannot
distinguish stdDM reception, native command CB publication, relay publication
and plant adoption. A PipeWire mixer warning is observed but is not established
as causal. The selected native output address/port (localhost:6100) matches the
SPA stdDM listener (127.0.0.1:6100), and the relay ports declare the same F32_LE
277-element physical metre schema. The public sink uses NO_CONVERT and accepts
only its explicitly armed zero Header sequence.

The owner now records entered/completed/failed adoption gates for native stdDM
receipt, native command bucket, relay submit and actual plant probe adoption.
Each gate includes public stream state/node identifiers where available. A
separate relay source acknowledgement file captures source queue publication
without concurrently updating the owner's evidence counters. Monotonic times
in these records describe transport progress only. They do not prove model
time, native command freshness or optical validity.

Before closing the session, the owner snapshots only the four selected native
telemetry files into the external evidence root, copying at most the declared
per-file byte budget and retaining a manifest with byte counts and digests.
Partial final publication is preserved for diagnosis. The pilot also copies
selected native top-level output files, without traversing native configuration
symlinks. Retention failures are recorded without masking an existing pilot
failure. These changes keep the original 30-second adoption deadline and all
command, frame association and physical figure checks.

## v5 telemetry discovery defect and correction

The v5 pilot observed completed exact-zero stdDM receipt, followed by a native
command bucket deadline failure. No relay submission or exposure occurred.
Source inspection establishes two adapter defects:

1. SET_TELM_RECORD was given bare names such as `cbDmCmd`. Native
   `hrtTelemetry_pause_streamList` calls fixed-length `hrtCB_compareBaseName`;
   names must match exactly, or `#` must occupy each digit position. Bare names
   do not match `cbDmCmd0`. The command can report SUCCESS even when no stream
   matches. The corrected adapter supplies the four exact zero-index tags.
2. `hrtTelemetry_canonicalBaseFileName` creates
   `YYYY-MM-DD_HH-MM-SS_<tag>`, and `startFile` appends block state, ISO time
   and `.tel`. The reader and failure snapshot previously required a filename
   beginning with the CB tag. They now match the source-defined date/time
   prefix and exact tag boundary. Header tag, type, extent, publication count,
   bucket/sync, units and association checks remain mandatory.

Source locations are `hrtCircBuffer.c:3630–3662`,
`hrtTelemetry.c:6014–6089`, `3140–3176`, `1236–1308`, and
`hrtTemplate.c:775–794`. The native default output path is the owned child's
working directory (`./`); the v5 startup log confirms the four basename
prefixes there. The software fixtures cover exact enable arguments, canonical
filename discovery, rejection of another tag/index and partial suffix, and
canonical telemetry snapshots surviving runtime cleanup. Live native
publication/readout remains a separate gate.

## Native Copper correction sign and retained coefficients

Observed in the selected unchanged native source: HO reconstruction consumes
actual quadrant-major normalized pixels and applies its configured control
matrix without an added negation (`hrtHoReconBlock.c:2630–2748`). The default
scalar TFC path multiplies that vector by `hoLoopGain`
(`hrtTfcBlock.c:2856–2868`). CLWC then calls the accumulation routine whose
operation is `S = α S + β X` (`hrtClwcBlock.c:2274–2292`,
`hrtVec_acc_aacc_bx.c:74–120`). Physical output follows the configured
VDM-to-PDM map and existing flat/offset/clipping paths. There is no generic
negative feedback sign added between these scalar/MVM operations.

The sealed v5 Copper native configuration retains HO gain `g = +0.01`, CLWC
scalar `β = 1`, and CLWC leak/pole coefficient `p = 0.99`. It retains a
253-coordinate native reconstructed/VDM vector, a 277-coordinate physical DM
and the measured modal-to-actuator map. Its native reconstruction matrix is
therefore not an interchangeable 277-by-3600 physical reconstructor. Optical
post-reconstruction scaling and active reference/offset/feedback flags must
also be included when comparing the effective deployed map.

For a fixed linear physical map `A`, with the optional paths inactive and no
clipping, the source equation is:

```text
qₖ       = C mₖ                     native reconstructed coordinates
Xₖ       = g qₖ
Sₖ₊₁     = p Sₖ + β Xₖ
uₖ₊₁     = A Sₖ₊₁                 physical micrometre OPD
         = p uₖ + β g A C mₖ
```

The existing AOC zonal push/pull estimator uses the positive-minus-negative
response divided by the positive command interval. A positive inverse
`R_est = D⁺` therefore has `R_est D ≈ I` on retained controllable coordinates;
this statement does not mean its individual entries are positive. For a
local interaction relation `m = m_disturbance + D u`, a cancelling physical
increment is `−R_est m`. Consequently an unchanged positive native scalar
gain requires an effective physical matrix `A C = −R_est` for that feedback
convention. Loading `+R_est` without a compensating declared sign changes
feedback direction. This is a derived compatibility requirement, not an
instruction to tune native gain or silently negate a candidate artifact.

Under an ideal instantaneous scalar mode and an exact inverse, the source
recurrence's closed-loop perturbation factor would be `p + β g` for `+R_est`
and `p − β g` for `−R_est` (1.00 versus 0.98 with the retained coefficients).
Actual native delay, projection, normalization history, reference terms,
optical scaling and clipping are excluded from this derivation; it is not a
stability or convergence qualification. Preserve the signed measured `D`
and positive inverse artifact, and record any separately selected native
matrix adaptation and its units, ordering, projection and sign.

For the retained 253-coordinate estimator wire, train using its actual frozen
physical command map. Write the selected wire matrix as `C_wire = −R_est` and
retain the real extrapolation/projection chain: physical output is
`P E C_wire m`, not a substituted 277-coordinate identity mapping. If the
training basis uses `u = P E a`, its measured response is
`D_basis = D_physical P E`; `R_est = D_basis⁺` then estimates those declared
253 coordinates. This preserves the actual projection/extrapolation and their
signed conventions. Native `processVdm`/`hrtClwcBlock_processPdm` implement that
chain (`hrtClwcBlock.c:1876–1918`, `1540–1570`). The full-plan declaration must
bind its dimensions and matrix hashes; a physical zonal candidate and an
estimator-coordinate candidate are different products. An unchanged native
correction trial needs its actual complete chain checked before admission and
independently measured residuals afterwards.

## Minimal extension to frozen full and validation plans

Proposed scope: extend only the public HEART calibration exporter/orchestrator
with a frozen plan input and corresponding stage-budget declaration. Reuse
`CalibrationClient.prepare_plan/write_plan/validate_result`, the existing
`rtc-calibrate --endpoint ... --plan ...` client and AOC estimators. The native
Session/CalibrationServer dispatch and the strict completion gates already
operate on arbitrary finite physical probe vectors. The selected full cohort uses 16 accepted frames and one completed discard
per signed batch; the functional pilot remains N2. No new scientific estimator,
reconstructor policy, gain, inverse truncation or acceptance threshold is part
of this extension. The current general method selector
admits only FGN/JFG; adding HEART to that broad API requires explicit review of
its provenance/measurement contract, not merely relaxing an engine allowlist.

1. Freeze the exact public plan, recipe, chronology/permutation, physical
   reference and probe figures, amplitude/basis metadata, actual probe row count, frames and discarded
   settling counts. Declare the simulator backend explicitly. Full science
   against CUDA requires a preserved CUDA base/package/target, normal detector
   acquisition and retained backend identity; the present HeartExport CPU-only
   base guard must receive a narrow reviewed capability extension after pilot
   completion. A CPU pilot does not establish CUDA native full science. Bind SHA256 identities for the unchanged native revision,
   rendered config, matched optical/detector graph, ROI order, physical DM
   units, package/SDK/helper sources, background and detector seed.
2. Calculate capture and native per-file budgets from the frozen total counts
   before export. Preserve the normal supervised HeartExport lifecycle,
   startup CORRECT→RUN proof, zero native receipt and positive AOS relay. Use
   one outstanding probe/exposure, the existing request deadline, and a
   separately declared finite total stage deadline.
3. Execute the frozen interaction plan through the existing public CLI after
   ordinary deployment admission. Keep a single native held generation;
   compare every adopted figure, clipping result, native command bucket and
   receipt before any settling or accepted exposure. Keep the actual native
   normalized pixel vector and raw ADC witness for every completion.
4. Retain endpoint/CLI results, completed owner/ADC report, all contributing
   capture manifests, command/stage/source ACK evidence and four native
   telemetry streams before public shutdown. Validate restoration, release,
   public shutdown and unchanged sealed inputs before AOC reduction. Preserve
   chronological identity validation before numerical canonical reordering.
5. Prepare an independent fresh validation plan from already declared null,
   signed or held-out figures. Reuse the same completions and representations;
   report descriptive prediction/residual metrics against the frozen candidate
   without selecting new operating settings or thresholds. A correction plan
   is a separate stage and requires the sign/coordinate adaptation described
   above; the pilot's direct DM_SHAPE path is not ordinary native correction.

For `B` successful probe adoptions, accepted counts `Nᵢ`, discarded settling
counts `Sᵢ`, one restoration adoption and restoration settling count `Sᵣ`, the
held native counts must be:

```text
cbDmCmd0 records             = B + 1
raw/calibrated/grad records  = Σᵢ (Sᵢ + Nᵢ) + Sᵣ
accepted capture records    = Σᵢ Nᵢ
```

Every additionally declared reference/warm-up exposure belongs in the second
count. The current three-probe pilot gives four DM and ten WFS records. A
277-coordinate zonal push/pull plan has 554 probe adoptions and 555 DM records;
with the full cohort's one discard and 16 accepted exposures per signed batch,
plus one restoration discard, it has 9,419 WFS and 8,864 accepted capture
records. A 253-coordinate zonal estimator plan instead has 506 signed rows,
507 DM records, 8,603 WFS records and 8,096 accepted frames. Hadamard or modal
plans must use their actual frozen row count, which need not equal twice the
physical coordinate count.
These counts refer to completed, committed full-rate records and contiguous
bucket/sync association, not file presence or elapsed time. Extra DM output
while held WFS frames are processed rejects the hold proof. Native slew retries
can create extra command records; they are not silently attributed to the
single requested figure by this adapter.

For this frontend, minimum serialized per-file budgets are
`1024 + F × record_bytes`, with record bytes 8,256 for raw pixels, 16,448 for
calibrated pixels, 14,464 for native normalized pixels, and 1,216 for physical
DM commands; `F` is the corresponding WFS or DM count. Accepted capture payload
uses the existing public 22,596-byte contract per frame. Declared full-plan
budgets must cover these actual totals; the pilot's defaults are not a general
full-plan guarantee. Check the actual counts and clipping/state witnesses
before claiming held acquisition, then compare native and FGN/JFG scientific
results using their explicitly compatible measurement representations.


## First exposure diagnostic (v6 → v7)

Observed in the v6 finite pilot: native exact-zero stdDM receipt, DM bucket
0/sync 0, positive relay sequence 1 and bit-exact AOS physical adoption all
completed. The first settling exposure published one raw and one calibrated
bucket (0/sync 1). Its native measurement file contained only its 1024-byte
header; no committed gradient bucket was visible at the strict 30 s deadline.
The exposure cursor and completed ADC diagnostics therefore remained zero.
These completed raw records demonstrate partial processing; they do not prove a
completed WFS measurement.

The hypothesis that RUN disables the PWFS processing callback is rejected by
the selected native source. `hrtWfsInputBlock.c:885` and
`hrtWfsProcBlock.c:1995` assign the same processing functions in RUNNING and
CORRECTING; the latter explicitly accepts both states at line 3431. RUN
entry resets offsets and marks the subaperture mask for update, without
disabling processing. TFC and CLWC remain held as previously described.

The hypothesis that zero initial lagged normalization deliberately suppresses
the first output bucket is also unsupported. `hrtWfsProcPyr_quadToPixels`
uses the previous normalization factor while still tracking completed work.
`hrtWfsProcBlock_processPixelStream` advances the output writer ready on
success or invalid on error (`hrtWfsProcBlock.c:4588`); the nondecimating file
writer writes every advanced bucket (`hrtTelemetry.c:1739`). No priming-frame
completion exception or extra source publication is implemented. Callback or
trigger progress and recorder binding remain unresolved by the retained files.

The v7 diagnostic package adds sequential `exposure_stage` witnesses for plant
frame publication, the raw bucket, calibrated bucket, measurement bucket,
exact native frame association and final AOS exposure completion. The
before-publication callback also records the actual normal detector ADC digest
and model interval. Copper reads calibrated telemetry before waiting for its
measurement, so a timeout records both partial native witnesses. Failure
snapshots include the four recorder filenames, byte sizes and committed
counts. These snapshots establish recorder progress only; scientific freshness
continues to require the existing full association checks.

`export_heart_calibration.jl --native-wfs-proc-debug true` explicitly enables
the unchanged native CLI diagnostic interface:
`-moduleDebug hrtWfsProcBlock_debugLevel -moduleDebugLevel 4`.
The exact variable is registered in `source/template/src/debugVars.c:167`;
`DAO_DEBUG_DIAG = 4` follows the selected DAO header enum starting CRIT at −1.
The option is false by default. This diagnostic launch is excluded from cadence
and scientific qualification. Native stdout/stderr already share the supervised
native log; the owner retains its first 64 KiB, truncation flag and source size
externally before close even on exposure failure. Bytes still buffered inside
the unchanged native process are not claimed as retained evidence.


Additional static discrimination confirms that the WFS-to-proc connection is
an explicit semaphore connection (`hrtHopLopPipe.c:754,955`). It does not depend
on correction state. WFS input triggers on the first calibrated rows and its
finalization path triggers if not already done. The initial subaperture-mask
warning is distinct from the PWFS pixel-selection mask: the empty quadrant
mask path explicitly selects all 900 pixels (`hrtWfsProcBlock.c:1307`), while
the initial subaperture CB is written even when no mask file was selected.
`local_setReaderMostRecent` accepts an already-ready first calibrated bucket.
The proc output CB is the configured gradient recorder input. These source
checks do not explain the absent v6 output bucket; the diagnostic trace must
identify whether the callback enters and where it stops.

v7 is frozen at
`heart-calibration-copper-pilot-prepared-v7/deployment.conf`, SHA-256
`cfff82504ede2fce4779bd4fa5ce87667d0d80ce5948dff7f35751042f61d2ac`.
Its 477 declared artifact hashes match. Software checks: owner 68 assertions,
telemetry decoder/association 50, calibration exporter 39, and normal native
owner 20 all passed. The exported calibration owner also loaded in its sealed
HIL environment. No native v7 process was launched by the adapter worker;
measurement completion and scientific qualification were pending at that stage.


The root v7 launch reached READY, but no scientific pilot connected before the
existing 30 s owner accept deadline. The later manual connection was approximately
34 s after readiness. Its accept fault is orchestration evidence, not a new WFS
measurement finding; no probe or exposure was admitted. The fresh v8 diagnostic
package preserves the exact v7 calibration-owner, telemetry-decoder, plant and
native-config bytes and both 30 s deadlines. All 477 artifact hashes match;
`deployment.conf` SHA-256 is
`871f1e5782888c85f3c3f1883fab607bdaf381b57c80c946ee8a0dafb645098b`.
The external `heart-calibration-copper-pilot-prepared-v8-owner-evidence` root is
fresh. Root will preload the public SDK and perform launch, wait for READY,
immediate pilot connection and final public shutdown in one process.


v8 admitted the pilot promptly and failed at `native_measurement_bucket` after
raw and calibrated bucket 0/sync 1 completed. Its native-log snapshot actually
contains 45,056 bytes, reports `truncated=false`, and ends during startup CORRECT;
the pilot copy contains the same bytes. No per-frame native callback entry is
visible. `daoDebug.c:553` writes to ordinary stdout without flushing when
`daoDebug_logToStdout_streamTarget` is null. The evidence therefore cannot yet
distinguish absent callback execution from output still in native stdio buffers.
Shutdown SIGTERM is expected teardown evidence, not a demonstrated crash.

The next source-discriminating diagnostic adds the explicit export option
`--native-debug-line-buffering true`, requiring `--native-wfs-proc-debug true`.
It prefixes the unchanged native command with the installed GNU
`stdbuf -oL -eL` interface. Both options default off; wrapper absence is a
preparation failure with no fallback. The wrapper absolute path, binary SHA-256
and complete command arguments are retained in package and native-owner
provenance. After listener readiness the owner checks that its supervised child
PID has execed the declared native binary through `/proc/PID/exe`; the existing
worker placement validation is unchanged. This logging diagnostic is excluded
from cadence and scientific acceptance. It preserves the normal science config,
HEART binary/source and both 30 s deadlines.


The fresh v9 diagnostic package uses this explicit wrapper and retains the exact
v8 native config and plant bytes. Its deployment SHA-256 is
`f95720be45980b691c117cc969999409c5185c2a88f066f996dc9f62be1db917`;
all 477 artifact hashes match. The installed `/usr/bin/stdbuf` binary SHA-256 is
`2ce167833ea6fd323fa3de2ef274aa2bbc33d4f4ba33787ce2e48b3dd6bf3aee`.
Focused exporter tests passed 41 assertions; native owner tests passed 26,
including explicit wrapper availability/mode checks and retained runtime
arguments/hash/qualification. No native worker was launched during preparation.
The absence of visible v8 callback logs remains an unresolved observation until
the line-buffered diagnostic is run.


## Native newest-bucket race and paced v10 diagnostic

The flushed v9 trace establishes the first-frame stall mechanism. The owner
completed raw and calibrated bucket 0/sync 1. The native proc worker entered its
normal PWFS callback, then logged that `getBuckets` selected calibrated bucket
**1**, followed by pixel polling with 0/64 rows and 0/900 subapertures. The
measurement recorder still had no advanced bucket at the strict deadline.
Its retained native log is 48,950 bytes, untruncated, SHA-256
`f1a37e5a8a56a2a24305e320d42c51e12473e2a9391920b94b09f443b0876b64`.

Source explains this observation without a normalization or scientific-gain
change. `hrtWfsInputBlock_process` immediately begins the next input read and
calls `handlerParamsUpdate` before blocking for UDP. That helper initializes the
next calibrated bucket's progress (`hrtWfsInputBlock.c:1939`);
`hrtCB_initBucketProgress` marks it UPDATING with zero progress
(`hrtCircBuffer.c:1988`). The processing callback unconditionally calls
`hrtCB_setReaderMostRecentStreaming` (`hrtWfsProcBlock.c:3758`), whose selection
prefers the current nonempty writer bucket (`hrtCircBuffer.c:896`). A proc worker
that wakes after the first frame has fully arrived can therefore select the
already-prepared next frame instead of the frame that triggered its semaphore.
Serialized admission cannot supply that next frame while awaiting completion
of the first. This is source-derived and matches the v9 selected-bucket trace.

No public reader-selection policy was found in this native path. The standard
WFS handler explicitly sets `isStreaming=true` at
`hrtStdWfsHandler.c:927`, rather than selecting it from its public configuration.
The unchanged public SPA transport already exposes row pacing. Ordinary Copper
export defaults to a 2,000 µs readout, and the previous normal 100 Hz deployment
records that value; the finite calibration pilots explicitly selected zero.

Root approved v10 to change only the transport readout property to 1,000 µs at
500 Hz, preserving the existing 32-row datagrams. The public sink sends packet 1
immediately and packet 2 after 500 µs (`wfs-sink.c:906,954`). It copies the exact
admitted input frame once, retains the same frame identifier and timestamp, and
rejects another admission while transmission is active. No additional detector
exposure is generated. The setting satisfies the existing requirement that the
readout parameter be below 95% of the declared 2 ms frame period.

Spacing provides the proc worker an opportunity to select bucket 0 before the
input prepares bucket 1. It is not a scheduling guarantee. Missed scheduling,
skipped buckets, mismatched sync, raw digest differences or invalid accepted
responses still fault through the unchanged checks. Repeated exact association
and the expected native DM/WFS counts must be demonstrated before accepting the
paced calibration path; no v10 pass or scientific qualification is claimed here.

Fresh v10 deployment SHA-256:
`2919a5f17c5558da7c8630d3ab6f4cad72385aa055fdf5bccaaddf4d83249c8e`.
All 477 artifact hashes match. Native config, plant, native binaries, calibration
owner and decoder match v9 byte for byte. The only changed runtime configuration
is the readout property in `core.conf.in`; updated provenance and added SDK
report assertions account for the other artifact differences. Both diagnostics
remain explicit, both 30 s deadlines are unchanged, and the external evidence
root is fresh. Root owns the next serial launch; no worker acquisition was run.


## v10 public filename limit and v11 paced observation

v10 failed before exposure admission. The external public command argument was
128 bytes and ended in `.csv`; the flushed native log shows the parsed filename
ending in `.cs`, followed by `hrtFile_load` reporting an unsupported type.
The v9 path was 127 bytes. Both probe files had identical contents, permissions,
and SHA-256 `2fe329717075d230b3512e47344f6a98901dcb654ce5033c66d2e0d422002d69`.
The native public client declares a 128-byte filename buffer
(`hrtCmdClient.h:272`, `scaoTemplateCmdClient.c:266`, via
`HRT_GMS_CMD_MAX_STR_LEN`); the DAO argument parser copies `size` bytes then
sets `str[size-1]` to NUL (`daoCLArg.c:951`). This confirms silent truncation,
without a native source change. Export and owner preparation now reserve the
maximum UInt64 probe filename and reject paths longer than 127 encoded bytes.

v11 used the short external root `heart-native-v11` and 1,000 µs readout. Native
DM adoption completed. Its first admitted frame produced raw, calibrated, and
gradient bucket 0/sync 1 and passed the exact detector digest association.
This is a pass after the v9 selected-empty-bucket stall for that first frame;
it does not establish repeated association or a complete pilot. The request
then failed before actual AOS completion. The retained gradient has 3,600 finite
zero values, so the nonfinite first-frame hypothesis does not explain v11.

The calibrated auxiliary buffer is READY with progress 64/64, sync 1, and
native timestamp zero. `hrtWfsInputBlock_finalizeFrame` sets its duration from
`usecTime-rNow` before advancing (`hrtWfsInputBlock.c:1475`). The CB writer only
calculates a completion timestamp when duration is zero
(`hrtCircBuffer.c:800`); a nonzero duration preserves that zero timestamp.
The adapter's generic positive timestamp guard incorrectly rejected the
calibrated buffer while calculating descriptive pupil intensity. The dedicated
auxiliary decoder now requires the exact calibrated tag/type/shape,
READY/progress completion, and nonnegative timestamp. Its caller still requires
the same raw bucket and sync. Raw and gradient timestamps remain positive,
and positive AOS identity, raw ADC digest, and gradient association remain
mandatory. The first all-zero response remains invalid and may only complete
the declared settling discard. Accepted captures still require finite, nonzero
native response and positive previous/current pupil intensity.

New decode, validity, frame-receipt, and actual completion stage witnesses retain
the first failure externally. A bounded `primary-failure.json` prevents a later
reader EOF during client teardown from replacing that first error in the final
owner report. Unit regression demonstrates the old calibrated timestamp guard
failing and the dedicated diagnostic decoder succeeding on the same completed
fixture, while zero gradient timestamps and incomplete progress still fail.

Fresh diagnostic v12 descriptor SHA-256:
`29c1e0e9d440f6244ebebdbb066b5d5013c9055c5fac9053031eb78b0447b307`.
All 479 artifact hashes match; root owns its launch. No complete native pilot or
science qualification is claimed by preparation.

## Public frozen full-plan export and collection

The public exporter accepts `--plan` and `--simulator-backend cpu|cuda`.
The default remains CPU. CUDA selection verifies the selected base's backend,
its single source owner's `--backend` argument, and the exact CUDA dependency
UUID through `CalibrationCampaign.validate_simulator_backend`. It preserves
that owner argument and the base package dependencies; there is no fallback.
The native HEART worker remains on its existing CPU placement. The simulator
plant is copied with an exact hash check before the documented detector seed
freeze. Neither the native scientific callbacks nor their maps/gains change.

The frozen plan must use Copper's actual 277 physical actuator coordinates,
3,600 normalized native measurements, finite Float32-representable figures,
2–64 accepted frames per probe, and bounded `discard_exposures` settling. The
exporter does not create, reorder, or reinterpret probes. Plans prepared by the
existing public `CalibrationClient.prepare_plan` retain their actual zonal,
Hadamard, modal, or spatial commands and order. Frozen cohort plans use N=16
and one declared discard per probe and restoration.

For B probes, S discarded exposures, and N accepted exposures per probe:

```text
native DM records = B + 1
completed WFS exposures = B × (S + N) + S
accepted capture frames = B × N
```

Each file budget follows its selected native layout. The owner evidence budget
also reserves bounded command replies and stage records. Capture payload and
client JSON output bounds follow the accepted frame, probe, and measurement
counts. An oversized plan or explicit budget smaller than the derived bound
fails before deployment; the ordinary exporter retains its existing budget cap.

A prepared nondebug CUDA zonal package exists at
`~/.cache/rtc-calibration-completion-20261003/heart-calibration-copper-zonal-cuda-prepared1`.
Descriptor SHA-256:
`94fa572a6070dec53de96dc441a6226f19c25aaaa141f7a3d6d64d6ee30260da`.
All 480 hashes match. The original `fgn-zonal-1/interaction-plan.json` is copied
byte for byte, SHA-256
`dfd2c32ba4e56d211eb4f8ee5bfc971d916d7972e125d9109cca8a533214ab1c`.
Its 554 physical probes require 555 DM records, 9,419 WFS records in each of
raw/calibrated/gradient files, and 8,864 accepted captures. Payload budget is
200,290,944 bytes; native per-file/evidence budget is 227,065,856 bytes; public
result output budget is 70,693,888 bytes. The complete parsed plant matches the
CUDA base except the requested detector seed 700; calibration input/result and
Hil Project/Manifest files remain byte identical. This is export verification,
not a CUDA admission or scientific acquisition result.

After the functional pilot has passed, prepare a fresh package and fresh short
owner evidence root using the public CLI:

```sh
julia --startup-file=no --project=deployment/julia \
  deployment/julia/export_heart_calibration.jl \
  --base-package BASE_COPPER_FGN_CUDA --simulator-backend cuda \
  --plan FROZEN_INTERACTION_PLAN --calibration-stage interaction \
  --output NEW_PACKAGE --owner-evidence-directory NEW_SHORT_EVIDENCE_ROOT \
  --heart-root NATIVE_HEART_ROOT --heart-source-config MATCHED_COPPER_CONFIG \
  --calibration-root NATIVE_CALIBRATION_ROOT \
  --pipewireao-jl-root EXACT_ZERO_PIPEWIREAO_ROOT \
  --rtc-binary PUBLIC_RTC_BINARY --calibration-binary PUBLIC_CALIBRATE_BINARY \
  --pipewire-prefix /opt/pipewireao --readout-us 1000
```

Preload the public SDK, supervise launch through normal `Deployment` lifecycle,
wait for admission, and immediately invoke:

```julia
using PipeWireAODeployment
PipeWireAODeployment.HeartCalibrationExport.run_plan(package, runtime, fresh_evidence)
```

The call uses the sealed plan through the ordinary `rtc-calibrate` endpoint.
It invokes existing public `CalibrationClient.validate_result` on the actual
response means and positive exposure identities, waits for the final owner
report with the expected completed/ADC count, and verifies every native CB
record and exact total before retaining evidence. Additional native DM output
while WFS frames execute fails the held-controller count check. Missing,
duplicate, reordered, wrong-sync, partial, or extra records fail verification.
The launcher still owns public shutdown and records its result in `finally`.
No deployment remains alive for candidate installation after release.

Method reduction continues through public `CalibrationClient` AOC preparation
and estimation using the original frozen method specification and chronological
permutation. The collector returns the ordinary raw public result so that the
method's existing numerical policy remains authoritative. A physical 277-column
candidate is not a 253-coordinate native controller matrix. The retained P/E
maps and `-R_est` wire convention described above remain required for any later
candidate projection; no matrix installation is performed by this extension.

Focused software verification now includes 82 owner assertions, 55 decoder/count
assertions, 61 exporter assertions before the final profile guard additions,
and 26 native supervision assertions. At that stage, scientific acceptance
awaited the owned native pilot and fresh nondebug acquisition. Hardware and
cadence qualification remain outside this finite fixture.

## v12 functional completion and matched seed-531 method artifact

The owned v12 retry completed the finite pilot and public shutdown. The first
mask-14 attempt had failed placement preflight before launching any source or
native owner; retry used a launch mask that admitted the declared private CPUs.
The package was unchanged. Retained native telemetry passes the standalone
bounded verifier with exactly 10 raw/calibrated/gradient records, buckets 0–9,
sync 1–10, and exactly four DM records, buckets 0–3/sync 0. The final owner reports
sequence 10, restoration confirmed, ownership released, 10 ADC frames, one
invalid initialization settling exposure, maximum ADC 4,417, and zero rail
pixels/frames. The lifecycle artifact records `pilot_confirmed=true`,
`shutdown_confirmed=true`, final phase `stopped`, and no failure or shutdown
failure. Six frames were accepted. This establishes finite completion for the
paced unchanged native frontend; the explicit debug/stdBuf run does not qualify
cadence or a full scientific matrix.

The frozen full cohort uses interaction seed **531**, as recorded in the
original `fgn-zonal-1/recipe.json`; pilot seed 700 is not a matched training seed.
The original unlaunched prepared1/2 exports remain preserved. The matched
nondebug artifact is:

```text
~/.cache/rtc-calibration-completion-20261003/heart-calibration-copper-zonal-cuda-prepared3
Deployment SHA-256:
93be47c8c7d2199ad6a59cae4cecce778c012cfe185097de67e9c3a277a1e4ed
Frozen native method identity SHA-256:
67c40f966ebd01224fd172a96f91fcb748ae443b7068772f3f675b75d55775ed
Fresh external owner evidence: .../hn-zon3
```

All 490 artifact hashes match. Its seal binds the seven original recipe,
method, prepared specification, canonical order, canonical plan, interaction
plan, and base identity files to their original prepared-identity hashes. It
also binds all 50 original AOC package files and the original public
`calibration_client.jl`. The selected CUDA source, frozen seed 531, and exact
copied chronological plan are explicit. Its shipped HIL environment rebuilt
the public AOC canonical/chronological plans byte for byte: 554 physical probes,
N16, S1. This is preparation verification; no scientific capture was launched
by the worker.

Add these arguments to the preceding public export command for a matched
training method:

```sh
--frozen-method FROZEN_METHOD_DIRECTORY --detector-seed 531
```

After `run_plan` and successful public shutdown, reduce through the public SDK:

```julia
PipeWireAODeployment.HeartCalibrationExport.reduce_plan(
    package, evidence, runtime, fresh_candidate;
    expected_deployment_sha256="93be47c8c7d2199ad6a59cae4cecce778c012cfe185097de67e9c3a277a1e4ed")
```

Reduction verifies the descriptor from before acquisition, the native completion
flags/counts, successful stopped deployment state, frozen plan identity, and
sealed public result/count-file digests. The shipped cold helper reconstructs
the same public AOC prepared plan, validates chronological exposure identities,
reorders only the response values back to canonical order, and calls the existing
public AOC estimator. A synthetic reverse-order regression recovers the known
matrix through those calls and rejects mutated input seals and reused outputs.
The output remains an unaccepted response candidate. Native controller mapping,
selection, installation, and correction acceptance are separate gates.

Focused software checks pass 241 assertions: owner 82, telemetry/count decoder
55, exporter 69, native supervision 26, and public AOC method reduction 9.
Preparation copies and parsing are not a CUDA exposure test or full-method
scientific acceptance result.

## CCR-016: bind reduction to captured native evidence

Independent review demonstrated that prepared3's reducer accepted an unrelated
minimal stopped-state document, an existing FGN public result, and fabricated
hash-linked completion flags/counts without native measurements. This is a
confirmed admission defect, not a valid native result. Prepared3 remains
preserved and unlaunched; its reduction example above records that historical
artifact and must not be used for scientific admission.

The replacement path records the admitted runtime's descriptor, instance,
session ID, launcher/owner/native child PIDs, acquisition generation/domain and
source owner before collection. Reduction requires that exact runtime's final
state, completed exposure count, `admitted=false`, no lifecycle error, and
absence of the owned instance after public shutdown. Final native owner and
native supervisor reports, startup CORRECT/RUN and probe command acknowledgments,
four complete native CB streams, and the bounded association journal are retained
before cleanup and bound by an evidence manifest.

The cold verifier reads the actual native payloads. It verifies chronological
probe adoption and physical Float32 figures, every raw/calibrated/gradient
bucket and sync, each positive exposure identity/model interval, and the recorded
payload hashes. It recomputes descriptive calibrated-pupil validity and raw ADC
diagnostics, rejects accepted invalid frames and all rail hits, and reconstructs
each public batch mean using the existing server's Float64 sum followed by
Float32 conversion. The result must match the public CalibrationClient values
bit for bit. Standard `collect` produces batch means without invoking `capture`;
the retained full-rate native CB streams are the per-frame evidence for this
path. No additional exposure or alternate WFS calculation is introduced.

The original CCR-016 reproducer now fails before candidate creation with
`missing actual native runtime identity`. Focused regressions pass exporter 82,
owner 82 and actual-evidence verifier 10 assertions. Payload mutation, changed
public means with self-consistent replacement hashes, reordered adoption,
native PID mismatch, changed ADC diagnostics, missing streams and unrelated
stopped runtimes are rejected. This is software verification. Independent review
and a fresh nondebug N2 standard-plan run, actual reduction and public shutdown
precede full scientific acquisition; old v12 diagnostic evidence lacks the newly
recorded calibrated/gradient digests and is not relabeled as new-protocol evidence.

Exact sealed recipe frame and settling counts are required at preparation.
The frozen N16 training and N64 held-out/locked plans use the same bounded
completion protocol and their own original seeds, chronology, public AOC files
and plan hashes. Successful full matrices, independent held-out inverse utility,
native 253-coordinate mapping, and unchanged gain/pole correction remain separate
scientific gates. A 277-coordinate physical response candidate is not directly
installed as a native controller matrix.


## Nondebug completion evidence and ordinary streaming limitation

The fresh nondebug N2 standard-plan run `heart-calibration-copper-n2-evidence1`
completed seven WFS exposures, three native DM figures and four accepted frames.
Its public shutdown left the same instance stopped and unadmitted; the actual
native payload verifier and public AOC reduction passed. Independent review
reproduced the Float32 secant exactly and confirmed all 71 retained evidence
hashes and the absence of the six owned PIDs. The resulting 3600×1 response is
an unaccepted functional candidate, excluded from the frozen scientific cohort.

The subsequent fresh training reference (`hn-ref1`) completed N32/S1 plus
restoration: 34 WFS records, two DM records and 32 accepted frames. Raw ADC
maximum was 4,038 with zero rail hits; the one initialization settling exposure
was invalid and discarded. Public shutdown passed. The independently seeded
qualification reference (`hn-ref2`) failed on its fourth exposure. Its retained
raw/calibrated bucket 3 has sync 4, whereas gradient bucket 3 is INVALID,
progress 0/3600 and sync 3. The native log explicitly reports error 102,
“Read counter has jumped from 2 to 4”. This failure prevents reference sealing
and full-cohort scientific admission for ordinary streaming ingress.

The unchanged native streaming reader selects the most recent nonempty write
bucket, including UPDATING buckets (`hrtCircBuffer.c`, `local_setReaderMostRecent`).
The input worker initializes the next calibrated bucket before blocking for the
next UDP frame (`hrtWfsInputBlock_handlerParamsUpdate`). If Proc reads after this
initialization, it can select the next unadmitted bucket and reject the skipped
counter. The failed reference demonstrates this native reader rejection; its
precise scheduling cause remains unestablished. Proc uses a semaphore between
frames, so a continuous idle Proc spin is not established. Host RT budget
throttling and datagram timer catch-up are hypotheses, not accepted root causes.
Increasing fixed row pacing is not proof of a reader association handshake.

### Explicit deferred comparison ingress

The reviewed unchanged native fixture revision
`6a5c06b11a8b934effeb6328a73a70895b2af94a` already contains a separately selectable
comparison ingress mode. `HRT_DEFER_WFS_INGRESS=1` receives both ordered 32-row
datagrams, publishes the first 32 calibrated rows, waits for same-sync Proc 32-row
and Recon 1800-input snapshots, then publishes the final 32 rows. Its waits are
bounded and the native scientific operators remain in place. No HEART source
change or rebuild is part of this adapter extension.

The public HEART calibration exporter accepts `--native-ingress-mode deferred`
(or `native_ingress_mode="deferred"` in `export_package`). The default is
`streaming`, which explicitly forces environment value `0` even when the parent
environment requests deferred ingress. Preparation requires Copper 64×64 with
exactly two 32-row datagrams, the reviewed source revision and the already
compiled gate markers. The sealed provenance binds the native executable hash,
source revision, mode and transport shape. The supervised owner verifies the
actual owned child's `/proc/<pid>/environ` before native initialization; the
initial/final hold proofs and cold native evidence verifier require that same
readback and mode. Missing or inconsistent evidence fails admission.

Deferred mode is an explicitly selected completion calibration comparison
fixture. It requires a fresh nondebug N2 run, independent references, full
matrices, validation and correction evidence before scientific acceptance.
Its qualification does not establish ordinary progressive streaming, physical
camera behavior or cadence. The original failed streaming artifacts remain
preserved; the ordinary streaming limitation remains open.


The fresh deferred preparation is retained under
`~/.cache/rtc-calibration-completion-20261003/heart-native-deferred-v1`.
All 15 packages passed 7,379 artifact hash checks before acquisition. N2's
deployment descriptor is
`da655a2f60b4e8046e1f68a7165e0ac34d96d61c69d14b0a4962693b10ee678c`;
its fresh owner evidence root is `hn-d1-n2`. The two N32/S1 reference packages
use the original independent seeds 522 and 523. The twelve scientific packages
retain their original N16 training or N64 validation plans, seeds and chronology.
None of these preparation checks constitutes acquisition acceptance.

Focused software checks pass exporter 106, calibration owner 87, actual native
evidence verifier 11 and native supervisor 26 assertions. These checks reject
unknown modes, wrong shape/packetization, wrong reviewed source revision,
missing compiled gate markers, ambiguous/missing environment entries and a
retained child environment that differs from the selected mode. The actual
unchanged native binary passed its compiled feature check, with executable SHA
`1c0862686dc79d127033845a12d32a0d12ac4ccc24a28396f69d0233b16ef9d1`.

Preparation elapsed time is recorded for each immutable package. The fresh
`run_native_plan_v2.jl` and `run_native_reference_v2.jl` drivers record monotonic
nanoseconds for startup readiness, first-call-inclusive public `run_plan`, public
shutdown and total execution; plan reduction has a separate elapsed time. Public
`run_plan` also records acquisition, public mean/count validation, and retained
payload verification phases. Report these wall phases separately. Their sum is
not an RTC cadence, throughput or frame deadline qualification. The reference
freezer revalidates the exact deployment descriptor/all package artifacts, every
retained evidence manifest entry and the actual stopped runtime before executing
the sealed native payload verifier or freezing the independent reference bytes.

### Completed deferred reference pair

The fresh nondebug deferred N2 run completed its seven WFS exposures, three DM
records and four accepted measurements; public shutdown and actual retained
payload reduction passed. This is a bounded functional result, not full-matrix
or correction qualification.

Both deferred flat references then completed 34 exposures, two DM records and
32 accepted frames each. Their actual final runtimes are stopped and unadmitted,
and public shutdown passed. Each reports only the declared initial invalid
settling frame; ADC maxima are 4038 and 4009, with no rail pixels or rail frames.
Independent review replayed both native payload verifiers and checked all 132
retained manifest entries. The v3 cold freezer additionally revalidated 1121
consumed inputs, including the exact helper it executes.

The native reference bytes differ from the common FGN reference. The native
qualification mean also differs. Therefore native analysis uses its own measured
reference and fixes Q = I − rr′/(r′r) before training selection or validation.
The relative differences, approximately 0.0043411 and 0.0044456, are descriptive;
they do not establish a cause or introduce a tolerance for reference reuse.
The retained seal is
`~/.cache/rtc-calibration-completion-20261003/heart-native-deferred-reference-freeze-v3/native-reference-freeze.json`.

| Frozen input | SHA-256 |
| --- | --- |
| Reference seal | `88392a6532962fa4fa5124fa88bd19aac0af18ee8bf2d7abfe21c4591503d946` |
| Native reference Float32 bytes | `fc208d76e9f0dcccede3e6c36e9e08eb0c1af151fe9cbc2ef05546d7e5259db8` |
| Independent qualification Float64 mean | `2aad68e2fe0d0fc16fb9d26b25ffaa9703b862a40b19e5fd44b43154bc2a79b1` |
| Unchanged selection policy | `609f47b6b1f3d5d43a1d4ba989b3e9f97fef5efcecf53a16b9859e63ec23ab3a` |

The reviewed v3 cohort driver runs only one explicitly named stage or a named
pair from the same family. Every stage must complete capture, public shutdown
and bound reduction before the next stage starts. It rechecks the native
reference seal, all its consumed inputs, policy and ingress equality. Interrupt
cleanup remains owned by the parent wrapper. Training matrices, inverse
selection, independent held-out/locked validation and active native correction
remain separate acceptance gates.

### Active Copper correction preparation

`HeartCorrectionExport` prepares a fresh ordinary native CORRECT deployment
after actual native locked utility. It repeats the retained reference,
training, public AOC reduction, inverse fit, validation selection and locked
measurement checks in a cold process. The first production replay revalidated
ten captures and both references, reproduced the selected Hadamard-1 estimator
and controller bytes, and passed in 571.86 seconds on one CPU thread. This
preparation result does not qualify active correction.

The normal dynamic plant, detector, model chronology and four scientific
helpers (`simulator.jl`, `owner_protocol.jl`, `correction_truth.jl`,
`analyze_correction.jl`) remain byte-identical to the selected normal base.
Native Copper uses the selected negative 253-coordinate estimator with its
original gain +0.01, CLWC pole 0.99 and scalar 1. The actual Float32 projection
maps those coordinates to 277 physical micrometre-OPD demands. The public
standard DM receipt and adopted plant command use metre OPD.

Before admission, the owner binds the fresh native PID/generation, exact INIT
configuration and calibration inputs, strict SUCCESS acknowledgments for
thirteen required runtime flags, startup CORRECT and its own active CORRECT.
This is acknowledgment and source/configuration evidence; it is not a private
GMS readback. The held RUN proof is cleared before publishing an active frame.

Every retained 256-frame window requires exactly 256 raw, calibrated, gradient
and unclipped VDM records, plus 258 physical DM records: initial zero at sync 0,
commands 1:256 at their matching positive sync, then restored zero at sync 256.
Native state changes rotate all five recording files asynchronously. The active
owner admits three distinct phases: startup RUN, CORRECTING, and restore RUN.
All five empty file headers must be present and valid before publication in the
new phase. It drains the preceding readers, verifies their exact counts, and
closes them when the native writer has moved to the new files. Each file's
header count is local to that file; CB bucket numbers remain global. All 15
files, including the eight empty RUN WFS/VDM files, are retained and checked.
Startup DM uses bucket/sync 0/0; active DM uses 1:256/1:256; restoration uses
257/256. Standard DM receipts match those exact sync values. The zero sequence
opt-in applies only to startup, because a zero restoration figure retains sync
256.

The first corrected-startup experiment directly observed startup and the first
CORRECT exposure in distinct files, then failed under the old unique-file
reader. A read-only replay reproduces that rejection and verifies the original
per-file/global counters and payloads. Three-phase synthetic tests cover the
new gate, full count/association checks, duplicate and partial files, and exact
receipt mismatches. Actual restoration, both complete windows, and scientific
utility still require a fresh experiment; this software verification does not
qualify those gates.

VDM records have null-header creation sync 0 and are associated by serialized
bucket count/order. Their actual Float32 projection is checked independently
against the physical DM record, with a rounding bound and margin below the
native clipping limits. Output rail proximity alone does not establish this
no-clipping condition.

The public reset stops the old native child, retains and validates its closed
files, then binds a new PID/generation. Journal counters restart in a fresh
directory while the independent positive probe token remains monotonic. The
two windows must reproduce actual ADC, adopted command and direct OPD witness
bytes. Public shutdown and the two direct-truth/zero-command replays remain
required empirical gates.

Timing fields in final native reports describe CLOCK_MONOTONIC application
exchanges from before model generation through publication, native association,
receipt and actual adoption. They do not measure exact native callback time,
RTC latency, RTT or cadence. `heart_correction_analysis.jl` supplies the frozen
analyzer's historical exchange field names through an in-memory `ReportView`
only; it writes no compatibility report. The returned report path/hash names
the original native report. Raw ADC bytes, command bytes, native counts,
strict acknowledgments and unclipped VDM projection are revalidated before
the unchanged scientific replay is called.

This path is restricted to the separately qualified compiled deferred Copper
ingress fixture. Ordinary progressive ingress CCR-017 remains open. Classic
uses a different native coordinate map and gain sign and requires its own
explicit operational background/reference/permanent eligibility binding.

### Normal correction ADC policy and retained failed experiment

The first complete native Copper active window processed 256 exposures and
commands, drained all three telemetry phases, and restored a zero physical
figure with global DM bucket 257 and exact wire/CB sync 256. It then failed the
adapter's additional zero-rail check. The original failed report and lifecycle
remain failed; restoration does not establish correction utility.

The read-only audit `native-active-adc-policy-audit-v1.json` records two ADC
rail pixels in that native window and in each of the six preceding FGN CUDA,
JFG CUDA and FGN AMD correction batches. Their locations are identical: frame
21 at row 18/column 26 and frame 26 at row 26/column 18 (all indices one-based).
No value exceeds 16,383. The native raw telemetry is bit-identical to its
retained ADC payload. The shared frozen correction analyzer accepts ADC values
up to and including the declared rail; its utility gate requires exact detector
and direct OPD replay plus a verified zero-command baseline. It did not require
zero saturation. The calibration policy still requires zero rail hits.

After this observation, the primary agent explicitly approved alignment of
future normal correction experiments with that original correction policy.
Fresh contracts declare `normal-correction-adc-bounded-replay-v1`. The active
owner and analyzer independently recompute maximum ADC, rail pixel/frame counts
and response invalid counts from every retained raw/gradient record. They compare
all diagnostics to the report, reject above-rail values and nonfinite responses,
and allow only the first declared Copper initialization response to be invalid.
Classic uses the separately declared flux-state policy below. Rail
pixels remain in the detector payload and truth replay. No observed hit count
is an acceptance threshold. Actual ADC/truth replay, independent demanded-figure
clipping exclusion, positive utility, both reset windows and public shutdown
remain required. This policy change does not retrospectively accept the failed
experiment, and it changes no illumination, gain, inverse or native algorithm.

### Scoped Classic active correction preparation (historical pre-run contract)

The Classic active path consumes the completed bounded four-direction native
transfer through the maintained `HeartClassicTransfer.replay_admission` API.
It repeats source, data, package, lifecycle and every native payload/mean/math
binding before installing an inverse. The transfer qualifies reuse of the
already selected inverse on those sparse/mixed directions; it is not a new full
native calibration fit. Score issuance, replay and export use the same immutable
SDK root because the score binds the consumed SDK and HIL worker identities.

The accepted controller has 221 coordinates. Native Classic integration and
`cbClUnclipped0` have 277 padded coordinates. The explicit full-to-active
selector T determines S = Tᵀ; its controlled indices are nontrivial and include
native index 268 (one-based). The exporter proves exact Float32 E_native S = B
and installs R_native = S R_selected, preserving positive-zero inactive rows.
The retained VDM record precedes the unchanged sparse E operation. The demanded
physical figure is independently computed through E once, followed by native
identity P. Native source and loaded configuration retain HO gain −0.3,
CLWC pole 0.99 and scalar 1, with no LO input. Thus the accepted positive inverse
has the original negative correction polarity; Copper's negative inverse and
positive gain convention are not applied to Classic.

Classic keeps the actual 352×352 calibrated/raw detector, 188 native
state/x/y/flux records and 376 interleaved measurements. Scale is explicitly 1;
there is no guessed angular conversion. Measured operational background,
reference and eligibility are bound to the accepted plant. Disabled native
subapertures use permanent state −1, since state 0 can reactivate. Raw inactive
slopes are retained. The accepted inverse's disabled measurement columns are
exact positive zero. CORRECT only marks mask updating and resets weighted-CoG
averaging; it does not clear the loaded per-subaperture reference calibration.

Profile dispatch applies the same strict three-phase ownership, global bucket
and exact exposure sync checks. Classic declares 128 MiB per telemetry file.
Its largest 256-record calibrated phase requires 126,895,104 bytes including
headers and aligned payloads; raw pixels require 63,456,256 bytes. A sparse-file
fixture proves the old 16 MiB bound rejects that extent and the declared bound
accepts it without allocating a simulated frame corpus. Separate synthetic
retained-record tests cover all 15 phase files and 256 Classic records. These
are software checks. At that preparation checkpoint, actual normal native
Classic correction, reset, detector and OPD replay, zero baseline and public
shutdown were still empirical gates. The completed successor results are
recorded below.

## Classic active startup flags: CCR-031

The first sealed Classic active package failed before acquisition because the
owner validated its correct 24 runtime flags against Copper’s exact 13-flag
set. This was an adapter startup defect; the native configuration and selected
inverse were unchanged. The failed package and lifecycle remain failed.

The successor uses a shared profile-specific validator in export, owner load,
startup proof and retained analysis. Copper requires its original exact set of
13 flags; Classic requires its exact set of 24. Missing, extra, duplicate and
wrong-valued flags are rejected. Both original sealed contracts load through
the corrected owner; independent actual-contract tests pass 42 assertions.
Source-v7 freezes all 151 deployment source identities, with only the flags
fix, its resource closure and associated tests changed from source-v6. A fresh
managed Classic transfer replay and public export under that same SDK root
precede the successor run. This software verification does not establish
Classic active correction utility.

## Actual Copper active correction completion

The source-v6 successor completed both 256-frame windows and reset under a
fresh native generation. Each window retains 256 raw/WFS/VDM records and 258
DM records: startup zero, 256 exact positive-sync updates and zero restoration
at sync 256. The independent physical-demand projection excludes native DM
clipping. All 15 phase files are retained and revalidated.

The normal detector diagnostics retain the two saturated pixels in two frames,
maximum ADC 16,383 and the declared first invalid measurement. They satisfy
the explicitly aligned normal-correction policy; calibration still requires
zero rail hits. Direct truth, exact ADC replay and the zero-command baseline
all pass. Both repeated windows reproduce variance ratios 0.7153282641 for
frames 17–128 and 0.6490191125 for frames 129–256. Maximum command is
0.15432382 µm OPD, with zero components at the 0.8 µm limit; the separate
native-demand witness supplies the clipping proof.

The retained `native-correction-active-v7-evidence.lifecycle.json` has SHA-256
`75b582b9e4a644a2ab12f3df9189917d8a4197efd6429e64b505cb7ab5b884ad`
and confirms both batches, both replays and public shutdown. Its final state
is stopped, unadmitted and without error. This completes the scoped Copper
application correction gate. Whole-exchange completion observations do not
qualify native RTC latency, hardware or ordinary progressive-ingress cadence.

## Classic graph boundary selection: CCR-032

The second Classic active attempt failed during source preparation: the active
owner requested `pwfs_frame` from the Classic graph, whose normal public
preparation selects `shwfs_frame`. The external first-window directory was
empty; no correction utility was established. The failed lifecycle, package
and source-v7 remain unchanged.

Source-v8 selects the frame output from the validated profile descriptor:
Classic uses `shwfs_frame` with a 352 × 352 detector; Copper keeps `pwfs_frame`
with a 64 × 64 detector. The owner checks the resulting detector extent and
277-element physical command boundary. Neither graph nor any of the four
frozen scientific helpers was edited. Only the owner, profile descriptor and
profile tests changed.

Cold CPU tests reproduce the old failure on the captured Classic graph and
exercise the production successor on both actual profile graphs. Each corrected
graph passes 22 assertions covering exact graph/input/output binding, extents,
unsupported and wrong-profile rejection, recorder/truth preparation, first
model timestamp zero, model sequence one and reproducible first ADC/truth after
reset. The broader source audit checks acquisition, decode, phase/capacity,
E/P projection, ADC diagnostics, reset and retained analysis; no additional
profile defect was confirmed. Independent production Classic graph verification
passes 15 assertions. Fresh same-root managed replay/export and actual Classic
correction remain separate gates.

## Classic native runtime map links: CCR-033

The third Classic active attempt reached startup proof but failed before frame
admission. The public native owner creates `runtime/config` symlinks to the
sealed package calibration files. Classic startup passed that symlink directly
to the strict sparse-map decoder, which correctly rejected it. Copper already
resolved its analogous FITS path. The failed package and lifecycle remain failed.

Source-v9 resolves the runtime extrapolation path, rechecks its exact sealed
`runtime_inputs` digest and then calls the unchanged strict sparse decoder.
All earlier calibration-input digest checks and the native-to-wire matrix
comparison remain in place. Direct arbitrary symlinks are still rejected by
the parser. Cold tests use the actual sealed Classic package and the public
`HeartOwner.arguments` runtime layout, reproducing the old rejection and
checking exact resolved matrix bytes plus altered link-target rejection. Unit
tests also reject in-place target changes. No native source, sparse-map bytes,
scientific helper or controller coefficient changed. Fresh same-root replay,
public export and actual correction still precede Classic acceptance.

## Classic normal flux classification: CCR-034

The fourth Classic active attempt reached CORRECT and completed the first native
measurement, then failed the correction adapter's Copper-specific invalid-frame
rule. The retained Classic record contains two eligible subapertures below the
unchanged 1000-count flux threshold (zero-based indices 70 and 87, flux 947.1875
and 989). They have native state 0 and retain finite nonzero reference-subtracted
slopes. The four permanently disabled subapertures remain state −1. The initial
hypothesis that disabled sentinel slopes caused this failure was rejected.

The actual first ADC frame matches the accepted FGN and JFG normal Classic
frames byte for byte. Native reconstruction excludes state-zero subapertures;
FGN and JFG emit zero slopes for these invalid subapertures. The actual initial
native VDM agrees with the masked selected-inverse prediction within
6.16 × 10⁻⁸ µm; the unmasked prediction differs by 0.02585635 µm. This establishes
normal flux dropout behavior, without changing thresholds, eligibility, gains,
references, the selected inverse or the native scientific operators.

Source-v10 declares a separate normal Classic response policy. Every raw slope,
flux and state remains retained. Eligible state 1 requires finite flux > 0 and
flux ≥ the sealed threshold; the complementary finite flux requires state 0.
Permanently ineligible subapertures require state −1. All slopes and fluxes must
be finite. A sealed Float32 threshold artifact records the actual native FITS
values; the native file digest is also checked against the runtime-loaded input.
Live and retained validation use the same classifier and independently compare
per-frame and per-subaperture dropout diagnostics. Dropout responses retain
`valid=false` and remain in the normal correction window. Held calibration's
all-active validity guard and Copper's first zero-lag initialization rule remain
unchanged. The failed fourth attempt remains failed. A fresh source-v10 managed
score, public export and two-window successor experiment now provide the actual
results below.


## Actual Classic active correction completion

The source-v10/package5 successor completed two 256-frame native CORRECT windows
with the accepted positive padded inverse, original sparse E, HO gain −0.3 and
pole 0.99. Native generations 1 and 2 have distinct child PIDs. Reset reproduces
ADC, adopted command and direct-truth payload bytes exactly. Each window retains
256 raw/WFS/VDM records and 258 DM records, including startup zero and restoration
at exact sync 256. All three phases and 15 files pass retained verification;
the independent E/P demand witness excludes native clipping.

Both windows record maximum ADC 449, zero rail pixels and zero rail frames.
They retain 236 invalid-but-classified response frames and 544 eligible
subaperture dropout samples per window; eight eligible subapertures contribute
these samples. Raw slopes and native states remain unchanged, and the four
permanently disabled subapertures remain state −1. These diagnostics describe
normal science flux dropout, not accepted calibration measurements; calibration
still requires all eligible subapertures valid and no rail hits.

Direct-truth and exact ADC replay, verified zero-command baseline and positive
utility pass in both windows. Residual/atmosphere variance ratios are
0.04428151441912413 for frames 17–128 and 0.03440108015053748 for frames 129–256.
Maximum physical command is 0.3789594 µm OPD, with zero components at the 0.8 µm
limit; the separate native-demand witness establishes clipping exclusion.

The retained `native-classic-correction-active-v5-evidence.lifecycle.json`
SHA-256 is `334d893155e4442b4e638ea13efb1735c59b1b8812e95f4b840c88367a32fe39`.
It confirms both batches, exact reset reproducibility, both replays and public
shutdown, with final state stopped, unadmitted and error-free. The two analysis
SHA-256 values are `565e6680f691f0db805f1d33aa80dc1ae77468ea85768149d70a37e75f49ea60`
and `eab83f9ff7e17c61de102425b559ecb8f7f94f4d29d4d7476bbb7e430a96da77`.
Independent cold final review accepts this actual run after rehashing 1,573
inputs, verifying recurrence/projection, all phase counts, replay and cleanup.
Audit `native-classic-windows-independent-v5.json` has SHA-256
`2550220c39a78c08b5f9953eef459068f523fe80ddce367d519997530c56a094`. The bounded transfer supports
reuse of the accepted Classic inverse; it does not claim a new full native
Classic calibration fit. Application completion observations establish neither
hardware performance nor native RTC latency or cadence. Earlier failed packages,
reports and lifecycles retain their original failed dispositions.
