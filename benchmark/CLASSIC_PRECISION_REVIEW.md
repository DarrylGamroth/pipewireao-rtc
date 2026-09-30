# Classic Float32 precision review

Date: 2026-09-30. Independent source and captured-array review. This is numerical
characterization under [the active authority map](../docs/README.md), continuing
[the matched-chain review](CLASSIC_MATCHED_REVIEW.md). It does not qualify HEART,
transport delivery, timing, a physical loop, or row-block execution.

## Conclusion

The existing 10⁻⁶ native-micron comparison **fails**: JFG versus Rust controller
and clipped PDM commands differ by up to 1.2516975402832031 × 10⁻⁶. This review
does not change that acceptance criterion.

The captured controller difference is reproducible entirely from the differing
reconstruction outputs passed through the same Float32 recurrence. An independent
zero-state NumPy replay reproduces all 1,031 × 221 observed controller values,
bit for bit, for each implementation. It computes its own clipping feedback and
does not feed the captured controller or feedback values into subsequent steps.
There is no evidence here of an incorrect controller equation or feedback delay.
Reconstruction errors are compatible with ordinary Float32 accumulation error;
the exact BLAS kernel/reduction mechanism has not been independently identified.

## Provenance and scope

| Source | Revision / location |
| --- | --- |
| RTC review worktree | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`, branch `copper-progressive-requal-20260929`, `5f7e37e9dd5995d613da6858e096acb5162346f9` |
| JFG worktree | `/home/dgamroth/workspaces/codex/pipewire/JuliaFilterGraph-progressive-requal`, `254e578e5b227d33c500b350bdc3076c8bb49275` |
| Calculon algorithms worktree | `/home/dgamroth/workspaces/codex/pipewire/calculon-algorithms-progressive-requal`, `19c9a21cb5993e097914b49b07bbd45232073555` |
| Captured evidence | `/home/dgamroth/.cache/rtc-classic-matched-arrays-20260930` |
| Existing analysis | `analyze_jfg_classic.py`, `jfg-array-numerical-analysis.json` under that evidence directory |
| Reviewed capture | `jfg-array-compact`, with Rust outputs in `fixture` |

RTC already contained modified benchmark files and untracked progressive reports.
JFG contained a modified HEART runner and untracked Classic graph/replay files.
Calculon algorithms had no reported changes. This review changes only this file.
The recorded JFG graph hash is
`5f1c60239d082dbb47a7862ccbdacc2698da534f553682bac2272872318f1f83`;
prepared-profile hash is
`9058b87a73a7dda24c4839ca8a7def98d6dca4bba8cc8ac0e6cff1f8382877c4`.
The existing capture reports retain individual parameter hashes and Julia 1.12.7.

## Findings

### CP-01 — The controller difference is explained by upstream residual differences

Severity: informational for implementation correctness; high for acceptance
reporting. Confidence: high for the captured arrays. Disposition: confirmed
numerical difference; no controller remediation justified.

**Observed source:** JFG's
`julia/FilterGraphAlgorithms/src/algorithms/control/closed_loop_correction.jl:198–235`
and Rust's
`crates/calculon-algorithms/src/algorithms/control/closed_loop_correction.rs:308,399`
both compute the following operations with Float32 state and coefficients:

```text
sₙ = uₙ₋₁ − a fₙ₋₁
uₙ = p sₙ + g rₙ
g = Float32(−0.3), p = a = Float32(0.99)
```

The inspected source requests ordinary multiplications and additions. The
independent replay below also rounds after each ordinary Float32 operation.
Matching captures demonstrate these rounding semantics for this execution;
source spelling alone would not identify compiler contraction on every build.

**Observed validation:** the fixture's truncation T contains one unit entry per
row, and E at those selected physical rows is exactly the 221 × 221 identity.
The other controller/PDM mapping matrices were checked as identities by the
existing analysis. Therefore the feedback for each controlled coordinate is
exactly `u − clamp(u, lo, hi)`. Independent checks found:

| Check, 1,031 frames | Rust | JFG |
| --- | ---: | ---: |
| Controller bits unequal to independent Float32 trajectory | 0 | 0 |
| Controller bits unequal to local update using captured previous values | 0 | 0 |
| Maximum controlled clipped-command error against clamp(u) | 0 | 0 |
| Maximum feedback error against u − controlled clipped command | 0 | 0 |

The independent replay starts with zero controller/feedback, consumes each
implementation's own captured reconstruction output, and regenerates all state.
Thus upstream residual differences plus the shared rounded recurrence suffice
to reproduce the complete controlled trajectory difference. Missing feedback,
an extra state reset, or different anti-windup coefficients are unnecessary
explanations and inconsistent with these captured values.

**Derived:** in exact arithmetic each controlled coordinate is independent, with
update slope p when unsaturated and p(1 − a) when saturated. For these F32
coefficients those slopes are approximately 0.9900000095 and 0.00989999065.
The map is contractive, but unsaturated sustained residual errors can accumulate
with gain |g|/(1 − p) ≈ 30. Float32 state rounding adds a further per-step error.
Comparing a long trajectory with a one-step absolute threshold is consequently
a separate accuracy requirement, not an automatic consequence of correct code.
This derivation concerns replay of recorded input, not stability of a plant.

**Required validation:** retain this independent replay as evidence for the
current capture; repeat it for any new full-frame or row-block capture. Do not
alter controller gains, state precision, or feedback science to make this
comparison pass.

### CP-02 — Reconstruction error fits rounding bounds; exact reduction attribution remains open

Severity: medium, numerical attribution. Confidence: high for measured errors;
medium for attribution to a particular accumulation order. Disposition:
no demonstrated reconstruction defect; preserve the implementation and record
the active BLAS/compiler configuration if exact attribution is needed.

**Observed source:** JFG's dense reconstructor calls `mul!` in
`julia/FilterGraphAlgorithms/src/algorithms/wavefront_sensor/dense_reconstruction.jl:169`.
Rust's Float32 GEMV calls a per-row dot product in
`crates/calculon-algorithms/src/algorithms/linear_algebra/gemv.rs:58–62`;
the selected feature uses OxiBLAS `dot_f32`, with a scalar fold as its alternative.
The two sources do not prescribe the same reduction tree. This review did not
inspect the active machine-code kernels.

**Observed arrays:** all repeated JFG reconstructed-error frames equal their
seven-frame period. Existing repetition evidence records bit-exact calibrated
pixels and slopes across implementations. The independent comparison of those
seven residual vectors found:

| Quantity | Maximum absolute value |
| --- | ---: |
| JFG residual − Rust residual | 2.086162567138672 × 10⁻⁷ |
| Rust residual − Float64 C × slopes | 1.3599623316373766 × 10⁻⁷ |
| JFG residual − Float64 C × slopes | 9.985848142823883 × 10⁻⁸ |
| Residual difference at controlled coordinate 212 | 7.450580596923828 × 10⁻⁹ |

**Derived diagnostic bound:** with binary32 unit roundoff ε = 2⁻²⁴, a conventional
376-term dot product has forward-error bound
`γ₃₇₆ Σⱼ |Cᵢⱼ sⱼ|`, where `γ₃₇₆ = 376ε/(1 − 376ε)`.
For these inputs the bound ranges from 4.2108159222 × 10⁻⁶ to
1.3809612491 × 10⁻⁵. The maximum observed error divided by its corresponding
bound is 0.011855 for Rust and 0.008704 for JFG. The Float64 reference's own
roundoff is negligible at the reported F32 error scale. These conservative
bounds establish compatibility with ordinary rounding, not proof that an
arbitrary implementation satisfying such a loose bound is scientifically
acceptable.

**Required validation:** if exact kernel attribution is needed, record the
loaded BLAS, thread count, CPU dispatch and Rust features, then compare one
seven-frame reconstruction with its actual reduction or instruction sequence.
There is no need to rerun the full image graph to diagnose a dot product.

### CP-03 — The existing analysis is useful but does not by itself authorize a new tolerance

Severity: high, qualification claims. Confidence: high. Disposition: retain the
failed 10⁻⁶ result and distinguish arithmetic conformance from application accuracy.

**Observed:** the existing JSON reports 333 failing controller values across 280
frames; the first failure is total frame 363, controlled coordinate 212 / physical
actuator 256. The maximum difference is 1.2516975402832031 × 10⁻⁶ native microns.
The same values fail at the clipped physical boundary. Feedback remains within
10⁻⁶. Both implementations exceed 10⁻⁶ against the shared Float64 trajectory
(approximately 1.20 × 10⁻⁶ Rust and 1.09 × 10⁻⁶ JFG).

The comparison is an absolute/scaled-relative check with a scale floor of one;
all captured controller values have magnitude below 0.878, so it acts as an
absolute 10⁻⁶ test there. This is about 1.252 × 10⁻¹² metres at the largest
observed difference; no physical acceptability follows from that conversion.

The script correctly promotes the actual F32 coefficients to Float64 and keeps
the seven initial frames plus 1,024 continued frames in order. Its Rust preclip
physical vector is a Float64 projection of captured controller values, not a
captured Rust Float32 boundary. Its initial Rust feedback is synthesized as zero;
the independent replay confirms that assumption for the first seven frames.
The full and compact JFG capture equivalence is recorded separately in
`jfg-array-recording-verification.json`.

Clipping classification is inferred from equality of q to the limits. The
reference trajectory is at least 2.68737071245 × 10⁻⁵ from a limit and reports
154,858 clipped values with no disagreement, so no ambiguous equality case is
observed in this corpus. This is not coverage of behavior arbitrarily close to
limits. Pixel and flux thresholds likewise have large margins in all seven
frames; their agreement does not validate threshold-boundary cases generally.

**Recommended criterion:** retain exact fixture/order/shape/finite checks; assess
reconstruction separately against a declared high-precision reference and an
error budget derived from the actual reduction; require exact agreement with
an independent Float32 controller/clipping model for the captured residuals;
and separately assess complete physical-command accuracy against a predeclared
application budget. Continue reporting the original cross-implementation 10⁻⁶
gate as failed unless the comparison owner explicitly changes its meaning.
Do not select 1.3 × 10⁻⁶ or 2 × 10⁻⁶ merely because it clears this recording.

If the objective is arithmetic characterization, this evidence supports
“same equations, differences consistent with Float32 reconstruction and state
rounding” for the controlled capture. If 10⁻⁶ is an actual command-accuracy
requirement, neither implementation is established compliant by the present
Float64 comparison. A science or precision change then requires its own
engineering decision. Full physical-boundary attribution still benefits from
captured Rust preclip commands; HEART still requires independent capture and
the agreed full-frame-first, row-block-second comparison sequence.

## Reproduction of the decisive independent check

Run with `OPENBLAS_NUM_THREADS=1 python3` and the following script. It only reads
existing arrays and takes substantially less than one second on the review host;
no scientific graph, timed benchmark, or production implementation is changed.

```python
from pathlib import Path
import numpy as np

root = Path.home() / '.cache/rtc-classic-matched-arrays-20260930'
fixture = root / 'fixture'
jfg = root / 'jfg-array-compact'
count = 1031

def read(directory, name, width):
    return np.fromfile(directory / name, dtype='<f4').reshape(-1, width)

g, p, a, lo, hi = read(fixture, 'scalars.f32le', 5)[0]
T = read(fixture, 'full-to-active-vdm.f32le', 277)
indices = T.argmax(axis=1)
assert np.count_nonzero(T) == 221
assert np.all(T[np.arange(221), indices] == 1)
E = read(fixture, 'active-to-full-vdm.f32le', 221)
assert np.array_equal(E[indices], np.eye(221, dtype=np.float32))

rust_r = read(fixture, 'dm_error.f32le', 221)[np.arange(count) % 7]
rust_u = np.concatenate([
    read(fixture, 'vdm_command.f32le', 221),
    read(fixture, 'feedback-vdm-command.f32le', 221),
])

for name, residual, observed in (
    ('Rust', rust_r, rust_u),
    ('JFG', read(jfg, 'dm_error.f32le', 221),
     read(jfg, 'vdm_command.f32le', 221)),
):
    u = np.zeros(221, dtype=np.float32)
    feedback = np.zeros_like(u)
    predicted = np.empty_like(observed)
    for n in range(count):
        u = p * (u - a * feedback) + g * residual[n]
        feedback = u - np.clip(u, lo, hi)
        predicted[n] = u
    unequal = np.count_nonzero(
        predicted.view(np.uint32) != observed.view(np.uint32)
    )
    print(name, 'unequal controller values:', unequal)
    assert unequal == 0
```

Validation performed: source inspection; elementwise reconstruction of captured
updates; independent Float32 controller replay; seven-frame Float64 reconstruction
and forward-error calculation; documentation whitespace/newline/link checks.
No software build, live graph replay, timing experiment, or hardware validation
was performed by this review.
