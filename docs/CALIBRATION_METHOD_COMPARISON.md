# Classic calibration method comparison review

## Scope and disposition

Independent architecture review,2026-10-03, RTC quality worktree at
`d99a24d03364a05389384fc72647e814376d4fd8`. The initial sections propose the comparison;
MCR-6 and later sections record subsequent pilot and software-review evidence.
Only this review document was written by its independent reviewer. No RTC launch, instrument action, production
change, gain/threshold change, HEART edit or external algorithm reuse occurred.
The parent-owned [analysis plan](ANALYSIS_PLAN.md) remains the work plan.

**Disposition:** proceed with a selectable probe/estimator seam and a small
balanced dense-pattern amplitude pilot. Full Hadamard comparison follows that
pilot. Partial spatial/modal products require explicit coordinate and span
claims. A software-complete estimator alone cannot establish comparable science.

The existing baseline uses two independent277-coordinate zonal sweeps at
±0.04 µm OPD,N64. Its selected operator is368×221; the chosen TSVD retains186
modes. The current cached locked-test report has `forward_pass=true` and the
single frozen candidate has `passed=true`. This reviewer inspected those
fields, not a new correction run. Later fresh FGN/JFG correction results are recorded separately in
[quality validation](CALIBRATION_QUALITY_VALIDATION.md). Historical failed JFG
ADC replay reports remain unaccepted; their cause is still open.

## MCR-1 — Public API and coordinate ownership

**Confidence:** high; source-confirmed interface. **Disposition:** approved
with explicit directional-product semantics.

Current public AOC APIs provide `ProbeBases.ZonalPushPull`,
`HadamardPushPull`, `ModalPushPull` and `SpatialSinusoidalPushPull`.
`InteractionMatrices` has zonal and Hadamard complete-cycle estimators.
Probe command arrays have patterns in rows and physical coordinates in columns;
interaction products have measurements in rows and estimated coordinates in
columns. All families can use the existing demanded/adopted/settled acquisition
protocol, chronological result validation, finite completion and restoration.

For L supplied modes, let M have shape277×L and amplitude aⱼ have units µm OPD.
The requested physical deltas are qⱼ=aⱼ M[:,j]. Passing interleaved modal
responses to public `InteractionMatrices.ZonalPushPull(a)` is mathematically
appropriate for estimating each modal coordinate's signed derivative:

```text
G[:,j] = (mean_response(+qⱼ) − mean_response(−qⱼ)) / (2aⱼ)
G has shape376×L and units pixel per µm OPD of the declared mode coordinate.
```

The public estimator does not know the physical mode geometry. The client must
retain the mode matrix, amplitude units, actual physical figures and column
ordering with the product. At finite amplitude, G is a measured directional
secant. `G≈D M` is a local-linear model requiring experimental assessment;
it is not an exact identity for a nonlinear WFS.

The minimal client extension prepares a public probe plan plus its public
estimator and explicit coordinate metadata. Normal result validation remains
chronological; only afterward is the inverse permutation applied for canonical
positive/negative estimation. Preserve typed AOC numerical status checks and
artifact publication only after complete valid estimation. No callback math,
new RTC scientific estimator, hidden simulator derivative or native protocol
extension is necessary. The existing physical-zonal API remains meaningful;
a generic modal product must not silently reuse its physical-column label.

## MCR-2 — Exact command representation and amplitude

**Confidence:** high; derived from wire representation and estimator equations.
**Disposition:** required before comparing estimates.

Freeze the zero/reference command, detector settings, measured background,
reference slopes, selected mask, illumination, exposure, maps, clipping policy
and controller coefficients. Keep normal noisy ADC acquisition. Every complete
figure must be finite Float32, adopted unchanged and unclipped. Retain exact
wire arrays and source hashes; rejection cannot become a silently rescaled probe.

For modal/spatial probes, define the operational matrix explicitly from rounded
commands: `M_actual[:,j]=Float64(q_wire[:,j])/Float64(a_wire[j])` at zero
reference. Record its difference from the intended sampled matrix. With a
nonzero reference, demand exactly preserved positive/negative deltas about
that reference; asymmetric rounded deltas are not centered push/pull. A scalar
amplitude correction cannot repair element-dependent rounding silently.

For spatial patterns the public simulator geometry interface
`REVOLTClassicSim.actuator_coordinates()` returns2×277 coordinates in exact
physical command order. AOC expects277×2, so transpose once. Record normalized
pupil coordinate units, axis orientation, supplied cycles per coordinate unit,
frequency order, sine/cosine order and normalization. AOC centers or masks
nothing implicitly. These are public authoring coordinates, not optical truth
used to estimate a response. No pupil-weighted energy or influence weighting
may be inferred from the coordinate samples alone.

Use explicit peak normalization when making a peak-limited comparison. Record
per-pattern maximum absolute command, command Euclidean norm, RMS over all277
physical elements and total integrated squared command across acquired frames.
Also record zero/near-null sampled modes, actual matrix singular values,
conditioning and chosen numerical rank tolerance. The spatial API's sampled
peak guard does not establish independence. Include no DC frequency in its
sine/cosine-pair constructor; supply a separate declared modal pattern if needed.

## MCR-3 — Representation limits and common predictions

**Confidence:** high; linear-algebra contract. **Disposition:** required claim
boundary, with no full-rank requirement imposed on exploratory modes.

Use the unchanged physical map `B=P E C` and selected measurement map S. The
baseline predicts `S Dbar q_actual`. A modal estimate predicts `S G α` for a
physical command represented by `q_actual≈M_actual α`. Freeze any numerical
solve tolerance and report the actual representation residual separately from
measured prediction error. Float32 rounding may move a nominally representable
held-out command slightly out of the declared span; report that residual.

A partial modal estimate is not a full277-coordinate matrix. Writing
`G pinv(M)` gives one extension that assigns unmeasured behavior outside the
span; it cannot be reported as measured full D. Full physical recovery requires
full row rank of M, a documented right inverse and its noise/conditioning cost.
Controller comparison can be less demanding: if `M L≈B` is verified with a
recorded residual, form `A_modal=S G L` without claiming full physical recovery.
If that representation fails, compare only common physical commands in the
intersection of the tested spans. Do not score an unrestricted221-dimensional
held-out corpus and attribute omitted-span error entirely to estimator noise.

Arbitrary physical sinusoidal modes need not lie in range(B). Feedback selection
T is not a physical inverse of E: `T E=I` does not imply `E T=I`. Consequently,
`T M` alone cannot certify controller-realizable versions of those modes.
Projection through the controller map changes the patterns and must be declared.

For the bounded spatial demonstration, declare32 non-aliased nonzero
frequency vectors before observing responses, yielding64 modes. Check the
actual sampled rank/condition before acquisition. Compare their measured G
against baseline directional predictions Dbar M and against newly acquired
held-out combinations inside that same span. This assesses spatial modal
calibration only; it does not challenge the full-controller zonal baseline on
an unequal representation task.

### Explicit controller-modal comparator

Use the existing B=P E C itself as a declared physical basis for the221
controller coordinates. For each column define `pⱼ=max(abs,B[:,j])`; reject a
zero or nonfinite column. Prepare public `ModalPushPull` positive rows
`qⱼ=Float32.(0.04 B[:,j]/pⱼ)` and record the exact wire-derived normalized
matrix M_actual. The public directional estimator returns G of shape376×221.
With `L=diag(p)`, the intended relation is `M L=B` and hence `A=S G L`.
Compute and retain the actual residual `M_actual L−B`; use actual figures for
held-out prediction and do not silently drop that rounding term.

This requires221 positive/negative pairs,442 signed batches. It calibrates the
complete declared controller task if the map/representation checks pass. It
makes no claim to recover the missing physical-coordinate directions. These
modes are not generally orthogonal, so their conditioning and unequal physical
energies remain explicit. Choosing this task-aligned representation can reduce
cost independently of any noise advantage. The original full277 zonal estimate
remains the comparator after composing through the same B.

## MCR-4 — Exposure cost, energy and nonlinear bias

**Confidence:** high for counts/equations; detector-noise predictions conditional.
**Disposition:** required accounting and pilot before dense full sweeps.

For277 physical coordinates, the existing balanced non-DC Sylvester-Hadamard
implementation uses order512:512 positive patterns and512 negatives. Its
columns are orthogonal on the full512-pattern cycle. Zonal uses554 signed
batches. Never truncate Hadamard rows and then apply its full-cycle decoder.

At the same per-coordinate peak0.04, each Hadamard pattern has277 times the
squared command norm of one zonal pattern. A spatial peak-normalized pattern
has its own geometry-dependent norm. Increased multiplex signal is allowed
under a peak-only constraint, but must not be presented as a gain at equal
probe energy. Optical wavefront energy is not identical to command-vector
energy; no unmeasured influence-function weighting is implied here.

Under independent identical additive response noise with variance σ² per
measurement per exposure, ideal linear decoding gives zonal coefficient
variance `σ²/(2 N a²)` and Hadamard variance `σ²/(2·512·N·a²)`. These formulas
expose the multiplex advantage under that model, not a qualification result.
Actual WFS photon statistics, thresholding, spot motion and nonlinearity can
change with dense patterns. The single-actuator0.02/0.04 agreement does not
validate a277-actuator dense0.04 pattern.

Before a full Hadamard sweep, acquire a deterministic small pilot: four declared
Hadamard patterns spanning the prescribed row order, four declared
controller-modal columns and four declared spatial patterns, each at0.02 and
0.04 physical peak, one ABBA/BAAB quartet per condition,
N16 per signed batch, and two reference batches per condition. This is144 total
batches,2304 accepted frames and2449 model exposures with one discarded settle
exposure per batch plus one restoration exposure. Choose patterns before
responses; this is a screen, not proof for all512 Hadamard patterns or all controller/spatial modes.

Compare normalized signed responses across amplitudes, duplicate-pair/order
variation, reference drift and even response. Report coherent differences
rather than hiding them inside total-vector noise. Unresolved differences call
for a bounded increase of repeat precision on those pilot conditions. Detected
amplitude dependence forbids a claim of a common infinitesimal D; it can still
support explicitly finite-pattern prediction characterization. Do not change
thresholds, illumination or amplitude silently to obtain apparent superiority.

## Practical comparison sequence

1. Verify the selectable client on synthetic linear responses through public
   AOC algorithms: exact basis/order, chronological reversal, modal-column
   interpretation, actual rounded figures, rank-deficient span handling,
   numerical failure and restored/released completion. These tests are a future
   implementation gate; none were run for this design-only review.
2. Run the bounded dense-pattern pilot above, with frozen source/settings and
   measured offsets. Stop before a costly full comparison if interpretation
   remains ambiguous. The provisional choice N16 is an economical pilot
   precision, not an instrument noise threshold.
3. If justified, start two independent Hadamard sweeps at N8 and opposite
   chronological/sign order. Compare with fresh two-sweep zonal N16 data under
   the same settings. Add two controller-modal N16 sweeps for the same
   controller task, explicitly reporting their lower exposure count. Retain
   the existing N64 zonal estimate as a noisy reference, not ground truth. Seeds and order are declared before acquisition.

| Method, one sweep | Signed batches | Accepted frames | With one settle/batch and final restore |
| --- | ---: | ---: | ---: |
| Controller-modal,N8 | 442 | 3536 | 3979 |
| Controller-modal,N16 | 442 | 7072 | 7515 |
| Zonal,N8 | 554 | 4432 | 4987 |
| Zonal,N16 | 554 | 8864 | 9419 |
| Hadamard,N8 | 1024 | 8192 | 9217 |
| Hadamard,N16 | 1024 | 16384 | 17409 |

Counts exclude extra reference batches; record them and their full costs if
added. HadamardN8 versus zonalN16 is a near-equal acquisition-budget comparison,
not exact equality. Report accepted frames, settling/restoration, startup,
acquisition and numerical-processing time separately. If exact equal-exposure
comparison is later required, predeclare complete cycles and extra replicates;
do not discard selected inconvenient rows after seeing results. The two
independent sweeps remain distinct replicates, not one pooled confidence bound.

4. Use common fresh physical validation directions for full-span methods. Report
   forward error versus zero, repeat disagreement, amplitude-stratified error,
   and command reconstruction loss using the actual packed candidates. Existing
   baseline held-out data may serve as a frozen comparative reference, but once
   used to tune a new method it cannot remain that method's final locked test.
   Freeze the inverse candidate grid, validation rule and fresh independent
   locked set before method selection; preserve the original baseline result.
5. Assess the controller-modal comparator on the full verified controller span
   and the bounded64-mode spatial branch on its declared common span. The
   spatial branch's lower exposure count purchases a smaller representation.
   Report that trade-off alongside precision; do not rank it as a cheaper equivalent
   full277 estimator. Any claim that the64 spatial modes cover the complete
   controller span requires a separate representation proof; rank alone cannot
   make64 modes span221 independent controller coordinates.
6. Only after equal-budget results, consider equal-accuracy cost curves with
   additional prespecified N values. “Equal accuracy” needs an explicit common
   metric and comparison margin agreed before follow-up outcomes. No supplied
   instrument threshold means this remains relative characterization unless a
   simulation-specific criterion is adjudicated. Do not infer a universal
   winner from one N, seed pair, amplitude or partial span.

No method-selection result promotes actuator rank, atmospheric closed-loop
stability, physical-device authority, wall-clock cadence or the unresolved JFG
input-parity gate. Those require their own retained evidence.

## MCR-5 — Selectable client implementation verification

**Disposition:** no blocking defect found in the reviewed client increment.
**Confidence:** high for inspected equations, serialization contract and focused
ordinary-array behavior; deployed method workflow remains unverified.

Reviewed files and SHA-256:

| File | SHA-256 |
| --- | --- |
| `deployment/hil/calibration_client.jl` | `0625169579554d9afcf52ed04b29ba0110d484a9b11c6a51289c7c8adde20174` |
| `deployment/hil/test_calibration_client.jl` | `9efab76b50d21b353bcdb88dcac5ab602b26b86029edd0bcb4500678dc9479ac` |

The implementation delegates basis generation and estimation to public AOC.
Explicit zonal and Hadamard products are tagged `physical_actuator`; modal
and spatial products are tagged `mode_direction`. Their positive physical
command rows are copied Float32 arrays. Modal estimation uses the declared
positive mode amplitude for each signed pair, so its columns estimate the
finite directional secants defined earlier. The spatial constructor retains
planned geometry/basis diagnostics while actual Float32 commands define the
operational directions. No rank or full-physical-matrix recovery is performed.
The descriptive expression `D * direction` must retain the finite-amplitude
local-linear interpretation stated in this review.

Hadamard generation and decoding use the same AOC non-DC Sylvester convention;
the estimator checks complete-cycle response extent. Physical amplitudes remain
per actuator, not per Hadamard pattern. Modal amplitudes instead remain per
mode. Reference addition checks exact preservation of every positive and
negative Float32 delta, rejecting a lost/asymmetric delta before publication.
AOC nonfinite product status is checked before returning an estimated matrix.

New command-basis metadata supplies shape and `column_major` for JSON3's flat
matrix encoding. The modal artifact test verifies the serialized array equals
the flattened actual Float32 positive-command matrix and records its shape.
Spatial planned-basis metadata separately supplies shape/layout; it must not be
substituted for the deployed rounded matrix. Input JSON matrices are explicitly
nested rows. This does not establish a roundtrip authoring format for an entire
output artifact. Actual coordinate-unit declarations and source identities
remain the future workflow's responsibility.

Omitting `probe_basis` preserves the previous prepared tuple, CLI-plan keys
and artifact keys; focused tests explicitly check them. `validate_result`
continues to check chronological exposure association. Estimation assumes the
canonical interleaved basis order. A future reversal workflow must validate the
chronological result before applying its inverse permutation; this increment
adds no automatic permutation or deployed selectable-method orchestration.

### Independent requested verification

Executed from the RTC quality worktree:

```text
taskset -c 5 env JULIA_DEPOT_PATH=/tmp/pipewireao-ndarray-exchange-depot:/home/dgamroth/.julia OPENBLAS_NUM_THREADS=1 julia --startup-file=no --threads=1,0 --check-bounds=yes --depwarn=error --project=/home/dgamroth/.cache/rtc-calibration-quality-20261003/selected-v2-n16/base/hil deployment/hil/test_calibration_client.jl
```

Result: exit0;105/105 assertions across six test sets. Retained log:
`~/.cache/rtc-calibration-quality-20261003/client-bases/independent-bounds-depwarn.log`,
SHA-256 `42aea6d1bf226625f870136d12a0cca58de48f53dfd67f16256cbe767b409a65`.
The selected installed environment's Manifest retained SHA-256
`164567605cac267ae885faff76497da4b6e86300b71cc87ff47adb75568057c7`.
Julia precompiled dependencies and printed a notice that ten dependencies had
different stdlib versions already loaded, with possible additional recompilation.
No deprecation error or failed assertion occurred. This is successful focused
software verification, not a warning-free startup or performance measurement.

No production source was edited by the reviewer. No RTC acquisition, dense
pilot, complete method campaign, controller activation or new physical/rate
qualification follows from these tests alone.

## MCR-6 — Actual dense-pattern pilot review

**Disposition:** pilot calculations and receipt association verified; full dense
method superiority remains unaccepted. Confirm amplitude/order behavior before
costly full dense acquisition. **Confidence:** high for the recorded numerical
observations; intrinsic nonlinearity remains an interpretation to distinguish
from order/history effects.

Reviewed cache: `~/.cache/rtc-calibration-quality-20261003/dense-method-pilot`.
The report `analysis.json` has SHA-256
`4ba8ac1713a3c2428df3ac89bf044fd59a5eb65724f04f603219a3240fccf9bf`.
The reviewed analyzer is `analyze-dense-pilot.jl`, SHA-256
`1551bb85c324840d9f0f5f593599c55e37487afe056c96740710e23da03c44dd`.
An independent NumPy recomputation used the preserved result JSON, labels,
policy, exact Float32 plan figures, selected mask and packed baseline D.
No Julia analyzer output was used as an intermediate numerical input.

### Observed and independently checked

- All144 batches contain16 valid exposures:2304 unique chronological
  `(domain,generation,sequence)` identities, from `(1,1,2)` through
  `(1,1,2448)`. Domains/generation are unchanged, durations are1,896,000ns,
  and model-time intervals are ordered and nonoverlapping. All completion,
  restoration, release and shutdown flags pass; launcher exit is0.
- Every report source hash and baseline-D hash matches. The packaged selected
  mask equals the frozen campaign mask. Each condition has exactly zero
  before/after reference figures and a correctly labeled ABBA/BAAB quartet.
  Every signed plan figure equals the declared amplitude-scaled Float32
  direction. Attribution to unchanged adopted figures additionally relies on
  the previously reviewed strict Rust coordinator contract; result JSON does
  not separately serialize every adoption acknowledgement.
- Every condition statistic and amplitude contrast recomputes within
  1.14×10⁻¹³ absolute numerical difference. The normalized actual wire
  direction is exactly identical at0.02 and0.04 for these power-of-two scaled
  patterns; Float32 direction rounding does not create their difference.
- Bracketing-reference interpolation uses actual batch exposure midpoints.
  Symmetric quartet timing cancels its linear-reference contribution to the
  mean signed derivative: removing that correction changes the mean derivative
  by at most7.7×10⁻¹⁵ in Euclidean norm. It still affects individual pair/order
  diagnostics and the even residual; those use the documented correction.
- The reported order contrast is **half** the difference between the two pair
  derivatives. It is one within-quartet noise/order diagnostic, not four
  independent repetitions or a confidence interval.
- Reported acquisition time is67.183136842s, startup readiness49.710475776s,
  total stage118.336527232s. These are lifecycle timings of this simulated
  finite run, not a frame-rate or deadline qualification.

### Derived amplitude contrasts

Projection uses the same independent baseline `Dbar * direction` unit vector
at both amplitudes. Percentages below divide the projected0.04-minus0.02
change by the baseline predicted derivative norm; they are not percentages
relative to an unknown noise-free derivative.

| Family | Canonical modes | Projected changes |
| --- | --- | --- |
| Hadamard | 17,145,273,401 | +2.830%,+3.086%,+3.176%,+2.716% |
| Controller-modal | 12,65,119,176 | +0.310%,−2.051%,+2.230%,+1.234% |
| Spatial | 1,16,33,48 | +3.131%,+1.145%,+3.578%,+3.572% |

The dense projected changes exceed their observed within-quartet projected
half-order contrasts. Controller-modal results have mixed signs and much lower
signal norm, so this pilot does not resolve their amplitude dependence well.
The coherent dense effect cannot be relabeled as a noise/SNR improvement.
The baseline D is noisy and finite-amplitude; disagreement with it alone does
not identify which estimator is biased.

All pilot patterns acquire0.02 before0.04, with one quartet per amplitude.
Counterbalanced sign pairs remove the first-order within-quartet drift term,
but do not independently separate amplitude from between-condition chronology,
settling/history, or changing detector/WFS response. No identified optical or
WFS mechanism is claimed. Absence of a large even residual would not exclude
an odd cubic response contribution to the signed derivative.

### Smallest recommended confirmation

Use four existing directions: Hadamard canonical17 and401; spatial canonical1
and16. The Hadamard choices span the previously declared row sample; spatial
choices include the observed strong and weaker contrasts. This is deliberate
follow-up selection from the pilot, not an independent random sample of all
patterns. Preserve their exact public geometry/frequency grid and direction
arrays; introduce no replacement pattern based on new outcomes.

At each of0.01,0.02,0.04 physical peak acquire N64 per signed batch, **two**
quartets of opposite ABBA/BAAB orientation, each with two bracketing reference
batches. Total:4 directions ×3 amplitudes ×2 quartets ×6 batches =144 batches,
9216 accepted frames and9361 model exposures including settling/restoration.
This halves the proposed eight-direction follow-up while retaining a clear
Hadamard replication and spatial contrast discriminator. Do not predict wall
runtime from exposure count alone.

Freeze the exact order before acquisition. Assign cyclic amplitude triples to
patterns in the first repetition and reverse each triple in the second;
reverse pattern traversal as well. This balances each condition's mean serial
position across repetitions and removes universal low-before-high ordering.
Use independent declared detector samples, unchanged source/settings and the
same finite lifecycle bounds. Keep repetitions separate in the report.

Predeclare projected0.02-minus0.01 and0.04-minus0.02 contrasts, their two
quartet-specific realizations, pair/order diagnostics, vector changes, reference
drift and even residuals. Compare corrected and uncorrected balanced means as
an analysis check. N64 reduces derivative noise relative to the N16 pilot;
two quartets remain weak support for any distributional confidence claim.
A coherent replicated trend supports amplitude association over those sampled
patterns. An unresolved0.01/0.02 contrast is an uncertainty statement, not proof
of zero nonlinearity or a global512-pattern guarantee.

After that evidence, adjudicate a finite amplitude for the full method and
retain its prediction limits. If amplitudes differ by method, report that
explicitly; it ceases to be a same-amplitude comparison. Common physical
held-out prediction and the frozen command/energy accounting remain required.
No full Hadamard sweep or detector/controller setting change is recommended
before this bounded confirmation is reviewed.

## MCR-7 — Portable method owner and reduction review

**Disposition:** no blocking defect found in the frozen source. Ordinary-array
and mocked-owner verification passed independently. Actual installed method
execution remains a separate gate. **Confidence:** high for the reviewed
admission, permutation, matrix packing and explicit candidate boundary.

| Reviewed file | SHA-256 |
| --- | --- |
| `deployment/calibration_method.py` | `169c7adf0232e3e096f41d3ec4bd6726a579b1fcd06dd6a4a794220a08fd2465` |
| `deployment/hil/calibration_method_analysis.jl` | `d27274c5b55e8d5a4cd9b231405e719163cca629c35cafaa773fab2ee1bba71c` |
| `deployment/test_calibration_method.py` | `4524aa71ff5eb4fcf79db8aa2ed80457e24249e724db77a46ba51efd64c94697` |
| `deployment/hil/test_calibration_method_analysis.jl` | `0472ebed1025cc0e0af38acdbae805227639abae3d00f1356befc915c9ccee3b` |

### Admission and scientific ownership

The owner requires explicit base, recipe, method, AOC source, RTC/coordinator
binaries, new output and new runtime paths. It has no cache-specific scientific
source or probe defaults. The maintained `/opt/pipewireao` limitation is checked
explicitly. Method version/run/order and basis field sets are validated;
numerical mode/geometry admission is delegated to the public AOC client before
RTC launch. Existing `stage_base` enforces complete-frame Classic CPU.

Retained background/reference/active arrays are obtained from the actual base
bindings, checked against startup graph/provenance, finite element types and
exact shapes. They are copied into a new package. No noiseless calibration
helper regenerates those offsets in this path. The explicit recipe controls
lamp/seed and acquisition parameters, so a fair method comparison must still
freeze matching recipes; this owner does not itself certify that two separately
supplied recipes describe identical science.

### Prepare seal and chronological reduction

Preparation writes both canonical and chronological plans plus an explicit
chronology-to-canonical permutation. It retains the actual client used in the
package and checks that its analysis copy has the same digest. Before launch,
the Python owner hashes prepared files, copied analysis/orchestration sources
and all ordinary package files into `prepared-identity.json`, retaining that
seal digest in process memory. Source-package identity is checked before and
after acquisition. New paths and symlink restrictions prevent ordinary source
package overwrite; existing candidate outputs are rejected.

After acquisition, the owner checks lifecycle flags and frozen identities.
The Julia reducer additionally requires clean stopped deployment state,
launcher exit0 and no reported failure/recovery/cleanup error. It validates the
expected pre-acquisition seal before loading science responses or reconstructing
the basis. It regenerates and compares the exact chronological CLI plan, then
validates receipt chronology against that plan. Only numerical response rows
are inverse-permuted. Full-row reverse order therefore restores both physical
coordinate order and plus/minus sign correctly. Hadamard complete-cycle
semantics remain owned by its public AOC estimator.

For modal/spatial methods, reduced matrix shape is376×declared-mode-count and
coordinate kind is `mode_direction`; physical estimators remain
`physical_actuator`. Basis metadata contains actual positive deltas reconstructed
from exactly preserved Float32 figures/reference, with its own explicit
column-major shape/layout. The packed candidate matrix uses
`vec(permutedims(matrix))`, correctly yielding F32_LE ROW_MAJOR in measurement
by estimated-coordinate order. The fixture verifies actual bytes by reconstructing
the376×2 matrix, including a nonzero last measurement row.

The candidate includes input/package/CLI/stage hashes and an explicit
`complete-unaccepted-candidate` status. No inverse is selected, existing active
matrix replaced or correction authority granted. Analysis failure occurs after
the shared stage's restore/release/shutdown path; preparation failure does not
launch acquisition. A partial candidate payload without successful final
metadata is not a completed candidate. The recorded cold estimator timing is
separate from total reduction-process and acquisition/startup timings.

### Independent verification

Executed the existing focused Python suite with `PYTHONPATH=deployment`:
8/8 tests passed, exit0. Executed the existing Julia suite on CPU5 using the
same installed project/depot as MCR-5, `--threads=1,0`,
`--check-bounds=yes`, `--depwarn=error`, and one OpenBLAS thread:
56/56 assertions across three test sets passed, exit0, with no emitted warning.
The tests include forward/reverse reduction, exposure-associated batch swaps,
invalid permutation, changed plan/method/client/analyzer/seal, lifecycle failure,
existing outputs and incomplete/mocked acquisition behavior.

Retained logs under `~/.cache/rtc-calibration-quality-20261003/method-owner/`:

| Log | SHA-256 |
| --- | --- |
| `independent-python.log` | `31d461d4f5ea9a76ac910ab10c6f0bdaffcf73105fffad0bef6b67b23d0e121f` |
| `independent-julia-bounds.log` | `fc30f5073ad10fcd03db3a938c066e0af37f04577dd375bf1a70dfddc27baa6e` |

This reviewer performed no RTC launch or production source edit. A small actual
reverse-modal lifecycle/packing run is the appropriate next integration gate.
Dense scientific confirmation and later full-method comparison retain MCR-6's
separate amplitude/order and finite-span conditions.

## MCR-8 — Actual reverse-modal installed smoke

**Disposition:** the bounded maintained method-owner integration gate passes
for the recorded two-direction reverse-modal case. This does not qualify a
full method matrix or its scientific accuracy. **Confidence:** high; independent
file/receipt audit and public-AOC numerical recomputation completed.

Case: `~/.cache/rtc-calibration-quality-20261003/method-smoke-reverse-v2`.
The method-result SHA-256 is
`ca76b0ef3b4e0604b8972b22dcb46906c0c86de5818301fde16be24745fc0059`;
candidate metadata SHA-256 is
`6c3a2474a0c31cc8fca2555caaca7ac9257feb18697f4e00100a47d5ce5075ae`.
The pre-acquisition seal is
`9ff790295241f58cf7f48facfcc08694fd44c87ed8d9fbffcfead105bc6943bf`.

Independent checks verified all20 sealed preparation/source files and all381
package files, including exact package file-set equality. The installed owner,
analyzer and client match MCR-7/MCR-5's reviewed hashes. Every declared CLI,
stage and candidate payload hash matches. Package hashes remain unchanged after
the independent numerical check.

The four chronological figures exactly implement canonical rows `[4,3,2,1]`.
Both positive physical-direction rows agree with the method declaration and
candidate basis metadata. There are64 valid unique exposures,16 in each batch,
with increasing identities from `(1,1,2)` through `(1,1,68)`, fixed duration
1,896,000ns and ordered nonoverlapping model-time intervals. The coordinator
reports complete acquisition, restoration and ownership release without primary
or recovery failure. The deployment reports stopped, no final error and launcher
exit0; its source sequence69 is the fresh final restoration exposure. The runtime
instance directory is gone; its parent retains the ordinary deployment lock and
state record. No independent child-exit-code claim is inferred from launcher0.

A separate Julia process on CPU5 used the actual packaged public AOC client,
reconstructed the declared canonical basis, validated chronological receipts,
applied the inverse permutation, estimated and packed the result independently
of the method reducer. It reproduced every byte of the376×2 F32_LE ROW_MAJOR
candidate:3008 bytes, SHA-256
`9eddbeaf7efc15364280a03411841557bedecc53aff9fe82571a0e635950dc70`.
The candidate is explicitly `mode_direction`, `complete-unaccepted-candidate`,
with no reconstructor selection, physical activation or scientific acceptance.

The independent process used the case's packaged HIL project with
`--threads=1,0 --check-bounds=yes --depwarn=error`, one OpenBLAS thread and the
recorded ndarray depot. It exited0. Its log
`method-owner/smoke-independent-aoc.log` has SHA-256
`178b93672e1da2ce4af3070300ece894da5a5cdef7438acc3689a65c966c0eba`.
Julia printed a dependency-precompilation notice about already-loaded stdlib
versions; no numerical mismatch or deprecation error occurred.

Reported lifecycle timings are preparation5.861488327s, startup49.269273568s,
acquisition12.181828514s, shutdown1.005249680s, reduction4.076275875s and total
72.451347077s. Total includes surrounding ownership/provenance overhead and is
not required to equal the sum of selected subintervals. No cadence inference
is made.

The first attempt remains preserved under `method-smoke-reverse`. Its deployment
log states `core CPUs unavailable in inherited affinity: [5]`; no candidate
exists. The successful retry admitted the configured placement. This distinction
preserves the prelaunch failure without attributing it to science or receipt
ordering. No new RTC launch or production edit was performed by this reviewer.

## MCR-9 — Dense confirmation and first full comparison cohort

**Disposition:** actual confirmation is verified. The dense0.02-to0.04
association persists under the reversed schedule. Proceed, if adjudicated,
with a four-sweep Hadamard/zonal characterization cohort at explicitly different
finite amplitudes. Defer the additional full controller-modal/spatial sweeps
until the first comparison is interpreted. No common infinitesimal derivative,
method superiority or specific WFS mechanism is established.

### Independent confirmation audit

Cache: `~/.cache/rtc-calibration-quality-20261003/dense-method-confirmation`.
Report SHA-256:
`f7242b5f91ae3b8a655145b1facb11e84db36e820ec2eea726be548264f9b3a5`.
Analyzer SHA-256:
`6b882c4140f612c16e06f1688bf8cd3f7db9ec5d3fa3caec5f82404bf12aa198`.

Independent NumPy calculations from preserved batch responses reproduce every
condition statistic and amplitude contrast within2.14×10⁻¹³ absolute difference.
All report source digests, baseline D digest, prior-pilot policy digest and
preparation-script digest match. Actual rounded signed figures match labels
and declared directions at each amplitude. Their normalized directions are
identical across0.01,0.02,0.04; geometry/rounding has not changed the direction.
The packaged active mask matches the pilot. Reference correction changes each
balanced mean derivative by at most7.2×10⁻¹⁵ in norm.

The144 batches contain9216 valid, unique, chronological exposures,64 each,
from `(1,1,2)` through `(1,1,9360)`, with unchanged domain/generation and
1,896,000ns duration. Intervals are nonoverlapping and ordered. Completion,
restoration, release, shutdown and launcher exit0 pass; final source sequence
is9361. Each condition has two zero reference figures and a correctly signed
quartet. The second repetition exactly reverses the first repetition's
pattern/amplitude block order and flips the quartet signs. Thus the first
pilot's universal low-before-high schedule is not sufficient to explain the
replicated amplitude association.

Projected percentage contrasts use the fixed baseline-prediction norm as their
denominator. Two repetitions remain two observations, not a confidence bound:

| Pattern | 0.01→0.02, repetitions1/2 | 0.02→0.04, repetitions1/2 |
| --- | --- | --- |
| Hadamard17 | −0.002% / −0.033% | +2.849% / +2.840% |
| Hadamard401 | +0.572% / +0.202% | +2.684% / +2.665% |
| Spatial1 | +0.544% / +0.888% | +3.419% / +3.325% |
| Spatial16 | +0.425% / +0.700% | +1.212% / +1.266% |

The smaller-amplitude contrasts do not prove a plateau: three patterns retain
positive contrasts in both repetitions, with appreciable between-repetition
variation. Selecting0.01 for dense characterization is a declared finite
amplitude choice supported by lower observed amplitude sensitivity, not proof
that every dense pattern is linear there. The test covers selected patterns
and cannot identify an intrinsic optical, centroiding, threshold or noise-bias
mechanism by itself.

Reported startup is41.191573460s, acquisition135.782652816s,
shutdown1.013007388s and total stage177.987419501s. This reviewer performed
no acquisition; these are audited actual-run records, not estimated cadence.

### Recommended smaller cohort

Freeze two full Hadamard277/order512 sweeps at0.01,N8 and two full zonal277
sweeps at0.04,N16, each method with independent declared detector seeds and
opposite complete chronological/sign order. Record actual wire bases and all
input/settings identities before launch. Declare method execution order and
avoid interpreting its four finite runs as a confidence distribution. Keeping
both methods in the full physical coordinate space makes their composition
through the same B and their common physical predictions directly comparable.

This cohort uses34112 accepted exposures and37272 total model exposures,
including one settling exposure per signed batch and one final restoration per
sweep, before any extra references. Adding two controller-modal0.04,N16 and two
spatial64-mode0.01,N16 sweeps raises these totals to52352 accepted and56656 model
exposures. Additional held-out/reference data must be budgeted separately;
80,000 is not the count of these eight sweeps alone. Stagewise execution avoids
committing the additional18240 accepted exposures before learning whether the
full-span dense estimate has useful prediction accuracy.

At these amplitudes and batch counts, under the ideal independent homogeneous
additive-noise linear model, Hadamard's per-coefficient standard deviation is
one quarter of zonal's. This is a conditional benchmark from the public decoding
equations, not an observed result or target. Hadamard simultaneously spends
16 times the total integrated squared physical command energy per full sweep:
its per-exposure command energy is17.3125 times the zonal pattern energy, while
its accepted exposure count is8192 versus8864. The amplitude and energy
inequality is intentional and must remain explicit. The comparison concerns
operational acquisition cost under a peak limit; it is neither equal-energy
performance nor an isolated estimator comparison at identical stimuli.

Record measured repeat/order operator discrepancies, finite-amplitude physical
and controller predictions, actual command energies, accepted/settling counts,
quality rejection and separate startup/acquisition/reduction timings. Public
AOC estimates remain candidates. Agreement with the earlier N64 zonal matrix
is useful context, but that matrix remains a noisy finite-amplitude estimate.

Use the same physical held-out measurements to score both candidate methods;
there is no need to reacquire identical held-out commands separately for each
estimator. Existing frozen held-out observations can provide a descriptive
comparison. If inverse policy or method settings are selected from them, use a
fresh declared common locked corpus for the final claim. Freeze the policy
function, validation metric and tie rule before computing outcomes; evaluating
several methods does not authorize repeatedly reusing an exposed locked set as
an untouched test. No active reconstructor replacement is part of this cohort.

Once that evidence is interpreted, the221-column controller-modal branch can
address representation efficiency on the same controller task, and the64-mode
spatial branch can characterize its explicitly limited span. Neither must be
acquired now to resolve the initial full-span Hadamard/zonal question.

## MCR-10 — Actual full physical Hadamard/zonal cohort

**Disposition:** independent integration and descriptive numerical audit passes.
No estimator winner, new inverse, controller replacement, universal linearity,
equal-energy advantage or cadence qualification follows from this result.

Cache: `~/.cache/rtc-calibration-quality-20261003/method-cohort`.
Frozen pre-acquisition policy SHA-256:
`142549f176135fb9d6405b96c1569fdf164e61ea034dc6d5b921ba6b5c15cf74`.
Frozen analyzer SHA-256:
`e38bd7110c08b72271fc69ff4888b67f3da0476106f3852baa66498162c82c5a`.
Actual `comparison.json` SHA-256:
`75428573a1ae0aee04ab9d0a03f3d4e4d19505de98c3ffb92a879bcda89a0c60`.

The source review confirmed complete public-AOC physical estimation,
chronological receipt validation before inverse permutation, true spectral
`opnorm(S*(D1-D2)*B,2)/sqrt(2)`, actual Float32 held-out commands and the original
signed-pair response equation. The analyzer's40 focused tests were reported
passed by its owner before freezing. The primary agent then executed it
successfully against all four completed cases. This reviewer independently
recomputed the recorded data using NumPy on CPU5; no RTC run or source edit was
performed.

### Independent data and representation checks

- Each case's20 sealed files and381-file package matches both the recorded
  hashes and exact package file set. Input recipe/method hashes match the
  frozen cohort policy; CLI, stage and candidate payload hashes match.
- Both Hadamard cycles contain1024 signed batches,8192 accepted exposures,
  final accepted sequence9216 and restoration sequence9217. Each zonal cycle
  contains554 signed batches,8864 accepted exposures, final accepted sequence
  9418 and restoration sequence9419. Exposure identities are unique and
  chronological within each domain/generation, with valid fixed1,896,000ns
  duration and nonoverlapping intervals. All four restore, release and cleanly
  stop with launcher exit0.
- Total accepted exposure count is34112; total model exposures are37272.
  Settling and reference cost are separate from accepted command energy.
- An independent Float32 recurrence reconstructs **every candidate byte**:
  zonal signed differences with the declared reciprocal amplitude; Hadamard
  sum over all512 non-DC Sylvester sign rows and the declared complete-cycle
  normalization. Chronological rows are first restored to canonical order.
  This independently confirms physical376×277 ROW_MAJOR F32 representation,
  beyond the analyzer's public-AOC re-estimation check.
- Exact startup arrays, graphs, five top-level HIL preparation/association
  helpers, six packaged scientific source trees and selected configuration
  files match across the four cohort packages, both N64 baseline packages and
  the retained held-out package. Plant and adopted detector configurations
  match after removing only the declared detector RNG seed. The selectable
  analysis client version is separately provenanced; no blanket assertion that
  every file in old and new packages is identical is made.
- Every case, family-mean and baseline forward score independently reproduces
  within1.43×10⁻¹⁴ absolute difference using the same actual physical vectors,
  selected368 rows and `z=(response_plus−response_minus)/2`. Bracketing nulls
  remain diagnostics and are not newly subtracted from those frozen contrasts.

### Observed finite-corpus results

| Quantity | Zonal0.04,N16 | Hadamard0.01,N8 |
| --- | ---: | ---: |
| Empirical spectral repeat/order scale | 3.9600248694 | 0.9845044085 |
| Relative physical Frobenius disagreement | 0.4827075718 | 0.1234340550 |
| Mean-matrix sparse residual RMS, pair1/2 (pixel) | 0.0026283 / 0.0025658 | 0.0018008 / 0.0018003 |
| Mean-matrix mixed residual RMS, pair1/2 (pixel) | 0.0288339 / 0.0288118 | 0.0089013 / 0.0088930 |
| Accepted squared command energy per sweep (µm² OPD·exposures) | 14.1823993660 | 226.9183898560 |
| Acquisition time, sweep1/2 (s) | 146.7623 / 146.5071 | 156.8668 / 154.3806 |

The spectral scale has units pixel/µm OPD in the declared controller composition.
It is a two-realization repeat/order discrepancy, not a confidence bound or pure
noise standard deviation. The ratio is close to the ideal homogeneous-noise
prediction of a fourfold standard-deviation reduction at these amplitudes and
averaging counts; agreement with that model does not prove it accounts for all
bias or all directions. The actual Hadamard integrated squared command energy
is16 times zonal. Its acquisition takes longer here despite fewer accepted
exposures; the result is not a frame-rate benchmark or proof of the timing cause.

Hadamard's measured family mean has lower error on both sparse/mixed groups and
both retained pair realizations in this specific previously observed corpus.
This is a supported descriptive improvement under different amplitudes, energies
and pattern families. It does not establish equal-energy estimator superiority,
an untouched new locked test, negligible nonlinear bias across512 patterns,
physical full rank or an accepted reconstructor. The previous N64 mean remains
a noisy finite-amplitude comparator, not truth. No numerical policy was retuned
and no new inverse was selected by this comparison.

The recorded comparison can inform the next explicitly declared
controller-modal/full-controller and spatial/partial-span experiments under
MCR-2/MCR-3. Their distinct representation claims, actual command energy and
fresh selection/test boundaries remain required; these observations do not
remove those conditions.
