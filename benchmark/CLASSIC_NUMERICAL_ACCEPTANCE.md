# Classic numerical acceptance

Tool provenance: the Python scripts and retired Julia launcher referenced here
were removed from the current checkout on 2026-10-08. Commands describe the
[recorded source revision](https://github.com/DarrylGamroth/pipewireao-rtc/blob/6b893b7e98e474580f53ff913751963b62f8db2a/benchmark/CLASSIC_NUMERICAL_ACCEPTANCE.md);
these commands are not runnable in this checkout. Results and design claims
retain their original scope. See the [current benchmark index](README.md) for retained tooling.

Date: 2026-09-30. Saved-array arithmetic evaluation under the
[active authority map](../docs/README.md). No HEART implementation, gain,
calibration, state precision, live harness threshold, or saved capture changed.

## Decision and permitted claim

The saved 28-frame HEART and 1,031-frame Rust/JFG sequences pass the arithmetic
conformance procedure below. Their original 10⁻⁶ µm cross-implementation gates
remain **failed**. Arithmetic conformance means that the captured outputs agree
with the selected equations and source-derived rounding models, or with
operation-count rounding bounds where the exact reduction tree is unspecified.
It does not establish an application command-accuracy budget or authorize the
phrase “scientifically equivalent” without that qualification.

The acceptance issue therefore has two explicit dispositions:

- **Resolved: arithmetic conformance and attribution for these saved sequences.**
  No algorithm change is justified by the observed differences. The executable
  accepts only when every exact model, reduction bound, propagated bound, and
  cross-implementation clipping-classification check passes.
- **Unassessed: application or physical accuracy.** No application error budget
  has been supplied. If the original 10⁻⁶ µm threshold is the actual application
  requirement, both historical comparisons remain noncompliant. This document
  does not replace that requirement with a larger empirical tolerance.

The HEART diagnostic process also failed shutdown. Its recorded run status stays
false even when numerical artifact analysis succeeds. Passing this procedure
never changes a run's transport, placement, timing, or lifecycle status.

## Provenance and evaluated data

Work started at RTC revision `94fd0162a03b8ab6213f88bbe28c8d7e3c360eac` on
`copper-progressive-requal-20260929` in
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-progressive-requal`.
Three unrelated untracked capacity/profile files were present and preserved.
This work adds only the evaluator, its tests, and this document.

The inputs are the complete stored sequences, without exclusions or time shifts:

| Data | Directory under `/home/dgamroth/.cache` |
| --- | --- |
| Seven original frames, Float32 coefficients, Rust initial seven and continued 1,024 outputs | `rtc-classic-matched-arrays-20260930/fixture` |
| JFG 1,031-frame arrays | `rtc-classic-matched-arrays-20260930/jfg-array-compact` |
| HEART 28-frame buffers and wire commands | `rtc-classic-heart-progressive-clipping28-boundaries-r1-20260930` |
| Matching 28-frame Rust reference | `rtc-classic-clipping-corpus28-r2-20260930` |

The evaluator checks array size and finiteness, Float32 coefficients, selection
identities, identity coordinate mappings, and HEART FITS hashes against its
capture report. It records SHA-256 for every consumed evidence file and for both
analysis scripts. These hashes identify this evaluation; except for the HEART
report comparisons they are provenance records, not checks against a separately
trusted hash registry. Calibration/capture provenance remains that of the
[matched review](CLASSIC_MATCHED_REVIEW.md),
[precision review](CLASSIC_PRECISION_REVIEW.md), and
[HEART boundary review](CLASSIC_HEART_CLIPPING_REVIEW.md).

The result is
`/home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/numerical-acceptance.json`,
SHA-256 `50b5f52bf515cc83a9148cea70d5f41f678c5cc1393578110082f67fa4044747`.
The evaluator SHA-256 for this result is
`b8781c9c530344b927f5860039cb1d210897de60eb3ef26e3b10467fca2a1913`.

## Sensor-stage cause and exact models

**Observed source:** HEART's `source/wfsProc/src/hrtWfsProcSH.c:109–229`
accumulates thresholded moments and flux in 16 lanes. For 484 subaperture
pixels it visits the first 480 in those lanes, accumulates the final four
pixels in scalar accumulators, then adds lanes 0 through 15 to those scalar
accumulators. `source/math/include/hrtVector.h:103` defines 16 lanes.
`source/wfsProc/src/hrtWfsProc.c:347` normalizes by multiplying each moment by
the rounded reciprocal flux for optical gain one. Reference gradients are
subtracted afterward. The Rust CoG source accumulates all 484 pixels in order
and divides each moment directly by flux before reference subtraction.
Both describe the same real-arithmetic moment/flux equation.

**Observed replay:** ordinary Float32 operations using those source orders
reproduce every captured HEART slope and flux from the shared calibrated pixels.
The Rust order reproduces every Rust slope, and those slopes equal JFG's.
The shared calibrated pixels themselves equal rounded `Float32(raw) − background`
bit for bit. The analysis uses the recorded 188 origins, 22 × 22 regions,
inclusive pixel thresholds, interleaved coordinates, and reference slopes.
All captured subapertures are active. Every fixture-based evaluator checks that
`active-subapertures.u8` contains exactly 188 bytes, all equal to one. Acceptance
reports record its hash. The analysis does not infer missing pixel dumps.

| Exact comparison | Values compared | Unequal bits |
| --- | ---: | ---: |
| Raw/background model → stored calibrated pixels | 867,328 | 0 |
| Scalar CoG → Rust seven-frame slopes | 2,632 | 0 |
| HEART lane/tail CoG → 28-frame captured slopes | 10,528 | 0 |
| HEART lane/tail flux → captured flux | 5,264 | 0 |
| Rust/JFG independent controller trajectories | 227,851 each | 0 |
| Rust/JFG regenerated clipping feedback | 227,851 each | 0 |
| HEART paired reconstruction | 6,188 | 0 |
| HEART padded controller trajectory | 7,756 | 0 |
| HEART complete downstream model → physical wire commands | 7,756 | 0 |

This extends the earlier downstream model to a common input-pixel boundary.
The earlier HEART review's unlocalized gradient cause is now explained by a
source-derived accumulation/normalization model on the recorded data. It does
not prove which machine instructions executed or rule out observationally
indistinguishable implementations.

The diagnostic search compared scalar versus 16-lane accumulation, fused versus
ordinary moment updates, and direct division versus reciprocal multiplication.
An initial model that assigned the final four pixels to lanes differed at 98
flux values; restoring the source's scalar-tail-before-lane-fold order reproduced
all fluxes and slopes. Model selection therefore follows the inspected source
and exact intermediate evidence, not a tolerance search. The focused test suite
contains a case that distinguishes these tail orders.

HEART source revision remains `6a5c06b11a8b934effeb6328a73a70895b2af94a`.
Inspected source SHA-256 values are:

| Source | SHA-256 |
| --- | --- |
| `source/wfsProc/src/hrtWfsProcSH.c` | `fb21715d9ec89bbfae510647fcd66ceee672bc9048de683362316797cef7808c` |
| `source/wfsProc/src/hrtWfsProc.c` | `b2d608b825a3d704a83f4ccc5684d06d49ce0ae133aadfb25fbd47bc41bb503f` |
| `source/math/include/hrtVector.h` | `c9b3e79f2d1e39cbf065dad179e122c65969f26f6d97e5bb1bad4635613fd38a` |

## Rounding bounds and propagation

The bound uses binary32 unit roundoff ε = 2⁻²⁴ and
γₖ = kε/(1 − kε). A reduction consuming n products once has at most 2n
rounding operations along any contribution's path. Expanding the product of
factors `(1 + δ)`, with |δ| ≤ ε, bounds forward error by
`γ₂ₙ Σ |aⱼxⱼ|`. This includes ordinary, tree, paired, and fused reductions;
it does not require matching a particular BLAS kernel. Here n = 376 for
reconstruction and n = 221 for compact physical projection. No coefficient was
chosen from the observed error maximum.

The binary64 reference multiplies stored binary32 values exactly and sums in
binary64. The evaluator adds its own conservative `γ₂ₙ(64) Σ |aⱼxⱼ|` error and
inflates computed nonnegative magnitudes before use. Tiny absolute terms cover
underflow rounding, and binary64 bound evaluations receive conservative
operation-count inflation. The calculation assumes round-to-nearest IEEE
arithmetic and reductions that neither omit nor duplicate terms. It is a
numerical bound evaluation, not a formal proof of the loaded binaries.

| Boundary | Largest observed error against own-input binary64 reference | Largest bound |
| --- | ---: | ---: |
| Rust reconstruction | 1.360 × 10⁻⁷ | 2.762 × 10⁻⁵ |
| JFG reconstruction | 9.986 × 10⁻⁸ | 2.762 × 10⁻⁵ |
| HEART reconstruction | 1.456 × 10⁻⁷ | 2.762 × 10⁻⁵ |
| Rust clipped physical projection | 4.141 × 10⁻⁷ | 4.439 × 10⁻⁵ |
| JFG clipped physical projection | 3.835 × 10⁻⁷ | 4.439 × 10⁻⁵ |
| HEART clipped physical projection | 8.009 × 10⁻⁷ | 3.446 × 10⁻⁵ |

These are conservative arithmetic envelopes. Satisfying them alone would be
weak evidence; acceptance additionally requires every exact source model above.
Clipping is nonexpansive, so the same projection bound applies after clipping.
No unavailable Rust preclip boundary is represented as a capture.

For the controller define the exact real map, using the recorded binary32
coefficients promoted without changing their values:

```text
f(u) = u − clamp(u, lo, hi)
H(u,r) = p [u − a f(u)] + g r
p = a = Float32(0.99), g = Float32(−0.3)
```

For 0 ≤ a ≤ 1 the derivative with respect to u is p inside the limits and
p(1 − a) outside, hence the global Lipschitz constant is p. The two recorded
arithmetic organizations have different local rounding errors but share H.
Each ordinary or fused operation's error is bounded by
`η |rounded_result| + tiny`, with η = ε/(1 − ε). The evaluator propagates
these errors through that implementation's actual multiplications, additions,
feedback subtraction, and fused operations to obtain a per-step bound ρₙ.
The independent model regenerates state and feedback from zero; it never feeds
a captured controller value back into its own next step.

For two trajectories, the executable evaluates:

```text
D₀ = 0
Dₙ ≤ p Dₙ₋₁ + |g| |rᴬₙ − rᴮₙ| + ρᴬₙ + ρᴮₙ
physical_difference_boundₙ = |E| Dₙ + projection_roundingᴬₙ + projection_roundingᴮₙ
```

Residual differences here are exact binary64 differences of the captured
binary32 residuals. This is conditional propagation for those measured inputs;
the preceding reduction checks independently constrain each residual. It is not
a worst-case sensor-to-plant accuracy bound for arbitrary future images.
The envelope applies across clipping transitions without assuming identical
clipping branches. Both captures also have zero observed disagreements in
physical clipping classifications.

| Pair | Largest controlled difference / bound | Largest physical difference / bound |
| --- | ---: | ---: |
| JFG versus Rust, 1,031 frames | 1.252 × 10⁻⁶ / 3.449 × 10⁻⁵ | 1.252 × 10⁻⁶ / 1.507 × 10⁻⁴ |
| HEART versus Rust, 28 frames | 8.941 × 10⁻⁷ / 6.081 × 10⁻⁶ | 1.311 × 10⁻⁶ / 7.625 × 10⁻⁵ |

Maxima in each column need not occur at the same sample. Every sample passes
its own bound; reporting only maxima would not establish that fact. The report
also records the largest samplewise error/bound ratio. The wide envelopes are
not proposed application tolerances.

## Preserved failures and limits

The historical criterion remains `abs ≤ 10⁻⁶ OR abs/max(|actual|,|expected|,1) ≤ 10⁻⁶`.
The long JFG/Rust controller and clipped physical comparisons each fail at
333 values, maximum 1.2516975402832031 × 10⁻⁶ µm. HEART's physical comparison
fails at two values, maximum 1.3113021850585938 × 10⁻⁶ µm. The independent
HEART review retains their projection-versus-controller decomposition.

This evidence covers a repeating seven-image workload and the selected initial
state, masks, thresholds, coordinates, mappings, and scalar coefficients.
Threshold-near cases, altered gains, state resets, other calibrations, arbitrary
BLAS behavior, row-block long captures, and physical-loop accuracy require their
own evidence. The exact Rust/JFG reduction trees remain unidentified; their
errors meet the declared arithmetic reduction envelope. The source-derived
HEART pixel model is observationally exact but is not an independently captured
HEART calibrated-pixel boundary.

The consequential assumption for integration is that arithmetic conformance is
the intended development comparison claim. If application command accuracy is
intended instead, that decision affects the remaining-gate disposition and
requires a supplied application budget; no code or tolerance should be changed
merely to clear this recording.

## Acceptance of subsequent wire captures

`acceptance_for_wire(fixture, expected, actual, frames, role, mode)` accepts
Float32 file paths or arrays with shape `(frames, 277)`. Its preconditions are
the unchanged fixture, zero initial controller state, and repetition of the
original seven source images beginning at frame zero. It returns the original
strict comparison, hashes, per-frame arithmetic-bound summaries, and explicit
clipping/threshold margins. Role and mode identify the evidence; they do not
select an empirical tolerance.

The function derives a common binary64 CoG reference from the pixels. If F and
M are the reference flux and moment, it bounds their reduction errors with
`B_F = γ₄₈₄ Σ |pixel|` and `B_M = γ₉₆₈ Σ |pixel × coordinate|`. It rejects a
flux validity decision if `F − B_F` reaches the threshold or zero. With
`q = M/F`, the quotient error before final normalization roundings is bounded
by `(B_M + |q| B_F)/(F − B_F)`. A further γ₃ term covers reciprocal
multiplication or direct division and reference subtraction. Binary64 reference
errors and evaluation inflation are included separately. Pixel selection uses
the verified rounded calibration and the shared inclusive threshold exactly;
the function reports distance from those pixels to the threshold.

The resulting slope radius is propagated through `|C|` and a γ₇₅₂ reduction
bound. Starting from zero, a controller error radius D uses the contractive
factor p plus residual radius and a γ₈ bound for its expanded arithmetic terms.
Eight exceeds the number of roundings along any source controller contribution
for either the ordinary or fused organization. The physical radius combines
`|E|D` and a γ₄₄₂ reduction bound; clipping remains nonexpansive. Both expected
and actual commands must satisfy their own reference intervals and the command
limits; their difference must satisfy the sum of the two radii.

This broad function reports **arithmetic consistency**, a weaker result than
exact model replay. Its envelope is deliberately conservative: the largest
single-implementation physical radius is 0.0019701 µm for 28 frames and
0.0079695 µm for 1,029 frames. Those values follow from the operation counts and
input data; they are not application tolerances. Such a bound alone can hide
small algorithm defects. It cannot identify feedback state or justify claims
about a branch when its interval straddles a clipping limit. The result records
both interval ambiguity and observed cross-implementation clipping disagreement.

For role `heart`, the function additionally calls `heart_wire_model(fixture,
frames)` and returns an independent `exact_model_passed` flag. This computes
the source-derived 16-lane/tail CoG for the seven images, paired fused
reconstruction, the full zero-state fused controller sequence, and ordinary
sequential sparse extrapolation. The reviewed original sparse entries are
ordered by physical row and then physical column; sorting the compact fixture's
selection indices reconstructs that exact traversal. This ordering was checked
against the original 12,597-entry sparse file. The model therefore needs no
internal live dumps for subsequent unchanged HEART runs. Other roles return
null for this exact-model flag; their unspecified dense reduction trees are
not represented as bit-exact oracles.

**Observed additional capture:** the parent task's
`/home/dgamroth/.cache/rtc-classic-heart-pilot1029-20260930/heart-100hz-r1/dm-wire-um.f32`
contains 1,029 frames. Every one of its **285,033 physical command values matches
the independent HEART model bit for bit**. The same model reproduces all 7,756
values in the earlier 28-frame capture. It follows every clipping and feedback
update in its own state without consuming captured outputs. This supports the
selected arithmetic law for the long capture even though the broad interval
method marks 21,620 clipping decisions ambiguous. It does not establish hidden
state uniqueness from physical outputs.

Against the stored Rust continuation, this new capture still fails the original
strict gate at 17,149 values, maximum 2.682209014892578 × 10⁻⁶ µm. Its independent
run shutdown failure remains a separate failed lifecycle result. No live run
was performed by this analysis worker. The new analysis result is
`/home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/wire-numerical-acceptance.json`,
SHA-256 `cc923c9d8dba697a0b03f3892f2d8316bf1efe2f7b06972131e8ae7ee7a66e05`.
It includes the exact-model result and canonical Float32 command hashes.

## Reproduction and verification

Run offline with NumPy and the existing host libm `fmaf`:

```sh
OPENBLAS_NUM_THREADS=1 python3 benchmark/classic_numerical_acceptance.py \
  --evidence /home/dgamroth/.cache/rtc-classic-matched-arrays-20260930 \
  --heart-capture /home/dgamroth/.cache/rtc-classic-heart-progressive-clipping28-boundaries-r1-20260930 \
  --corpus /home/dgamroth/.cache/rtc-classic-clipping-corpus28-r2-20260930 \
  --extrapolation /home/dgamroth/workspaces/codex/heart/revolt-rtc/config/dmExtrapolationMatrixTT.sparse \
  --output /home/dgamroth/.cache/rtc-classic-matched-arrays-20260930/numerical-acceptance.json
OPENBLAS_NUM_THREADS=1 python3 -m unittest discover -s benchmark \
  -p test_classic_numerical_acceptance.py
```

The evaluator exits zero only for arithmetic conformance. Its JSON separately
reports original gate failures and failed HEART run status. Nine focused tests
pass, covering cancellation, independent operation-count bounds, original
threshold preservation, invalid bounds, HEART tail order, controller saturation,
error propagation, coefficient assumptions, wire-command corruption,
flux-threshold ambiguity, and invalid active-mask rejection. A synthetic one-ULP
HEART wire corruption is rejected by the exact model. An additional in-memory one-ULP
corruption of one saved JFG controller value made arithmetic conformance fail
with exactly one controller mismatch; the evidence files were not modified.
The unchanged saved data passes. No live replay, benchmark, production build,
hardware experiment, or scientific parameter change was performed here.
