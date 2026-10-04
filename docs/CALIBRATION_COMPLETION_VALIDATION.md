# Measured calibration completion evidence

## Scope and provenance

This record concerns finite, completion-driven AOS scientific checks under
RTC-ARCH-023 and RTC-DEV-029. It does not qualify physical instruments,
wall-clock cadence, ordinary HEART progressive delivery or detector electronics.
The [plan](CALIBRATION_COMPLETION_PLAN.md) records the frozen decision rules;
the [review](CALIBRATION_COMPLETION_REVIEW.md) records independent findings.

Starting RTC revision is `6f57ea48b2620fe13b9d09a08a02ee4aeca755ce`.
Actual copied source, binary, array, recipe, environment and payload hashes in
each completed package take precedence over repository HEAD. Raw evidence is
retained in `~/.cache/rtc-calibration-completion-20261003/`.
Classic CPU results are retained in [the prior method selection](CALIBRATION_METHOD_SELECTION.md).

## Final deployment verification

The final immutable `native-correction-preparation-source-v10/deployment`
snapshot contains 151 files. Its copy proof has SHA256
`a10eaf47cf8dba114b3ed2941d94fe882c91accbc5767653ad2b221cd8231551`.
All 151 maintained deployment files match this snapshot. All source identities
remain unchanged across its SDK run: 1,190/1,190 assertions, 57 testsets and all
14 registered suites pass. This includes 174 installer assertions and 170
package/relocation/source-closure assertions. The log `final-sdk-v10-suite.log`
has SHA256
`e4504b9bd5ef18069b6262accbc87fcdab0691ccf3e2d295dbeddf351f1c6c42`.
Two Git provenance diagnostics come from successful export fixtures outside a
Git checkout; the duplicate YAML key diagnostic is an expected rejection test.
Earlier source-v8/v9 checkpoints passed the same SDK assertion count. Their
focused regressions and the source-v10 normal-response policy checks below
retain their distinct source identities. Cold checks alone do not establish
native correction utility.

The final Rust workspace run passes 97 tests, with none ignored. Formatting and
Clippy pass. The retained `proc-macro-error2` dependency produces a future
compatibility warning; it is not a current test or Clippy failure.
The final `live` feature build succeeds; its workspace run passes 134 tests.
Three opt-in private-core tests were not selected in that invocation. The
selected actual calibration and correction live checks are recorded separately
below; their results do not stand in for those unrelated test scopes.

Ten cold HIL regressions on the earlier immutable source-v6 pass 1,273/1,273
assertions across 67 testsets: acquisition, bounded server, method analysis,
inverse selection, correction truth/replay, owner protocol and Classic
transfer/projection. Ten guards confirm that these runs do not import CUDA or
AMDGPU. All 664 frozen source/environment files remain unchanged. The combined
log `final-hil-v6-regression/suite.log` has SHA256
`b9c5dc09492b39bc621b0098bae44e919e7b77fd43f7b36dafc2a1a8fd0ad976`.
Subsequent source-v8 focused checks pass 259 assertions, including actual
Classic and Copper boundary preparation and original failure regressions.
Independent production-boundary preparation adds 15 Classic CPU assertions;
the actual package loader and boundary together pass 20 assertions.
Source-v9 adds 98 focused assertions: 81 owner assertions and 17 actual public
runtime-layout fail-before/pass-after assertions. Independent full startup
proof adds nine corrected assertions, followed by ten through the fresh
package itself. Mutated wire geometry and target bytes still reject. The
original four scientific helpers remain byte identical through source-v10.

Source-v10 adds 267 focused assertions for response classification, retained
phase analysis and owner lifecycle, plus 64 independent mutations against the
actual first failed Classic payload. The independent comparison of both
previously accepted Copper archives passes 1,554 assertions under the unchanged
Copper policy. This is a bounded compatibility check, not a fresh source-v10
Copper live run. The earlier 1,273-assertion HIL suite was run on source-v6;
no full-HIL-suite result is claimed for source-v10.

The fresh Classic package5 is installed at
`final-classic-native-installed-v5`. Loading its installed Julia project verifies
all 528 descriptor artifacts, 73 orchestration files, both HEART export wrappers,
module registration and relocated resource roots against the prepared package.
The descriptor bytes are unchanged. Closure report SHA256:
`ec64f70b1fe6710dbd6c0586f16952d7628d71e70586d7c1c39e6619d1e892b8`.
The actual packaged full startup proof passes 14 assertions; its independent
response-policy mutation suite passes 64. Classic score issuance and export
replay use the same immutable source-v10 SDK root; no report is moved to a
different SDK root and declared reproduced. Earlier installed packages and
failed native runs remain retained as separate evidence. The Copper
installation independently verifies 522 descriptor artifacts and 72
orchestration files against its accepted prepared package.

## Separate private-core regression result

A root-owned matched discriminator runs the unchanged PipeWireAO generic
loan-exhaustion test against parent `3c846025` and candidate `aa50935` on CPU 11.
Both return seven passing assertions and the same source-completion timeout at
line 142. The loan-count assertion passes in these two runs. Exact test,
Project/Manifest, dependency, environment, Julia/thread and PipeWire runtime
identities match. The only expected loaded-module difference is the compiled
PipeWireAO package under test; all common native/JLL libraries are byte identical.
All preparation, dependency and prefix files remain unchanged.

Independent paired audit `ccr006-privatecore-paired-audit-v1.json` has SHA256
`b113dc298d71600e8c7f96f5d09a81f6a99df71aff310d1ff2463a4e3ece053f`.
This establishes that this timeout is also present before the zero-sequence
receive change. It does not establish its cause or turn the generic regression
into a passing gate. The selected native calibration/correction paths have
separate actual association and lifecycle evidence below. No production change
was made to conceal or bypass the failing test.

## Native Copper normal correction accepted

The fresh public source-v6 export repeats all ten retained native scientific
captures, both references, the training grid, validation selection and locked
utility before publishing `heart-native-correction-prepared-v6`. Its descriptor
SHA256 is `4094c82489c59ce77563eb857ece440d612f4c5e1b5c61fc614242a7e943aa1f`;
all 522 artifacts and the exact package inventory pass independent review.
The selected inverse, physical map, plant, gains and unchanged native executable
match the earlier frozen inputs.

The root-owned `native-correction-active-v7-evidence` run exits zero. Both
256-frame correction batches, public stop/reset/start, zero restoration, public
shutdown and both actual CUDA ADC/truth/zero-command replays pass. ADC, command
and live truth payloads reproduce exactly across the new native generation.
All seven recorded launcher, owner and native-generation PIDs are absent after
shutdown. Lifecycle SHA256:
`75b582b9e4a644a2ab12f3df9189917d8a4197efd6429e64b505cb7ab5b884ad`.

Both batches give residual/zero variance ratios 0.7153282641 and 0.6490191125
in the predeclared evaluation windows. Independent physical-demand verification
excludes DM limiting; maximum absolute command is about 0.154324 µm OPD.
Retained detector diagnostics independently reproduce two upper-rail pixels in
two frames, maximum ADC 16,383 and one declared initialization-invalid response.
Every pixel remains in the exact replay. This is acceptance under the explicitly
disclosed normal-correction ADC rule, not unsaturated operation. The old failed
zero-rail gate remains false and its files are unchanged.

Analysis SHA256 values are
`b6d7bed1ecd7f22962078c99fb6c737069a1d106623f89f96bf42001bfab099f`
and `da48f76f6923e7fcf68e071649054755bfe301674c4407fe5dd5047cf66c2295`.
Independent final audit `native-copper-windows-independent-v7-final.json`
has SHA256 `14c85ba356cd9eeffc2b9b416b34d75d5b025aa8ccbbfa1981d9554d66bddfa0`
and verifies 885 inputs plus 28 cold assertions and exact truth equality.
This remains the selected deferred-ingress comparison fixture. It does not
resolve ordinary native Copper streaming CCR-017 or qualify cadence.

## Copper illumination and repeatability

Normal photon/read noise and 14-bit ADC remain enabled. The provisional detector
uses unity gain and excess-noise factor; it is not an accepted DU860 conversion
from electrons to ADC counts. Increasing lamp flux by 100× from the original
pilot gives mean pupil intensity about 2,744 ADC and maximum 4,001 in the
independent reference. No rail pixels were observed. The matching reference and
fresh detector seeds also changed; this is not a causal flux-only experiment.

Opposite-order derivative cosines at 0.02/0.04/0.08 µm OPD are
0.91956/0.97737/0.99421, with relative differences
0.40208/0.21295/0.10753. These demonstrate measurable responses, without
establishing instrument precision, population uncertainty or strict linearity.
Two repeats and shared normalization do not establish independent noise samples.

FGN and JFG each acquired two complete zonal, Hadamard and 64-direction spatial
sine/cosine matrices from the same frozen noisy CUDA plant. Every corresponding
measured matrix is byte identical across engines. Each zonal run contains 9,419
exposures; Hadamard 17,409; spatial 2,177. All completed runs confirm restoration,
release and public shutdown, with no ADC saturation or invalid accepted frames.

| Method | FGN acquisition seconds | JFG acquisition seconds | FGN total seconds | JFG total seconds |
| --- | ---: | ---: | ---: | ---: |
| Zonal | 166.03–166.79 | 162.85–166.09 | 319.15–325.04 | 296.86–349.84 |
| Hadamard | 291.42–295.41 | 294.48–295.61 | 446.31–449.80 | 426.55–428.41 |
| Spatial sine/cosine | 47.74–47.77 | 46.61–47.01 | 201.06–201.87 | 179.78–180.94 |

Total includes package preparation, readiness, acquisition, reduction and public
shutdown. Cold readiness varies; these are measured calibration durations, not
RTC latency benchmarks. Reduction is about 5.3–6.8 seconds per run. Hadamard uses
32× the signed probe energy of zonal at these amplitudes and averaging counts.
Its repeat discrepancy is 0.04608 versus zonal's 0.25679. Spatial discrepancy is
0.01669 over only its 64-dimensional measured span; it is not a full reconstructor.

A separate read-only timing run uses each preparation's captured reader and the
unchanged public AOC fitting helper, without modifying any candidate or selected
artifact. The six-candidate fit takes 1.06/1.10 seconds for FGN/JFG on the first
call after input verification, and 0.97/1.11 seconds on a second call in that
process. Package load and complete capture verification take 8.43/8.99 seconds.
These are individual observations with one Julia and BLAS thread on CPU 14,
not statistical timing estimates. Recomputed JFG coefficients match exactly;
FGN fitting differs by at most 3.4 × 10⁻¹⁰ relatively and zonal cutoffs by at
most 3.6 × 10⁻¹⁵ absolutely, with unchanged ranks. Original accepted coefficients
are preserved. Evidence is `fgn-inverse-timing-v3.json` and
`jfg-inverse-timing-v3.json`. Earlier timing attempts rejected the current reader
instead of loading the captured snapshot, then an overly strict bitwise cutoff
comparison; those logs are retained. No scientific selection gate was rerun or
weakened by these timing diagnostics.

## Composition, selection and held-out prediction

The actual physical map B is 277 × 253, rank 250, with three unactuated wire
coordinates. Fit Q D̄ U before inversion, where Q rejects the measured flat
response and U is the actuated orthonormal physical basis. Public AOC TSVD uses
the predeclared empirical cutoffs 1/2/4 times half the projected repeat-difference
norm. Neither the cutoff grid nor the controller coefficients were tuned using
held-out results.

Both engines independently select the 248-mode Hadamard inverse. Raw matrices,
maps and prepared scientific inputs match; packed inverse bytes differ in only
8–17 coefficients per 910,800, with relative differences below 3.4 × 10⁻¹⁰.
The execution mechanism producing these tiny differences is not established.

| Gate | FGN physical command SSE | JFG physical command SSE | Zero-command SSE |
| --- | ---: | ---: | ---: |
| Validation repeat 1 | 0.01312843 | 0.01312843 | 0.60150538 |
| Validation repeat 2 | 0.01439414 | 0.01439414 | 0.60150538 |
| Locked test repeat 1 | 0.02335807 | 0.02335807 | 0.68178564 |
| Locked test repeat 2 | 0.02334386 | 0.02334386 | 0.68178564 |

SSE uses absolute noisy batch means and micrometre OPD physical commands, not
only signed response differences. Both sparse and mixed groups improve over
zero in both repeats. The selected bytes were frozen before the locked test.
Fresh flat physical command norm is about 0.01627 µm OPD; controller coordinates
are not interchangeable with physical coordinates. Spatial forward validation
passes within the measured span, with projected response SSE 1.09614/1.09502
versus zero-response SSE 1,461.98/1,461.77.

## Deployed CUDA correction

The selected estimator predicts positive probe OPD. Copper's preserved positive
gain requires the negative estimator for correction against the additive OPD
plant. Gains, poles, anti-windup, maps and limits are preserved. Both engines
complete two 256-frame public stop/reset/restart batches with exact within-engine
reset payloads and direct live OPD truth. Actual CUDA replay verifies every ADC
pixel, the live truth and the zero-command baseline.

| Window | FGN residual/zero variance | JFG residual/zero variance |
| --- | ---: | ---: |
| Frames 17–128 | 0.71547319 | 0.71547328 |
| Frames 129–256 | 0.64897217 | 0.64897240 |

Peak commands are about 0.15339 µm OPD, below the 0.8 µm limit; no components are
at the limit. This diagnostic measures rail proximity, not requested-minus-demanded
clipping feedback. Separate algorithm tests cover the clipping feedback paths.
No near-zero residual or hardware-rate claim follows from this leaky controller.

A later independent audit of every retained detector sample finds two ADC rail
pixels in exposures 21 and 26, in both reset batches of FGN CUDA, JFG CUDA and
FGN AMD. Their locations agree across engines, and none exceeds the declared
14-bit range. The original verifier checks ADC ≤ rail and exact replay; it did
not establish zero detector saturation. The prior correction results retain
their finite replay/utility scope with this explicit saturation limitation.
Calibration/reference/probe captures use a separate strict zero-rail gate.

## Accelerator transfer and Classic correction

The frozen CUDA-derived Copper inverse passes AMD's two actual 1,041-exposure
directional transfer runs. Physical command SSE is 0.02336354/0.02334527 versus
zero-command SSE 0.68178564. Both sparse and mixed groups pass in both repeats;
relative directional-matrix differences from matched CUDA are
5.30335 × 10⁻⁵ and 5.37040 × 10⁻⁵.
No full AMD matrix is refitted, and matched seeds are not independent noise
corpora. Actual AMD device use requires the declared gfx10.3 override. Initial
report serialization failed on JSON3 object keys; the separately reviewed v2
route normalizes metadata while calling the exact unchanged scoring function.
Captures, policy, original sources and failure logs remain unchanged. The same
actual computed result demonstrates fail-before/pass-after serialization; the
cold verifier recomputes it exactly with one Julia and BLAS thread. The v2
preparer explicitly binds the new serializer and the original mathematical
source before constructing a correction package.

Classic FGN CUDA completes two 256-frame correction batches, public
stop/reset/restart and clean shutdown. Both actual CUDA replays verify every ADC
pixel, live OPD truth and the zero-command baseline. Residual/zero variance is
0.04427237 and 0.03436843 in the declared windows, with peak command
0.37895936 µm OPD and no components at the limit. Classic JFG CUDA also passes
both complete batches and replays: ratios 0.04428807/0.03435182, peak
0.37895930 µm OPD, no components at the limit, exact ADC and reset. Both have
maximum ADC 449, with no upper-rail pixels under the actual 12-bit rail 4,095.
The accepted 206-mode CPU inverse, CPU-derived simulated background/reference/
mask, 277→221 maps and gain −0.3/pole 0.99/anti-windup 0.99 are retained.
This is a backend correction check, not a newly measured full GPU matrix or
physical calibration.

Copper FGN AMD normal correction also passes two 256-frame public reset batches
with exact counts, identical ADC/command/direct OPD records and clean public
shutdown. The retained batch-1 HIP replay verifies exact ADC, direct live truth
and the zero-command baseline. Variance ratios are 0.71547259/0.64897138, peak command
0.15338704 µm OPD, with no components at the limit. This supports finite correction
using the unchanged CUDA-derived inverse on the explicitly selected AMD fixture.

## Native deferred acquisition and remaining streaming defect

Ordinary native streaming failed with reader counter 2→4 and a committed invalid
gradient; the adapter rejected it. The failed qualification reference,
restoration/shutdown dispositions and owned-process cleanup remain retained.
CCR-017 remains open. The selected existing HEART comparison binary's deferred
ingress qualifies a separate completion-driven Copper calibration path.
Receiving both packets before first-half release and using native processor/
reconstructor handshakes changes availability and synchronization. It cannot
qualify ordinary progressive delivery or hardware cadence. The selected
unchanged compiled executable SHA is
`1c0862686dc79d127033845a12d32a0d12ac4ccc24a28396f69d0233b16ef9d1`;
`HRT_DEFER_WFS_INGRESS=1` is explicit in captured provenance.

The fresh deferred N2 check passes seven exposures, three DM commands and four
accepted responses. Both fresh flat references pass 34 exposures and 32 accepted
responses each, with ADC maxima 4,038/4,009 and no rails. All actual payloads and
public means, stopped states, process cleanup and source seals were independently
verified. Native reference bytes differ from the FGN reference, so the native
cohort freezes its own measured reference and Q before training.

Both native zonal runs pass acquisition, public shutdown and AOC candidate
reduction after evidence revalidation. Each completes 9,419 exposures and produces a 3,600×277
Float32 candidate in physical probe-column order, with native normalized
quadrant-major measurements. Public batch means match retained native payloads.
Each has 8,864 accepted frames and 555 native DM records, ADC maxima 4,636/4,611
and no rails, under seeds 531/532 and opposing sign chronology. Each first
initialization exposure is invalid; it remains recorded and is excluded from
accepted responses. Both final states are stopped/unadmitted without error or
fallback cleanup. Candidate status is `complete-unaccepted-candidate`: no native
inverse selection, matrix installation or active correction follows from it.

| Native zonal phase | Repeat 1 seconds | Repeat 2 seconds |
| --- | ---: | ---: |
| Startup readiness | 86.42 | 86.73 |
| Acquisition including first call | 153.24 | 152.98 |
| Evidence revalidation and reduction | 24.75 | 24.54 |
| Driver total | 316.27 | 316.19 |

These are single observed completion-driven durations, not cadence benchmarks.
The native Hadamard and spatial pairs subsequently passed all three gates.
Each Hadamard run completed 17,409 exposures (16,384 accepted), maximum ADC
4,679 and no rails; acquisition including first call took 270.57/269.81 seconds
and driver totals were 512.52/505.87 seconds. Each spatial run completed 2,177
exposures. The frozen native grid uses its own measured reference and actual
277×253 map. Independent review reproduced all six response reductions and
inverse candidates bitwise, verified 21,566 input hashes and passed 123 checks.
Zonal retained ranks are 221/185/135 and Hadamard 248/235/219.

Reserved native validation independently selects the 248-mode Hadamard inverse.
Absolute physical SSE is 0.01821032/0.01870845 against zero-command SSE
0.60150538; sparse and mixed groups improve in each repeat. Independent review
reproduces every numerical field and selected byte, checks 22,861 consumed input
hashes and passes 107 separate per-vector assertions. The native estimator and
negative controller are frozen before the selected-only locked acquisitions.
Those fresh acquisitions pass acquisition, reduction and public shutdown;
locked physical SSE is 0.02768033/0.02767545 against zero-command SSE
0.68178564, again improving both groups. The fresh native spatial hold-outs also
pass all three lifecycle gates and forward prediction: projected SSE
1.09614378/1.09501814 against zero-response SSE 1461.98374/1461.77676.
The recorded span has rank 64 and held-out relative span residual 1.53×10⁻⁸;
this qualifies the measured partial span, not a complete physical inverse.
Independent review approves locked utility (full replay, 24,148 input hashes and
21 separate numerical assertions) and partial-span spatial utility (22,861 input
hashes and 50 assertions). Actual active correction remains a separate gate.

Native selection evidence: `native-selection-v1/selection.json`, SHA
`cc3bbf1084ba385e5d2ed50c18eb524ca35c6aab0d754741b316327effc14214`.
Locked evidence: `native-locked-v1/locked-test.json`, SHA
`fa3f23719478ed21b6807d99c9ad3788902dba20d5e834aefbaf8a37f7b4627c`.
The selected native negative controller SHA is
`7b65491be869943e8b56f05ecba792950fdbcdf795d0bdd38927f323c6144858`.
Spatial evidence: `native-spatial-forward-v1/spatial-forward.json`, SHA
`c27d14b41b71e08e93a8142b7dbead3b033e7be2b62ca35a66f087b0b61fd7a1`.

Matched native/FGN interaction matrices have relative Frobenius differences
7.90×10⁻⁶/7.51×10⁻⁶ for zonal, 2.01×10⁻⁶/2.04×10⁻⁶ for Hadamard and
1.38×10⁻⁶/1.27×10⁻⁶ for spatial. These descriptive comparisons do not set an
equivalence tolerance or substitute for correction. The native grid's 21.73
second fitting phase also includes a full post-fit input hash recheck; it is
not a pure inverse-fitting measurement.
Native Classic scientific coverage is separate from its completed functional
bridge.

Classic FGN/JFG subsequently passed both AMD reset batches and both actual HIP
replays with the same accepted CPU inverse. FGN residual variance ratios are
0.04430208/0.03434169; JFG 0.04427908/0.03439630. Each verifies exact ADC, direct
OPD truth and the zero-command baseline, with no components at the limit.
The explicit `HSA_OVERRIDE_GFX_VERSION=10.3.0` remains part of this host's
AMDGPU fixture. This completes the four selected Classic accelerator correction
cases; it does not establish new accelerator-fitted matrices or wall cadence.

## Native Classic transfer acquisition

The accepted Classic inverse, coordinate maps, measured background/reference
and fixed eligibility are bound into an unchanged native configuration for a
held four-direction transfer experiment. The first capture completes but its
verifier falsely equates the 1.896 ms integration with the 2 ms frame interval
(CCR-025). That package, failed gate and missing final manifest remain preserved.
An independently reviewed timing check binds these two quantities separately
to the sealed source arguments and detector configuration.

A fresh public run, `classic-native-transfer-v2-evidence`, passes capture,
retained-payload validation and public shutdown. All 1,561 completed exposures,
1,536 accepted exposures, 25 physical commands and public response means match
the native records. Maximum ADC is 1,719 against the 4,095 rail, with no invalid
measurements or rail hits. Acquisition including first calls takes 36.83 s;
mean/count validation takes 6.73 s and retention/payload verification 17.15 s.
These are application phase observations, not achievable RTC cadence.

Root verifies all 203 retained manifest entries. Completion SHA-256 is
`f83775613a937aa99bc8c3d0cb5eef155796ec2ba4fc2db115ca8d8cb2de9d2a`;
manifest SHA-256 is
`c54142caa900c6312f14b9dbab50a162089fe568046692d2a4a3a338a27739a4`.
Scientific scoring and active correction remain separate gates. Actual scorer
admission exposes an unnecessary Copper-only helper requirement (CCR-028).
Removing that unused requirement passes five actual-capture admission and
consumed-helper mutation checks in root and independent review. The original
failed admission is preserved. The admitted successor then stops before
numerical scoring: its object-only JSON loader rejects the sealed array of
probe labels (CCR-029). The maintained scoring worker has the same parser
defect. Its failed worker output is retained. The same sealed 24-label array
fails the original loader and passes the corrected typed loader in seven
root and independent assertions; 16 maintained loader/math assertions also
pass. Independent review confirms unchanged numerical mathematics.
Neither correction requires reacquisition or a change to the scientific data
or criteria.

The corrected cache v6 scorer then completes successfully on the same capture.
Both sparse and mixed groups pass forward and physical inverse utility in both
signed repeats, using the fixed accepted inverse and forward model:

| Group | Physical inverse SSE, repeat 1 / 2 | Zero-command SSE | Forward SSE, repeat 1 / 2 | Zero-response SSE, repeat 1 / 2 |
| --- | ---: | ---: | ---: | ---: |
| Sparse | 0.00035349 / 0.00033621 | 0.00376031 | 0.00245455 / 0.00243455 | 0.05847275 / 0.05800280 |
| Mixed | 0.02739922 / 0.02770031 | 0.50410814 | 0.07304064 / 0.07313413 | 13.24629274 / 13.23743984 |

Physical command SSE uses micrometre OPD squared; forward SSE uses detector
measurement coordinates squared. Actual raw and masked forward losses agree,
and the physical predictions are bit identical. No fitting or selection used
these four held-out directions. The report
`classic-native-transfer-v2-score-characterization-v6.json` has SHA-256
`8af4dc82f8b1e75a9adbc3c905661ddbc5c29936db9e829bc0860ee2bc01ebb9`.
This is finite four-direction transfer utility, not full-space or active
correction qualification. Independent actual-result review verifies all 514
package and 205 evidence identities, reconstructs all 9,024 public mean values
bit exactly from 1,561 retained native gradient records, and independently
recomputes every paired loss and prediction. Audit
`classic-transfer-score-independent-v6.json` has SHA-256
`605b06ebad90edf9573ffbc2e0bf7a2cec7065cfb75ba63c97858900545bf849`.
At this historical scoring checkpoint, maintained same-root score replay and
active correction were separate gates. Subsequent fresh package and actual
correction acceptance are recorded below.

## Compact source and evidence identities

Paths below are relative to `~/.cache/rtc-calibration-completion-20261003/`.
Each report or companion binds the actual sources, binary, arrays, environment
and subordinate evidence; the entries are not substitutes for their full seals.

| Evidence | SHA-256 |
| --- | --- |
| `fgn-amdgpu-transfer-v2.json` | `f9c8785ee661e54b962af89885eeb4c287ddf2d77d26b87f5b5bf7191a7a9acc` |
| `amdgpu-transfer-serialization-identity-v2.json` | `14c092d668ffc0537cdd03359e278e77042dc1e777246d9fa67689c12daaa2c3` |
| `fgn-amdgpu-transfer-scoring.log` — preserved failed serialization | `215c814f38d0d9a4ad7a38f4bab3b858f5981072797d9d5a799e324e01233b34` |
| `fgn-correction-amdgpu-v2/deployment.conf` | `8f06d785a20530cf2d2631e03295d7fd0a6ef45cfd67a26472f22a6ccb2c836a` |
| `fgn-correction-amdgpu-v2-evidence.lifecycle.json` | `4b68e30472bebac1b53abbd174b0b1ff08e1114f0beeca9d1a6e3f58ec5d5822` |
| `fgn-correction-amdgpu-v2-batch1-analysis.json` | `09e999a94ac8c45f0500ba781596391c8b79383d0c781c4334d515c4b81f93e3` |
| `classic-fgn-cuda-correction-v1-summary.json` | `2b3bd67c48fa74d0233634ebc4a58075099d700a040f112584927acddfbbdda3` |
| `classic-jfg-cuda-correction-v1-summary.json` | `b24dcf83181535a9e4f461953ce6fb18e681f2dfbdd22fdc722e7dc67bb03f08` |
| `heart-native-deferred-reference-freeze-v3/native-reference-freeze.json` | `88392a6532962fa4fa5124fa88bd19aac0af18ee8bf2d7abfe21c4591503d946` |
| `heart-native-deferred-training-zonal-pair-v1/cohort-run.json` | `3195056001435e18cca3ddc96e6340058fd67493550eed2422eac2befa98bde0` |

The AMD v2 serializer SHA is
`865695c8b4ccf4eef138d0399179e64321319e727d3a5a4dc681f6b8b5c941a1`;
its unchanged original scoring source is
`202d378aa673e7ef1aa0492a1ea09eb0ae69c9f2343e84d9948d5a9235b2023b`.
The Classic serial runner SHA is
`8a5914fd577e4fe953cf2ae7cdfb6b99c65dd08afd20a1ec6e2f8fda14756f8b`;
the native plan driver SHA is
`2e270160d9d45b6643d5c2126f48ac3295974718318160ab0b5e278e37a71e27`.
The native zonal payload SHAs are
`032c0fa1d1572b5ae44a6134da0d838b47f14f253c0b5e864eac3b4a926d75de`
and `991419cd55cde6a7d97e8cd58f123038030ab050975871b77cbfaecbd800c845`;
they are distinct unaccepted training candidates.

Independent review reran the Classic runner's 135 cold assertions, AMD v2's
79 assertions and actual cold score verification, with matching source/lineage/
package seals and no GPU imports or owners. Software checks and actual simulated
acquisition/replay remain separate evidence classes.

The native active-correction checkpoint passes 74 focused assertions in both root
and independent review. The frozen preparation SDK passes its full 909-assertion
suite, including relocation and source-closure checks. Its non-git source snapshot
emits two git provenance diagnostics; the checks still pass and actual file hashes
bind that snapshot. This is software verification, not active correction evidence.
The first public correction export fails before launch because its generated
deployment name exceeds the existing 40-character bound. Its source snapshot and
`native-correction-public-preparation-v1.log` are retained. Scientific admission
had completed. The corrected exporter passes the same name-bound regression and
the fresh public export succeeds. Root independently verifies all 512 artifact
seals in `heart-native-correction-prepared-v2`; its descriptor SHA-256 is
`26c8b0b12ca8a7edc7b1b7c300f33c2549e0828456435c997c16e4a24bac7730`.
Independent actual-package review approves this scoped experiment (audit
`native-active-package-independent-v2.json`, SHA-256
`40b707850a3a1c171d57bbc42173160ba9d4484b5a72cc591c0c91a6f3aa9bbd`).
The first native correction attempt then fails before exposure 1. Its adapter
waits for a standard-DM receipt before acknowledging connection; the launcher
waits for that acknowledgement before creating the RTC links. The retained
native stream contains one initial DM record, while the owner remains at
sequence zero and the RTC host has not been spawned. Independent review confirms
this startup dependency cycle (CCR-024). The failed package, logs, lifecycle and
native snapshot remain preserved; unsuccessful shutdown is not counted as a
passed lifecycle gate. A corrected phase ordering and fresh run are required.

The ordering successor establishes public readiness and a native CORRECT proof,
then fails during exposure 1 because the calibration reader assumes one file
per stream. Native RUN→CORRECT transitions rotate telemetry files (CCR-026).
The active path also needs exact positive DM wire IDs, including the retained
last ID on zero restoration, rather than the held-calibration sequence-zero
contract (CCR-027). The active-only source-v5 successor admits all five empty
headers before publication, retains three declared phases, and checks per-file
counts alongside global bucket/sync counters. Root phase/owner checks pass
27/69 assertions. Independent review passes 214 assertions, including the
original rotated-file counterexample and exact-ID negatives; all 140 frozen
source-copy identities match. The four normal simulator/science helpers and
the held-calibration sources remain unchanged.

The first public export of that successor fails before package publication:
its command points at a nonexistent completion-worktree RTC binary. No package
or live session is created. The canonical binary is verified to match the
previous native package, SHA-256
`490fe9fa67f9f1266fdf7901c5f275eb8065ca885d197e198e1092a17a22f16f`.
The failed invocation/log remain retained; its fresh successor changes only
that prerequisite path. At that checkpoint, actual phase rotation, restoration,
reset and finite correction utility still required a live successor run.

Package5's first attempted launch is rejected before any RTC owners because
the root driver inherits only CPU 15. That failed attempt remains preserved.
The next driver admits CPUs 2–15 so the declared deployment groups can be
applied. It completes 256 exact-sync exchanges, all 15 phase files and zero
restoration at native bucket257/sync256, then correctly fails its stricter
zero-ADC-rail gate. The retained detector data contain the same two saturated
pixel locations as the earlier FGN/JFG normal correction runs. Independent
recurrence analysis finds no sign/gain defect outside conservative Float32
rounding bounds. All six recorded owned PIDs are absent after fallback cleanup;
public shutdown, reset and replay remain false, and the failed result is not
promoted. The [explicit policy alignment](CALIBRATION_COMPLETION_PLAN.md)
requires new source/contract seals and a fresh run. It preserves every detector
sample and the calibration zero-rail rule.

A later frozen SDK checkpoint, `sdk-checkpoint-root-20261004-0730/deployment`,
passes all 1,100 assertions across 51 non-overlapping test summaries, including
the Classic acquisition extension and generated-name regressions present in
that snapshot. The successful log SHA-256 is
`161587846de6b474f6702a7ea62a41fdeff96c843aa7062bf035f037993121bf`.
The initial root shell invocation rejected an incorrectly spaced `taskset`
option before Julia started; its separate log is preserved. This checkpoint
does not qualify subsequent source changes or live scientific operation.

## Native Classic active startup regressions

The first three fresh Classic active packages failed before acquisition. Their
original reports and false lifecycle gates are preserved. CCR-031 concerns an
unconditional Copper flag contract: Classic requires exactly 24 flags and
Copper exactly 13. A shared per-profile validator now checks the exact set;
it does not accept a permissive superset. CCR-032 concerns a hardcoded
`:pwfs_frame` boundary: the unchanged Classic graph exposes `:shwfs_frame`.
The corrected profile-selected boundary passes actual package loading, detector
recording, direct-truth preparation, chronology and reset checks.

The source-v8/package3 live attempt then exposes CCR-033. The public native
runtime renderer intentionally links its configuration files to the sealed
package. Startup proof hashes all inputs successfully, but the Classic sparse
parser rejects the unresolved runtime symlink. Copper already resolves its
corresponding projection path. All five recorded PIDs are absent afterward and
the runtime instance is removed. This attempt retains failed startup and
shutdown gates; no correction utility is inferred from its cold setup checks.

The source-v9 remedy resolves the Classic runtime link and rechecks the resolved
file against the contract's input hash before passing it to the unchanged strict
sparse decoder. Exactly two source files change: the owner and its regression
suite. All 149 other files, including the sparse decoder, original E, inverse,
controller settings and four scientific helpers, remain unchanged.
Copy-proof SHA256:
`1c4fa243b2abaea4d06a06fa8690a9cbab88d3a9feb4eaa04159cf83be620627`.
Independent complete startup-proof tests use the actual public runtime renderer,
sealed package inputs and retained command acknowledgements. The old source
rejects the legitimate link; the corrected path passes. Mutated wire geometry
and changed target bytes still reject. The 9-assertion corrected probe is cold
software evidence, with test doubles only for process liveness and absence of
an outstanding exposure. It does not count as an actual native correction run.

## Native Classic dynamic dropout finding

Fresh source-v9/package4 passes startup, public admission, zero adoption and
CORRECT, then rejects the first exchange as an invalid whole-frame response.
Its lifecycle SHA256 is
`08701d641d6879994b08efc232ce77ea5c37f9a39e449c52d1df974876e02604`.
All six recorded PIDs are absent and the runtime instance is removed. The
original public shutdown and correction gates remain false.

Independent decoding finds two enabled subapertures with state 0 and flux
947.1875/989 below the sealed 1,000 threshold; all other 182 enabled regions
have state 1. The four permanent inactive regions remain state −1 with zero
slopes. Native reconstruction correctly excludes the two dynamic dropouts.
Its first VDM agrees with gain −0.3 times the accepted matrix and state-masked
slopes within 6.16 × 10⁻⁸ µm; using unmasked raw slopes differs by 0.02585635 µm.
FGN/JFG likewise emit zero measurement contributions for invalid regions.
Independent report `ccr034-independent-decode.json` has SHA256
`42367bcf457b1037d094604fbf85db353aa098e9c3014a545742d9cff526abd8`.

The [explicit normal-response policy](CALIBRATION_COMPLETION_PLAN.md#classic-normal-subaperture-status-policy)
corrects this adapter-level whole-frame requirement. It preserves raw values,
validity states, thresholds and all scientific coefficients. Calibration still
requires valid eligible probe responses. A fresh complete run and independently
recomputed dropout diagnostics are required; this failed exposure is not
promoted into successful correction evidence.

## Native Classic normal correction accepted

Fresh `heart-native-classic-correction-prepared-v5` binds the accepted inverse,
operational background/reference/fixed mask, original native sparse E and
unchanged flux thresholds. All 528 artifact seals pass. Descriptor SHA256:
`dbc593bd690bdf3d4da8c1f19ddf160b40a911a3fcb07eb2ab7373c1cfe5fc71`.
The root-owned `native-classic-correction-active-v5-evidence` run exits zero.
Both 256-frame batches, public stop/reset/start, zero restoration, public
shutdown and both actual CUDA ADC/live-truth/zero-command replays pass. ADC,
commands and truth reproduce exactly after the new native generation. All
seven recorded supervisor, owner and native-generation PIDs are absent, and
the runtime instance is removed. Lifecycle SHA256:
`334d893155e4442b4e638ea13efb1735c59b1b8812e95f4b840c88367a32fe39`.

Each batch retains 256 raw WFS frames, 256 gradient records, 256 VDM records and
258 DM records, including startup and restoration zero. The residual/zero
variance ratios are 0.0442815144 and 0.0344010802 in the two predeclared windows.
Independent physical-demand reconstruction excludes DM limiting; maximum
absolute command is 0.3789594 µm OPD. Every recorded ADC matches replay;
maximum ADC is 449 against rail 4,095, with no upper-rail pixels.

Normal response diagnostics retain 236 dropout frames and 544 below-threshold
subaperture samples per batch, with eight affected regions. The raw validity,
flux and slopes remain present; no frames are discarded or relabelled valid.
Per-region counts and state/threshold consistency are verified from retained
native records. These results support finite correction utility with classified
dropouts; they do not establish an instrument dropout tolerance or unsaturated
calibration precision. The strict valid-probe calibration policy is unchanged.

Analysis SHA256 values are
`565e6680f691f0db805f1d33aa80dc1ae77468ea85768149d70a37e75f49ea60`
and `eab83f9ff7e17c61de102425b559ecb8f7f94f4d29d4d7476bbb7e430a96da77`.
Independent final audit verifies 1,573 files and passes 36 retained-verifier
assertions plus an exact-truth assertion. Audit SHA256:
`2550220c39a78c08b5f9953eef459068f523fe80ddce367d519997530c56a094`.
Native recurrence agrees within 6.16 × 10⁻⁸ µm and sparse E projection within
2.47 × 10⁻⁷ µm; the relayed metre commands match exactly. Final acceptance
and scope are recorded in the [review](CALIBRATION_COMPLETION_REVIEW.md).
Earlier failed Classic reports
remain failed and unchanged.

## Completed selected gates and qualification limits

The five selected finite simulation steps have actual retained evidence:
illumination/probe characterization, repeated matched matrices and method cost,
held-out method selection, coordinate/inverse composition and deployed
correction, and unchanged selected HEART plus available accelerator simulation.
The [plan table](CALIBRATION_COMPLETION_PLAN.md#five-steps-and-existing-evidence)
and independent review specify the qualified cohorts and partial spatial spans.

Separate work remains: ordinary native Copper streaming CCR-017; the generic
PipeWireAO private-core loan-exhaustion timeout CCR-006; physical endpoints,
instrument-specific tolerances and DU860 electronics; wall-clock cadence,
progressive latency and full engine/backend configuration coverage. Accelerator
labels here describe the AOS simulator backend, not accelerator execution of
the RTC graphs. Completion-driven exchanges do not demonstrate 500 Hz or
1 kHz wall-clock operation.
