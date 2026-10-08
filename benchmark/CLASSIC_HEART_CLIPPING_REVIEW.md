# Classic HEART clipping precision review

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_HEART_CLIPPING_REVIEW.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

Date: 2026-09-30. Independent source inspection and offline captured-array
analysis. This review continues [the matched-chain review](CLASSIC_MATCHED_REVIEW.md)
and [the Float32 precision review](CLASSIC_PRECISION_REVIEW.md) under
[the active authority map](../docs/README.md). It establishes no timing,
physical-loop, or hardware qualification.

## Conclusion

The unchanged HEART 28-frame clipping replay **fails the existing 10⁻⁶ µm
comparison** at two unclipped physical command values, with maximum difference
1.3113021850585938 × 10⁻⁶ µm. The criterion remains unchanged.

Both failures are in extrapolated actuator rows, each combining 221 controlled
coordinates. The subsequent intermediate capture supports the selected
coefficient, clipping, and state conventions: an independent model starting
with the captured HEART gradients reproduces every reconstruction, controller,
and physical output value bit for bit. It uses single-rounding Float32
multiply-adds in reconstruction and control, and ordinary Float32 sequential
sparse extrapolation. This identifies matching arithmetic semantics for these
captured values; it does not identify the executable's machine instructions.

HEART's gradients already differ from the Rust fixture. The cause of that
upstream difference remains unlocalized. At each failed physical value,
projection rounding adds to the projected controller difference and takes the
total past the unchanged gate. The diagnostic run also exits with a shutdown
error and remains unqualified. Findings HC-05 and HC-06 record the new evidence;
HC-02 and HC-03 retain the earlier wire-only diagnostics as explicitly limited
investigative evidence.

## Provenance and evidence

The review document was created in
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`, branch
`copper-progressive-requal-20260929`, at revision
`2a8bf529061bfd9e103ad90acf001413d8135b29`. Existing modified benchmark runners
and tests, and untracked corpus, profile, and capacity-analysis files were
present. The initial review changed only this document. The subsequent
intermediate analysis adds
[`analyze_classic_heart_boundaries.py`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/analyze_classic_heart_boundaries.py) and
[`test_analyze_classic_heart_boundaries.py`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/test_analyze_classic_heart_boundaries.py);
it does not modify the runners or scientific implementations.

HEART source root is
`/home/dgamroth/workspaces/codex/heart/heart-copper-comparison`, reviewed revision
`6a5c06b11a8b934effeb6328a73a70895b2af94a`. The source references below are
relative to that root. Original calibrations are under
`/home/dgamroth/workspaces/codex/heart/revolt-rtc`.

| Evidence | Location under `/home/dgamroth/.cache` |
| --- | --- |
| HEART run | `rtc-classic-heart-progressive-clipping28-r1-20260930` |
| HEART diagnostic capture | `rtc-classic-heart-progressive-clipping28-boundaries-r1-20260930` |
| Common 28-frame Rust reference | `rtc-classic-clipping-corpus28-r2-20260930` |
| Original prepared arrays | `rtc-classic-matched-arrays-20260930/fixture` |

The HEART directory contains `dm-wire-um.f32`, `numerical-summary.json`,
`report.json`, packet captures, runtime configuration, and GMS readbacks.
The corpus contains `manifest.json`, `demanded_pdm_command.f32le`,
`vdm_command.f32le`, and `controller-constraint-feedback.f32le`.
The fixture supplies the Float32 reconstruction, slopes, extrapolation,
truncation, and scalar arrays. The manifest records individual hashes and the
28-frame input cube hash
`09f81afe6d7ea6c427f495c613dd8d4c2bcf07aa9881d7adbfdab6d86ea91c98`.

The common sequence is the original seven input frames repeated four times.
Reference outputs use the original seven-frame capture followed by the first
21 frames of the continued capture, without resetting state. The corpus
manifest reports 19 frames with nonzero controlled feedback. The run's existing
transport evidence reports 896 WFS packets and 28 DM commands with IDs 1–28;
this review did not independently re-decode the packet capture.

## Findings

### HC-01 — The command comparison fails at two extrapolated rows

Severity: high for acceptance reporting. Confidence: high. Disposition:
confirmed numerical failure; preserve the existing gate.

**Observed:** independent NumPy reads of the two physical-command arrays
reproduce these failures. Frame and actuator indices in this table are
zero-based array indices, not wire frame IDs.

| Frame | Physical actuator | HEART, µm | Rust, µm | HEART − Rust, µm |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 2 | −0.5260058641433716 | −0.5260048508644104 | −1.0132789611816406 × 10⁻⁶ |
| 19 | 3 | −0.678273618221283 | −0.678274929523468 | +1.3113021850585938 × 10⁻⁶ |

The fixture's selection matrix excludes physical actuators 2 and 3 from its
221 controlled coordinates. Both corresponding extrapolation rows contain
221 nonzero Float32 coefficients. Maximum error across the controlled physical
outputs is 8.344650268554688 × 10⁻⁷ µm. The existing numerical summary reports
168 values at a clipping limit in each capture, no clipping-decision
mismatches, and two failing values among 7,588 unclipped reference values.
The post-replay GMS reports 15 clipped actuators in the final frame, matching
the reference final frame.

**Derived:** these failures cannot be attributed solely to a direct comparison
of corresponding controller coordinates: both failing outputs include an
additional extrapolation reduction. Agreement on clipped values does not
reveal the preclip command or the amount fed back.

**Required validation:** capture preclip controller values and use the actual
extrapolation coefficients to distinguish propagated controller differences
from projection arithmetic. Matching clipping classifications alone is
insufficient to close this finding.

### HC-02 — Arithmetic differences are plausible but not independently localized

Severity: medium for attribution. Confidence: high for inspected source and
offline calculations; medium for the arithmetic hypothesis. Disposition:
initial wire-only attribution, subsequently narrowed by HC-05 and HC-06;
no production change justified.

**Observed source:** `source/blocks/src/hrtHoReconBlock.c:2545` selects streaming,
partitioned, or paired-column reconstruction paths. Its single-partition,
nonstreaming path calls `hrtVec_acc_ax_by`; the implementation in
`source/math/src/hrtVec_acc_ax_by.c` spells the update as
`S[i] += alpha * X[i] + beta * Y[i]`. HEART extrapolation calls the sparse
matrix routine from `source/blocks/src/hrtClwcBlock.c:1896`.
`source/math/src/hrtSparse.c:939` initializes each row to zero and accumulates
`r[row] += coefficient * input` in stored coefficient order. These spellings
do not establish compiler contraction, reassociation, or the actual active
reconstruction branch in this capture.

The controller source at `source/blocks/src/hrtClwcBlock.c:2289` integrates
gain-filtered error with pole 0.99. At `:2648` it subtracts pole times the
current clipping amount from the stored state. The runtime YAML selects
temporal gain −0.3, integration scalar 1, pole 0.99, no temporal IIR, and no
HO/LO POL correction. Recorded GMS flags enable clipping feedback and disable
the inspected additive disturbance, offset, dither, and uncontrolled-mode
feedback paths. These settings agree with the selected mathematical law in
the matched-chain review.

**Observed offline diagnostic:** starting at zero state, a NumPy calculation
used the fixture's seven Float32 slope vectors, compact reconstruction matrix,
and extrapolation matrix. It accumulated reconstruction column pairs in
increasing column order with ordinary separately rounded Float32 operations,
then used `u = p * (u − a * feedback) + g * residual`, with
`p = a = Float32(0.99)` and `g = Float32(−0.3)`. Feedback was regenerated as
`u − clamp(u, −0.8, +0.8)`. Projection accumulated the 221 compact columns
sequentially in Float32, followed by clipping.

This diagnostic's maximum physical-command difference from captured HEART is
8.344650268554688 × 10⁻⁷ µm, with only 679 of 7,756 command values bit-identical.
Its maximum difference from the captured Rust reference is
6.556510925292969 × 10⁻⁷ µm. Using captured Rust reconstruction outputs instead
of the diagnostic paired reconstruction, while retaining sequential
projection, gives maximum difference from HEART
1.0132789611816406 × 10⁻⁶ µm.

**Hypothesis:** reconstruction accumulation, accumulated controller rounding,
and extrapolation accumulation can explain the observed scale. The diagnostic
shows sensitivity to arithmetic order; it does not reproduce compiled HEART.
It assumes HEART's effective slopes equal the fixture slopes, substitutes
compact-column order for the original sparse storage traversal, and assumes
ordinary unfused arithmetic. None of those assumptions was independently
verified against captured HEART intermediate values or machine code.
The diagnostic result is not a replacement oracle or a passing result for
the original command comparison.

**Follow-up:** HC-05 and HC-06 complete the intermediate comparison and replay.
The original fixture-slope assumption in this section's diagnostic is false
for the measured HEART capture. The single-rounding model below uses HEART's
actual gradients. Do not change gains, precision, or the gate from either
diagnostic alone.

### HC-03 — Wire agreement supports the selected feedback convention but hides internal state

Severity: medium for coverage. Confidence: high for the counterfactual
calculations; limited to this fixture. Disposition: selected convention
supported by the wire-only counterfactual; internal recurrence subsequently
validated for the capture in HC-06.

**Observed offline counterfactual:** a separate NumPy replay used the captured
Rust reconstruction vectors repeated in their seven-frame period, zero initial
state, the ordinary Float32 controller recurrence above, and regenerated
feedback. It changed only the anti-windup coefficient and projected using
NumPy Float32 `E @ u`, then clipped. It does not run either compiled controller
or reproduce their projection kernel.

| Counterfactual anti-windup coefficient | Maximum physical difference from HEART, µm | Values above 10⁻⁶ |
| --- | ---: | ---: |
| Matched, Float32(0.99) | 1.0132789611816406 × 10⁻⁶ | 1 |
| 1 | 7.550716400146484 × 10⁻⁴ | 977 |
| 0, feedback disabled | 0.3354252278804779 | 1,007 |

All three calculations still differ from HEART's controlled clipped physical
outputs by at most 8.344650268554688 × 10⁻⁷ µm. Saturation conceals the altered
internal values at those controlled outputs; extrapolated physical outputs
expose them. The matched row differs from the original reference because this
diagnostic uses NumPy's projection reduction.

**Derived:** the full physical capture strongly disfavors these two obvious
feedback convention alternatives under the stated shared-input assumptions.
Controlled clipped-output agreement alone would not distinguish them.

**Follow-up:** HC-06 validates the captured preclip recurrence, including
saturated controlled coordinates. These counterfactuals and the earlier
Rust/JFG replay alone would not have established that result.

### HC-04 — Existing public buffer dumps can provide the discriminating evidence

Severity: informational. Confidence: high for source capability. Disposition:
experiment completed by the parent task; offline analysis recorded in HC-05.

**Observed source:** the maintained legacy `scaoTemplateCmdClient` exposes
`DUMP_BUFFER`, `-circularBufferName`, `-configDumpBufferInterval`, and
`-configDumpBufferFile`. `source/template/src/hrtTemplateCmds.c:516` dispatches
the command to `hrtTemplateCmds_dumpBuffer`, which supports `.fits` output and
calls `hrtCBFits_export` at `:2245`. Interval zero selects all retained history.
Although the CLI help says seconds, the implementation selects `last_n` for a
nonzero interval and passes it directly as the historical bucket count;
`source/util/src/hrtCircBuffer.c:2967` implements that interpretation.
The newer public `CB_DUMP` schema also exists in
`source/aoTypes/apiDef/hrtApi_CB_DUMP.yaml`; this review did not exercise either
command itself at runtime; the parent task subsequently performed the legacy
dump experiment described in HC-05.

After a bounded replay and before shutdown, with ingress stopped, use unique
output filenames and interval zero to dump:

| Existing buffer | Purpose |
| --- | --- |
| `cbHoVect0` | Reconstructed error before temporal gain |
| `cbDmErr0` | Gain-filtered controller input |
| `cbClUnclipped0` | Padded 277-coordinate pre-feedback integrator output |
| `cbDmCmd0` | Clipped physical command |
| `cbHoGrad0`, if needed | Subaperture validity, gradients, and flux |

The captured configuration gives these buffers capacity 1,000. At
`source/blocks/src/hrtClwcBlock.c:2373`, the unclipped buffer is written before
the clipping-feedback subtraction at `:2648`, making it useful for a direct
recurrence check. This is the controller vector before extrapolation, not a
capture of every physical preclip output.

`source/util/src/hrtCircBufferFits.c:984` exports oldest-to-newest bucket order.
It copies all selected buckets before beginning file output, but disk-write
errors can still leave a failed artifact. Require command completion success,
parseable FITS, expected dimensions, finite values, and established ordering.
Interval zero may include initialization buckets; do not discard extra buckets
without explaining their provenance. FITS records only the first bucket's
`TIMEUS` and `SYNC_CNT`, not every bucket's header. Do not assume those counters
equal WFS/DM wire IDs. The subaperture export writes four Float32 fields per
subaperture: state, x gradient, y gradient, and flux.

**Follow-up:** HC-05 and HC-06 establish the correspondence with all 28 wire
commands, zero padded uncontrolled entries, the selected recurrence, and the
original sparse projection. Packet-delivery and original numerical-gate
results remain attached to the capture. The dump occurs outside replay and
supplies numerical evidence, not a latency measurement.

### HC-05 — The diagnostic buffers align exactly, while the run still fails

Severity: high for run-status reporting. Confidence: high. Disposition:
usable numerical artifacts; failed run remains failed.

**Observed:** the diagnostic directory listed above contains five successful
`DUMP_BUFFER` commands, each with exit status zero. The analysis checks each
FITS SHA-256 against `report.json`, checks the expected primary-image type,
shape and extent, and rejects nonfinite values. All five pass. The four vector
images have FITS axes `(1, 277, 28)`, read as NumPy shape `(28, 277, 1)`.
The gradient image has axes `(4, 188, 28)`, read as `(28, 188, 4)`; its columns
are state, x gradient, y gradient and flux as specified by
`source/util/src/hrtCircBufferFits.c:1112`. All 5,264 subaperture states are 1.

All 7,756 `cbDmCmd0` values match `dm-wire-um.f32` bit for bit in stored order,
with no trimming or shifting. There are exactly 28 stored buckets in every
dump. The command, gradient, residual and gain-filtered-error first `SYNC_CNT`
values are 1; the unclipped-controller first `SYNC_CNT` is 0. The controller
and projection comparisons in HC-06 establish the corresponding sample order
despite those differing header counters. The FITS format retains only the
first counter, so this is value-based alignment, not independent inspection
of every intermediate bucket header.

The run reports 896 WFS packets and 28 DM commands. It repeats the same two
numerical failures and the same maximum difference as the earlier run.
`report.json` also records `scaoTemplate` exit status 1.
`scao.log` identifies `Error destroying loop monitor` and
`Socket not created/connected` during shutdown, with additional shutdown
worker errors retained in the log. The shutdown command client itself exits
zero; that does not override the process failure. No causal attribution of
this shutdown error to the dump commands is established. The earlier run
without dumps had normal child exits and still failed the numerical gate.

**Required validation:** keep the diagnostic run unqualified. A successful
artifact analysis does not repair the shutdown or numerical failures.

### HC-06 — A model from captured gradients reproduces the complete downstream trajectory

Severity: informational for state-law correctness; high for precision
acceptance. Confidence: high for the captured numerical equality; no claim
about emitted instructions. Disposition: downstream arithmetic localized;
sensor-stage attribution remains open, acceptance remains failed.

**Observed:** all 56 uncontrolled padded coordinates are zero in every
reconstructed-error, gain-filtered-error, and unclipped-controller frame.
The original sparse extrapolation file has 12,597 entries and SHA-256
`f78a2d1aec1fa0b800e6dba996f88c5c37d16704a5a8744b5fffd3f49acb3c92`.
Its selected columns are bit-identical to the compact Float32 fixture matrix;
its uncontrolled columns are zero, and its controlled output rows are the
identity. The analysis uses its actual stored coefficient order.

Let `RN32` mean ordinary binary32 rounding and `fmaf` mean one binary32
rounding of the exact product-plus-add operation. The analysis calls the
host `libm` function through Python `ctypes`; it neither compiles new C code
nor loads HEART's scientific implementation. For each of the 188 subapertures,
the following paired reconstruction reproduces all 6,188 captured controlled
residuals exactly:

```text
y_term = RN32(y_gradient × C_y)
pair = fmaf(x_gradient, C_x, y_term)
accumulator = RN32(accumulator + pair)
```

The accumulator starts at zero and visits the subapertures in their captured
order. The source's paired-column expression permits this arithmetic
organization. Separately rounding both products and the pair sum instead
differs at 2,916 residual values, by at most 2.9802322387695312 × 10⁻⁸ µm.
Both the captured gradients and residuals repeat with the exact seven-frame
period. Compared with the Rust fixture, HEART gradients differ at 8,104 of
10,528 slope values, by at most 3.5762786865234375 × 10⁻⁶ in slope units;
controlled residuals differ at 5,892 values, by at most
2.682209014892578 × 10⁻⁷ µm. Thus the prior assumption of identical HEART and
Rust slopes is not supported. The available gradient dump does not establish
which pixel calibration, moment, normalization, or rounding operation first
produces that difference.

Captured gain-filtered error is exactly `RN32(Float32(−0.3) × residual)`.
An independent controller starts with zero state, consumes those captured
errors, and regenerates its own clipping feedback without feeding captured
controller or feedback values into subsequent steps:

```text
uₙ = fmaf(Float32(0.99), stateₙ₋₁, errorₙ)
fₙ = uₙ − clamp(uₙ, Float32(−0.8), Float32(+0.8))  [controlled entries]
fₙ = 0                                         [uncontrolled entries]
stateₙ = fmaf(−Float32(0.99), fₙ, uₙ)
```

This matches all 7,756 captured padded controller values bit for bit. Ordinary
separately rounded multiplication and addition differs at 3,448 values, with
maximum 1.7881393432617188 × 10⁻⁷ µm. The feedback construction follows the
identity controlled extrapolation rows, physical clipping subtraction, and
selection described in `source/blocks/src/hrtClwcBlock.c:1755`, `:1783`,
`:2521`, and `:2648`. It therefore includes nonzero clipping feedback and its
proper temporal order, rather than merely fitting an unsaturated integrator.

Finally, Float32 sequential projection through the original sparse file,
followed by clipping, matches all 7,756 wire values. Replacing the model's
captured residual/error input with its independently reconstructed values
from the captured gradients preserves exact equality at every downstream
boundary. The entire replay from gradients onward starts from zero controller
state and uses no captured intermediate value as the next state.

**Derived:** no incorrect state reset, gain, clipping-feedback coefficient,
or feedback delay is needed to explain these captured values. The rounded
model establishes arithmetic conformance for this sequence. It does not
prove a particular compiler instruction sequence or general behavior for
other inputs; that would require separate evidence.

The physical failures can also be decomposed using Float64 projection of
each captured Float32 controller vector. Both failing outputs are unclipped.
In the following table all numbers are in units of 10⁻⁶ µm:

| Frame, actuator | E × controller difference | HEART projection rounding | Rust projection rounding | Total HEART − Rust |
| --- | ---: | ---: | ---: | ---: |
| 16, 2 | −0.4130985573 | −0.5442045407 | +0.0559758633 | −1.0132789612 |
| 19, 3 | +0.9109461430 | +0.2293643202 | −0.1709917219 | +1.3113021851 |

The total is column two plus column three minus column four. Float64
projection is a diagnostic of the stored Float32 coefficients and states,
not a new oracle or acceptance rule. Each projected controller difference
alone is below 10⁻⁶ µm; projection rounding takes the combined difference
above it. This is a numerical decomposition, not an attribution of the
controller difference exclusively to one upstream stage.

**Required validation:** preserve the failed command gate. If further
sensor-stage localization is needed, compare existing calibrated-pixel and
gradient intermediates against the shared fixture before considering any
scientific change. No new measurement is needed to establish the downstream
model equality reported here. Disassembly is necessary only for a claim
about actual compiler instruction selection, which this review does not make.

## Reproduce the intermediate analysis

The following command reads the existing capture and prints JSON. `--output`
can write the same report to a chosen analysis artifact; the reviewed result
is `boundary-analysis.json` in the diagnostic capture directory.

```sh
OPENBLAS_NUM_THREADS=1 python3 benchmark/analyze_classic_heart_boundaries.py \
  --capture /home/dgamroth/.cache/rtc-classic-heart-progressive-clipping28-boundaries-r1-20260930 \
  --fixture /home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/fixture \
  --corpus /home/dgamroth/.cache/rtc-classic-clipping-corpus28-r2-20260930 \
  --extrapolation /home/dgamroth/workspaces/codex/heart/revolt-rtc/config/dmExtrapolationMatrixTT.sparse
```

The script reports comparison failures as data, preserving
`run_qualified: false` and `wire_gate.qualified: false`; successful analysis
execution does not mean qualification. Seven focused tests validate FITS order and signed
zero preservation, malformed/nonfinite/scaled artifact rejection, and
`fmaf` cancellation and halfway-rounding behavior. Run them with:

```sh
python3 -m unittest discover -s benchmark -p test_analyze_classic_heart_boundaries.py
```

## Validation and limits

Performed: source/configuration inspection, independent reads and comparisons
of captured Float32 arrays, controlled/extrapolated row classification,
FITS hash/shape/finite/alignment checks, independent downstream arithmetic
replay, and seven passing analysis tests. No scientific implementation,
parameter, calibration, or acceptance criterion was changed.
The parent task performed the diagnostic live replay; this independent review
performed no live replay, software build, timing experiment, or hardware validation.
The earlier 1,031-frame Rust/JFG precision gate failure remains documented
separately and is not resolved by this 28-frame analysis.
