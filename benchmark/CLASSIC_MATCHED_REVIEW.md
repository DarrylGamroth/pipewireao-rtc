# REVOLT Classic matched-chain review

Date: 2026-09-30. Status: source analysis and proposed comparison configuration;
no Classic three-way numerical or timing qualification has been run by this review.

## Scope and provenance

The requested boundary is the real recorded Classic 352 × 352 U16 detector,
188 Shack–Hartmann subapertures, and 277 physical DM commands. The comparison
must execute the developed HEART, Calculon FGN, and JuliaFilterGraph scientific
chains, including clipping feedback. HEART source and executable remain unchanged.

This artifact is characterization planning under [the active authority map](../docs/README.md)
and [development architecture](../docs/architecture.md), not a promotion of archived
operational or physical-correction capabilities. The existing
[Classic callback result](CLASSIC_DEVELOPMENT_PERFORMANCE.md) validates FGN against
the direct Calculon implementation; its timed boundary excludes transport,
scheduling, and feedback carry. It does not establish equivalence to HEART or JFG.

Review worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`,
branch `copper-progressive-requal-20260929`, starting commit
`5f7e37e9dd5995d613da6858e096acb5162346f9`. Existing benchmark edits and untracked
progressive reports were present and were not modified. HEART source inspected:
`/home/dgamroth/workspaces/codex/heart/heart-copper-comparison`, revision
`6a5c06b11a8b934effeb6328a73a70895b2af94a`.

Source roots used below:

| Name | Path |
| --- | --- |
| HEART | `/home/dgamroth/workspaces/codex/heart/heart-copper-comparison` |
| Calibration | `/home/dgamroth/workspaces/codex/heart/revolt-rtc` |
| Profile/loader | `/home/dgamroth/workspaces/codex/pipewire/plugins` |
| FGN algorithms | `/home/dgamroth/workspaces/codex/pipewire/calculon-algorithms-progressive-requal` |
| JFG | `/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-progressive-requal` |

“Observed” below includes directly inspected source/configuration. “Derived”
means mathematical consequence of those implementations. Runtime equivalence
remains to be measured; source inspection does not establish successful delivery.

## Findings

### CL-01 — Existing Classic defaults do not identify one reconstruction

Severity: high, comparison correctness. Confidence: high. Disposition: use a
matched configuration overlay and existing calibration files; no HEART change.

**Observed:** [the profile](/home/dgamroth/workspaces/codex/pipewire/plugins/profiles/revolt-classic.toml)
selects 221 controlled rows from a 277 × 376 reconstruction matrix, and compacts
the extrapolator to 277 × 221. The explicit zero-based actuator list is not the
first 221 physical indices; its last index is 267.
[HEART's simulation configuration](/home/dgamroth/workspaces/codex/heart/revolt-rtc/config/classic_config_sim.yaml)
uses a 277-element reconstructed vector and 277-element VDM, but supplies no
`HO_CONTROL_MATRIX_FILE`. `hrtHoReconBlock.c:1254–1284` loads that file when
specified and initializes a zero matrix otherwise. Running that YAML unchanged
does not exercise the profile's nonzero reconstruction.

The loader's `compact_heart_reconstruction` (`artifacts/mod.rs:632`) rejects
nonzero uncontrolled reconstruction rows. `compact_heart_extrapolation` (`:578`)
checks identity controlled rows and rejects dependencies on uncontrolled input
columns. `vdm_truncation` (`:671`) builds the explicit controlled-index selection.
These are checked calibration preconditions, not assumptions based on matrix shape.
Read-only data inspection also confirmed that all 12 artifact SHA-256 values match
the profile, and that the actual sparse file has 12,597 entries and exactly 221
singleton unit rows, precisely the declared controlled-index identity rows.

**Derived:** retain HEART's original 277-dimensional padded controller and original
277 × 277 sparse extrapolator. Use the existing compact 221-dimensional FGN/JFG
controller. Let S embed controlled coordinates in the physical ordering and
T = Sᵀ select them. With original matrices C₀ and E₀ and compact matrices C and E:

```text
C₀ = S C             C: 221 × 376
E = E₀ S             E: 277 × 221
T E = I₂₂₁           T: 221 × 277
HEART state = S × compact state, provided initialization is zero and
POL/hidden-mode/other additive paths are disabled.
```

HEART constructs its truncation by scanning `row < vdmSize`, selecting singleton
unit entries in the sparse extrapolator (`hrtClwcBlock.c:7460–7546`). Merely changing
HEART to `VDM_SIZE=221, FULL_SIZE=277` would omit controlled physical rows above
220 from that scan. The padded configuration avoids changing this source behavior.
The two representations are mathematically equivalent under the listed
preconditions; their operation counts differ and must be disclosed in timing.

**Required validation:** load and hash all calibrations; check these identities
after F32 conversion; compare the controlled rows of HEART reconstruction/state
to the 221-element FGN/JFG vectors and compare all 277 physical commands. Record
the 56 uncontrolled HEART entries separately and require them to remain zero.

### CL-02 — Match controller update order, clipping feedback, and optional paths

Severity: high, numerical equivalence. Confidence: high for update equations;
runtime flags still require capture. Disposition: explicit matched overlay.

**Observed:** the Classic profile has gain −0.3, pole 0.99, and anti-windup gain
1.0. HEART applies temporal gain and then integrates `S ← p S + error`
(`hrtClwcBlock.c:2289`). After command clipping it applies
`S ← S − p × clipped_amount` (`:2629–2651`); clipping feedback initializes enabled
(`:7681`). With g = −0.3, p = 0.99, reconstructed error rₙ and controlled clipping
feedback fₙ, the emitted unconstrained command therefore obeys:

```text
u₀ = 0, f₀ = 0
uₙ = p uₙ₋₁ − p² fₙ₋₁ + g rₙ
dₙ = E uₙ
qₙ = clamp(dₙ, −0.8, +0.8)       277-element physical command
fₙ = T (dₙ − qₙ)                221-element feedback
```

The developed Rust and Julia `closed_loop_correction` implementations instead
form `state = previous_output − anti_windup_gain × previous_feedback`, then
`output = pole × state + gain × residual`. See
[Julia's update](/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-progressive-requal/julia/FilterGraphAlgorithms/src/algorithms/control/closed_loop_correction.jl:180)
and the corresponding Rust algorithm in
`crates/calculon-algorithms/src/algorithms/control/closed_loop_correction.rs`.

**Derived:** set FGN/JFG anti-windup gain to **0.99**, not the profile default
1.0, to reproduce this HEART update order. Preserve the original profile as
provenance and label the override. This changes no scientific implementation.
Setting all poles to 1 would conceal the mismatch and change the selected law.

**Observed:** HEART YAML has `HO_POLC: 1`, two uncontrolled modes and TT projection
paths. Configuration presence does not prove their runtime application:
`hrtHoReconBlock.c:1578` checks POL enable state; `hrtClwcBlock.c:2667` requires
both `unctrlModeRemoval` and `enableUnctrlModeFeedback`, the latter initialized
to zero (`:7680`). `UNCTRL_MODE_REMOVAL` is a separate configuration key.

For the minimal common law, explicitly disable HO/LO POL correction, uncontrolled
mode removal, optical-gain dithering/optimization, and other additive correction
paths; use unit optical gains, zero system flat, zero PDM offset, no slew limit,
and no temporal IIR. Keep clipping feedback enabled. Record the effective runtime
flags after startup. Disable optional PSD computation for the minimal processing
configuration and disclose that choice. TT projection filenames alone are not
evidence of TT removal; do not invent an extra TT projector in FGN/JFG.

**Required validation:** begin each replay with zero state; feed the preceding
successful sample's feedback exactly once; compare a sequence with nonzero
clipping feedback. Unsaturated samples alone cannot distinguish gains 1.0 and
0.99. Capture preclip commands, physical clipped amounts, and controlled feedback.

### CL-03 — Reuse developed complete chains, with calibrated SHWFS geometry

Severity: high, workload identity. Confidence: high. Disposition: harness/config
composition work required; algorithm replacements are unnecessary.

**Observed:** FGN's `examples/revolt-classic-filter-chain.conf.in` is an existing
nine-node chain: pixel calibration → image SHWFS measurement → reconstruction →
closed-loop correction → controller-to-VDM → VDM-to-PDM → PDM command limiting →
PDM-feedback-to-VDM → VDM-feedback-to-controller. It exposes feedback for the host
to delay. The profile direct replay and exporter already load and transform the
real artifacts. Historical FGN/direct checks are documented in
`docs/fgn-revolt-classic-qualification.md`; they do not qualify HEART or JFG.

JFG's `examples/julia/shack-hartmann-scao.conf` is illustrative: it uses default
geometry/calibration, a leaky integrator, a 289-element full VDM, and exported
feedback that is not consumed. It is not the matched Classic fixture.
JFG already has the required closed-loop correction and projection Algorithms;
`fixtures/pipewire/rtc-latency-copper-full-frame-feedback.conf` demonstrates the
feedback composition. Its constants must be replaced with Classic values, and
its PWFS measurement replaced with the developed complete-frame SHWFS Algorithm.
The existing `PreparedFeedbackBridge` in `julia/FilterGraphPipeWire/src/graph_node.jl:433`
stores feedback, and `:1606` copies the candidate feedback only on terminal
success. Reuse that host mechanism, including its first-sample behavior.

**Observed:** HEART's nonempty pixel-threshold file enables thresholding even
with `SHWFS_GRAD_TYPE: 0` (`hrtWfsProcBlock.c:1221–1244`). Its thresholded moment
code retains a pixel at equality and does not subtract the threshold
(`hrtWfsProcSH.c:167,199`). Local normalization uses moment/flux and subtracts
reference slopes (`hrtWfsProc.c:312–417`). Flux below threshold makes the subaperture
inactive; the reconstructor skips inactive subapertures (`hrtHoReconBlock.c:2504`).
HEART raw gradient telemetry can retain a nonzero value for a low-flux inactive
subaperture. Compare validity and effective masked gradients, not an unconditional
raw-telemetry equality assertion.

**Required validation:** exact pixel order and zero-based row/column origins;
interleaved x,y slopes; supplied coefficient arrays rather than regenerated
uniform-grid coefficients; pixel threshold 20 with inclusive acceptance; flux
threshold 1000; identical active mask and reference subtraction. First qualify
all seven recorded frames and then stateful repeated frames with clipping.

### CL-04 — A supported Classic full-frame HEART ingress gate is unresolved

Severity: high, timing claim scope. Confidence: high for inspected paths;
medium for absence of another supported control. Disposition: comparison scope
adjudicated by the user on 2026-09-30; HEART remains progressive and unchanged.
Native complete-frame HEART admission is not required for the selected comparison.

**Observed:** stdWfs sets `params->isStreaming = true` unconditionally
(`hrtStdWfsHandler.c:928`). `hrtWfsInputBlock.c:1054–1061` copies that property to
the GMS `streamingFlag`. The GMS definition `hrtGms_wfsInput.gms:14–19` describes
false as delaying the downstream trigger until complete receipt. The source has
a non-streaming input path, but the inspected YAML parser and stdWfs initialization
do not expose a selection for it.

`outputIsFullframe` is a different property: its GMS definition explicitly delays
the trigger until all pixels have been **processed**. HO pipe construction sets
it to zero (`hrtHopLopPipe.c:695`, `hrtHoPipe.c:611`), while LO sets it to one.
`hrtWfsProcBlock.c:4461` suppresses the early downstream trigger when it is set;
`:4617` supplies the final trigger. SHWFS calibration/measurement still runs
progressively in `processPixelStream`. It is not a detector ingress gate.

`HO:CONTROL_MVM_STREAMING_INPUT=0` selects an MVM implementation, not a
full-frame SHWFS input mode. With one partition the reconstructor still accumulates
columns as subapertures arrive (`hrtHoReconBlock.c:2545–2608`); multiple nonstreaming
partitions defer the MVM but not preceding pixel processing. No
`fullframeInputs` option was found in the inspected HEART source.

The existing comparison-build `HRT_DEFER_WFS_INGRESS=1` path explicitly requires
64 rows (`hrtStdWfsHandler.c:318–331`) and two 32-row datagrams (`:672` onward).
It cannot be reused for the 352-row Classic input by changing YAML alone.
Classic U16 payload is 247,808 bytes, so a single UDP datagram is not an option.

**Existing handler audit:** `hrtWfsCustom_lookupWfsHandler`
(`source/device/src/hrtWfsCustom.c:294–388`) registers the following paths.

| Handler | Existing complete-frame capability | Same FITS corpus through configuration? |
| --- | --- | --- |
| Standard WFS | Forces streaming at creation | External `wfsSimulator` reads FITS, then sends the ordinary streamed protocol |
| Andor, GigE GVSP | Set `isStreaming=true` | Hardware transport; no FITS replay option found |
| CBlue | Nonstreaming; waits for the image semaphore, then calibrates the whole image (`cblueWfsHandler.c:833–885`) | Camera SDK path; no FITS replay option found |
| GigE BGAPI2 | `CONFIG_STR="0"` selects nonstreaming in `bgapiWfsHandler_create` (`bgapiWfsHandler.c:1590–1625`); `readFrame` calls SDK `captureFrame` and calibrates the whole image (`:2131–2155`) | No FITS replay path found; the parsed `sim` connection flag does not provide a FITS reader |
| Aeron, EDT | Declare `supportStreaming=false`; receive hardware image buffers | No FITS replay option found; Aeron also rewrites the last pixel before calibration (`aeronWfsHandler.c:610–632`) |
| Dummy | Generates complete synthetic frames and calibrates them (`dummyWfsHandler.c:269–337,425–468`) | Generates a frame/row/column bit pattern, not file pixels; absent from standard lookup |

The six hardware choices are conditional on `HARDWARE` and their respective
driver build flags. The standard `scaoTemplate` entry point supplies no custom
WFS lookup (`source/template/src/scaoTemplate.c:517–518`), so the dummy source's
presence does not make it a configured built-in replay handler. No FITS/direct
WFS handler is registered. `wfsSimulator.c:27–31` explicitly describes the
existing FITS-cube-to-network simulator.

The command registry, WFS mutable configuration, and GMS sources expose no
supported WFS streaming-mode command found in this review. All source writes
to `streamingFlag` are the creation-time assignments from the driver's
`isStreaming` (`hrtWfsInputBlock.c:1056,1060`). A generic writable shared-memory
field is not an established post-INIT mode-change lifecycle. `LOAD_BUFFER`
(`hrtTemplateCmds.c:3940–4090`) does load FITS into a circular buffer, but does
not itself perform WFS calibration or drive the processing trigger chain. It
therefore does not establish a complete-chain internal FITS replay alternative.

**Unresolved:** whether an established, supported startup/GMS command can select
nonstreaming input coherently before block startup. Directly poking the GMS flag
would require review of progress initialization, calibration publication, and
reader selection; the exposed struct field does not establish that as a supported
configuration interface. Do not call it a validated no-source-change solution.

**Next discriminating inspection:** identify the documented command that sets
the WFS input mode, if one exists, and trace it through input initialization and
processing. If none exists, parent must adjudicate the comparison scope. A
complete-frame FGN/JFG comparison against normal streaming HEART can be labeled
accurately, but is not a three-way full-frame processing comparison. An external
frame gate or adapter is an architectural alternative requiring adjudication,
not an authorized implementation from this review. Sending packets in a burst
also does not guarantee full-frame availability before HEART starts processing.

**Accepted comparison scope, 2026-09-30:** retain normal progressive HEART
stdWfs and the unchanged `wfsSimulator` sender. Qualify FGN and JFG first in
complete-frame mode, then in row-block mode, against the same progressive
HEART reference. Preserve the same input corpus, packetization, pacing,
calibration and controller semantics. Measure first-packet → DM and
terminal-packet → DM for each explicitly labeled execution mode. Do not extend
the Copper deferred gate, add an external gate, or change HEART source. The
receiver-mode difference is intentional and must remain visible in results.

### CL-05 — Preserve units and distinguish numerical and transport boundaries

Severity: high, command correctness. Confidence: high for conversion code;
physical calibration meaning remains outside this review. Disposition: explicit
boundary checks in the proposed harness.

**Observed:** the existing JFG Standard DM adapter multiplies demanded command
values by `1.0f-6` before the SPA sink
([adapter](/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-progressive-requal/scripts/heart_std_dm_command_adapter.jl:37)).
The [Standard DM contract](/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugin-heart/docs/std-dm-protocol-baseline.md)
defines the ndarray boundary in metres and the HEART wire boundary in microns.
HEART's Classic `SCALE_FACTOR` is 1.0. Thus a graph command of 0.8 maps to
0.8 µm on the wire and 8 × 10⁻⁷ m at the SPA boundary. Compare decoded wire values
in one unit; allow the documented F32 round trip. Never apply a second ×10⁻⁶.

The coordinate coefficients and reference slopes carry the calibration's slope
scale. Do not add a generic pixel scale, arcsecond conversion, sign inversion,
or surface-to-wavefront factor of two. Physical interpretation of that calibration
is not established by numerical equality. The separate Classic simulated-plant
OPD-metre schema is a different boundary and must not be substituted silently.

**Required validation:** finite values and exact shapes at all boundaries;
calibrated pixels, effective slopes/validity/flux, reconstructed controlled error,
unconstrained controlled VDM, demanded 277-element PDM, and delayed 221-element
feedback. Use the existing absolute/scaled-relative F32 10⁻⁶ check as an initial
declared criterion in graph-native units, not proof that different accumulation
orders must pass. Report maximum absolute and relative errors per boundary and
near-threshold/clipping decisions; adjudicate any changed tolerance from evidence.
Do not apply an absolute tolerance of 10⁻⁶ metres to submicrometre commands.

## Concrete harness/configuration work

The following is proposed implementation work for the parent; this review did not
make these edits or generate new calibration files.

| Item | Required configuration/data |
| --- | --- |
| Input | Same `sim_wfs_data/classic_wfs.fits`, seven U16 frames; 352 × 352, identical frame order and identities. Preserve FITS `BZERO=32768` conversion. Start at the profile's 10 Hz for functional delivery, then separately declare any changed performance rate/readout. |
| Pixel calibration | `config/wfs_dark_unscaled.fits`, unit flat, zero additional dark/sky; preserve F32 subtraction and detector row order. |
| SHWFS | `cblueROIoffsets.csv`, `cBluePixelCoefs.fits`, `calPixThresh_20.fits`, `threshold_1000_188.fits`, `slopeOffsets.fits`, `validSubapMask.csv`; 188 regions of 22 × 22; local normalization and unit optical gain. |
| HEART reconstruction | Explicit `HO_CONTROL_MATRIX_FILE` for WFS 0 pointing to `REVOLT2_CM_lab_20240917.fits`; keep reconstructed/VDM/full/PDM dimensions 277. Existing matrix loader converts FITS to F32. |
| FGN/JFG reconstruction | Existing loader's controlled-row C, shape 221 × 376, same controlled-index ordering. |
| DM mappings | HEART original `dmExtrapolationMatrixTT.sparse`; FGN/JFG E 277 × 221 and T 221 × 277; controller↔active VDM identities 221; full VDM↔PDM identities 277. |
| Controller | Gain −0.3, pole 0.99, FGN/JFG anti-windup 0.99, hidden-mode gain 0; HEART clipping feedback enabled; all states initially zero. |
| DM constraints | `dm_clipping_277_0.8.csv`, upper/lower ordering checked; zero flat/offset, no slew; preserve actuator order, do not reinterpret the 19 × 19 display map as a new wire order. |
| Optional work | Disable POL, hidden-mode feedback, dithering and IIR; explicitly record optical gain and PSD/telemetry configuration. |
| Transport | Same `wfsSimulator` input and explicit Classic rows per packet, row bytes and expected packets/frame; compare actual captures. HEART remains progressive; FGN/JFG are tested in complete-frame and row-block modes under CL-04's accepted scope. |

1. Reuse `plugins`' profile loader and
   `calculon-revolt-classic-direct-replay/src/bin/calculon-revolt-classic-direct-replay.rs:250`
   export path for converted calibration. It already exports background,
   coordinate pairs, reference slopes, pixel/flux thresholds, active mask,
   reconstructor, forward/reverse projections, controller scalars and limits.
   Retain original and converted hashes, shapes, ordering and selected indices;
   record the anti-windup overlay instead of editing the original profile silently.
2. Add a dedicated matched Classic HEART YAML/runner overlay. Make paths absolute
   or resolve against the calibration root; load the real CM; preserve padded
   dimensions; set explicit optional-path policy and runtime state. Do not reuse
   Copper's 64-row deferred branch or hardcoded packet-count qualification.
3. Instantiate the existing FGN Classic chain with those exported artifacts and
   the matched controller scalar. Use the maintained one-sample feedback host
   support; feedback carry must be included in the full-chain timing boundary.
4. Add a JFG Classic graph configuration using the existing complete-frame SHWFS
   and closed-loop correction/projection Algorithms plus `PreparedFeedbackBridge`.
   Replace Copper-specific dimensions/calibration publication in
   `benchmark/run_shared_copper_fits.jl`; preserve the actual graph host and device
   adapters. Use row-major exported matrices through the established JFG boundary
   conversion, not a flat Julia reshape that transposes the logical matrix.
5. Generalize the comparison orchestrator/decoder qualification to 352 rows,
   188 subapertures, 376 slopes, 221 controlled and 277 physical commands, corpus
   length seven, and the selected packetization. Keep failed attempts and require
   all scheduled frame IDs exactly once before computing conditional latency.

## Acceptance sequence and remaining evidence

First establish the complete chain's numerical boundary agreement, including
saturation and feedback, at the profile rate. Then require exact WFS packet/frame
coverage and exactly one DM command for every admitted frame, with no duplicate,
missing, reordered or replaced identity. A successful retry does not erase a failed
attempt. Startup frames remain part of delivery qualification even if a separately
reported warmed latency statistic excludes them.

For performance, record first-packet ingress → DM and final-packet ingress → DM
with the same timestamp source, endpoints, source pacing, readout duration,
affinity, buffer policy and instrumentation state. Record scheduled → observed
ingress delay separately to reveal source stalls. Report frame assembly and
processing overlap, representation sizes, feedback/adapter work, compiler flags
(including HEART's existing profiling instrumentation), and background telemetry.
Label each receiver and graph mode explicitly. The accepted comparison is
complete-frame and row-block FGN/JFG versus unchanged progressive HEART;
it must not be described as three native complete-frame execution paths.

Documentation checks found no missing local link targets or trailing whitespace,
and both review files retain final newlines. Calibration inspection was limited
to file hashes and sparse-entry structure; no scientific chain was executed.

This review establishes a source-supported candidate mathematical match. It
does not establish physical-loop equivalence, loss-free Classic delivery, exact
floating-point agreement, or measured Classic packet-to-DM latency. No build,
test, benchmark, source mutation, or calibration generation was performed.
