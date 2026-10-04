# Copper bounded precision and amplitude pilot review

## Scope and review baseline

Independent design review in `pipewireao-rtc-copper-quality`, branch based on
`5565d6e42660e500c7c1e25b598a49ac85a38af8`. The worktree was clean at initial
inspection. The reviewer owns only this document; the parent owns acquisition,
implementation adjudication and integration. No live session or production
change was performed for this review.

This increment characterizes one physical command direction using the existing
Copper CPU normal-noise 64×64, 14-bit detector fixture, measured background and
lamp magnitude 5.752574989159953. It retains the full absolute 3,600-component
normalized response, without reference subtraction, gain tuning or optical
truth as estimator input. The prior eight-frame reference residual of roughly
8.9% was descriptive and is not an accepted precision target.

Authorities are active RTC-ARCH-023 / RTC-DEV-029 and the existing Copper capture
and reference contracts. The recorded-FITS UI counter-cache failure is a separate
functional observer issue, not evidence that event-gated calibration stalls.

## CQR-1 — Declare the actual physical direction and amplitude

**Severity/confidence:** Required coordinate contract; high confidence from source.
**Disposition:** Design acceptable with explicit labeling and representation checks.

The frozen `COPPER_QUALITY_PLAN.md` selects physical actuator **139**,
one-based in the maintained 277-coordinate command order.
`REVOLTCopperSim/src/hsdm277.jl` maps it to source row 10, column 10 and
provisional normalized pupil coordinates (0, 0), the geometric center. The
initial discussion proposed 143, which is at (0.5, 0); the parent changed the
selection to 139 before policy freeze or acquisition. This review follows that
explicit correction. Neither coordinate is a measured instrument registration.
The pilot does not characterize all actuator positions or weak/obscured modes;
a weak central response must remain a measured outcome, not trigger an
unrecorded actuator substitution.

Every non-null command must equal the frozen zero reference plus or minus the
actual Float32 amplitude at coordinate 139; the other 276 entries remain zero.
Bind ordered requested and adopted vectors, require exact wire equality and
`clipped=false`, and preserve absolute µm OPD units (adapter model units are m
OPD). Reject underflowed/nonfinite commands or a lost signed perturbation before
launch. Record actual widened Float32 amplitudes, not only decimal labels:

| Label, µm OPD | Actual Float32 widened to Float64 |
| --- | ---: |
| 0.02 | 0.019999999552965164 |
| 0.04 | 0.03999999910593033 |
| 0.08 | 0.07999999821186066 |

Use these represented amplitudes in the derivative denominator. A result with
one column is the finite-amplitude directional derivative for physical 139,
not an identified 277-column matrix or the 253-coordinate controller operator.

## CQR-2 — What the proposed two-traversal sequence can distinguish

**Severity/confidence:** Scientific inference boundary; high confidence.
**Disposition:** Permit descriptive pilot; no causal linearity or precision acceptance.

The frozen order is:

```text
repeat 1: null, +.02, −.02, +.04, −.04, +.08, −.08, null
repeat 2: null, −.08, +.08, −.04, +.04, −.02, +.02, null
```

Each entry captures eight samples after its own discarded settling exposure.
This balances overall sign ordering and amplitude traversal, but changes sign
order, traversal, prior command history and elapsed time together. With only
two realizations, their differences must be called repeat/order discrepancies.
They are not a pure-noise bound, a standard error, a Gaussian confidence interval
or a separated measurement of causal nonlinearity. Two same-seed engine runs
are implementation comparisons, not two statistically independent repeats.

After validating all chronological receipts, associate positive/negative means
by their declared labels. For repeat r and represented amplitude a:

```text
dᵣ(a) = (μᵣ,+ − μᵣ,−) / (2a)       normalized pixel / µm OPD
mᵣ(a) = (μᵣ,+ + μᵣ,−) / 2          normalized pixel
o(a)  = d₁(a) − d₂(a)               repeat/order discrepancy
```

Use public `RepeatedResponseMoments` on 3,600×8 per-batch arrays, retaining
Float64 mean/sample variance. Pass each correctly ordered positive/negative
mean pair to public `InteractionMatrices.ZonalPushPull` with one declared
coordinate and a Float64 amplitude widened from the actual Float32 command.
Its response input has two rows × 3,600 measurements; result is 3,600×1.
Require the public valid status. Avoid an unnecessary intermediate Float32
mean rounding before differencing.

Report per-repeat derivative norms, pairwise amplitude differences, dot products
and cosine only when both norms are positive; a zero norm yields an explicit
undefined value. Preserve each derivative, not only the average or cosine.
Compare pair midpoints with both bracketing null means and report null-to-null
changes. These are even-response/drift diagnostics, not a drift-corrected
estimator or evidence that all even response is physical nonlinearity. Retain
per-frame intensity and first-versus-later sample diagnostics without changing
which samples enter the declared mean.

Do not infer usable rank, global linearity or absence of bias from agreement
within a total-vector variance estimate. If this pilot shows a coherent
amplitude association, the smallest next discriminating experiment is a
separately frozen local opposite-order quartet (ABBA/BAAB) at the implicated
amplitudes, with local null brackets and additional independent detector seed.
That is future adjudicated work, not an automatic expansion of this acquisition.

## CQR-3 — Normalization history and eligibility

**Severity/confidence:** Association requirement; confirmed source behavior.
**Disposition:** Existing minimum settling applies; additional physical settling is unproven.

The deployed FGA `pyramid_pupil_image.jl` stages the current intensity reciprocal
but forms the present output using `reciprocal_previous_frame_mean`. Completing
one discarded exposure after every adoption primes the previous-frame state
from that same held command when its numerical processing succeeds. It does not eliminate noise
correlation, temporal drift or other unmeasured plant settling. In particular,
within-batch variance divided by eight is not established as the true variance
of that batch mean. Preserve intrinsic validity and previous-history context.

Every retained batch, including nulls, must pass the declared finite lamp/intensity
and ADC rail checks. Existing `settle!` acquires with `require_valid=false` and
returns a cursor without discarded-frame validity. This is intentional for dark
acquisition. The pilot must not claim that discarded intensity was independently
validated. First-versus-later retained-frame diagnostics can expose an anomaly;
no new global settling policy or protocol extension is required for the bounded
descriptive pilot. Do not silently drop
retained invalid samples, tune thresholds or normalize by average intensity.
Only the measured background is adopted for this pilot; the prior frozen
reference remains evidence, not a newly subtracted science parameter.

## CQR-4 — Bounded multi-batch lifecycle and identity requirements

**Severity/confidence:** Required orchestration contract; high confidence.
**Disposition:** Implementation and bounded installed FGN/JFG pilot verified; see final audit below.

Sixteen batches × eight retained exposures produce 128 captures. With one
completed discarded exposure per adoption and one final restoration exposure,
the successful sequence has 145 model exposures in total. The full capture
payload budget is 128 × 22,596 = 2,892,288 bytes, reserved cumulatively. The
small completion descriptors retain the 64 KiB reply bound; this is not a
128-frame `collect` JSON request. Capture paths/manifests must remain distinct
for each operation and preserve the fixed three-channel Copper formats.

For batch i (one-based), expected settling sequence is 9(i−1)+1 and retained
sequences are 9(i−1)+2 through 9i. Final capture ends at 144; fresh restoration
ends at 145. Record actual model times separately from wall time. One live
session per engine preserves the same generation/domain, with monotonically
increasing operation serials and declared probe IDs 0–15. Verify UUID mapping,
settings, probe, cursor and chronology before label-based numerical permutation.
The restoration target is the original zero reference, not merely the final
probe value. Default single-batch behavior must retain its existing contract.

The extension must keep one request in flight, finite operation and stage
budgets, no retry after unknown effects, and the existing fail-stop/restoration
rules. Each successful batch completion must be copied and validated before
its owned storage can be reused. Any failed batch prevents a complete pilot
claim while preserving partial evidence; transport failure must not reuse a
failed adapter. Restore/release and public shutdown remain required before
cold numerical reduction or reported completion.

Freeze the measured-background producer report and bytes, original base/source
inventories, actual Float32 commands and ordered batch labels before launch.
Across engines compare actual raw payloads before attributing output agreement
or differences to processing; shared seed 444 alone is insufficient evidence.
All settings and scientific sources except the declared detector seed and
background remain bound to the qualified reference fixture.

## Initial adjudication

No new numerical algorithm is needed. The proposed bounded pilot is useful
with the stated directional, history and statistical limitations. The parent corrected the selected coordinate to 139 in the plan before
policy freeze. Source verification must
still establish cumulative multi-batch capacity, actual probe/serial binding,
declared settling behavior, lifecycle failure behavior and public AOC association before
live clearance. Actual installed results require a separate final audit. No
full interaction matrix, inverse, correction, detector/gain change, HEART action,
GPU or physical qualification is approved by this design review.

## CQR-5 — Completed batch payloads on a later failure

**Severity/confidence:** Moderate evidence-preservation defect; confirmed from source.
**Disposition:** Closed by source repair and focused regression verification; successful-run mathematics is unaffected.

In the initial multi-batch implementation, `run_stage` appends each successful
capture completion to the durable result but copies `instance/captured` only
after all batches, restoration and release succeed. A later rejected adoption
or capture bypasses that copy. The exception path retains requests and capture
descriptors, then terminates the owned deployment; `deploy.py` removes its
owned runtime directory in its final cleanup. Consequently, earlier completed
raw and WFS payloads are lost while their descriptors survive. The initial
partial-failure fixture checks descriptors and recovery, not payload survival.

This cannot make a failed pilot pass: the original exception remains fatal and
the campaign is incomplete. It does limit reproducibility of an aborted pilot.
If partial evidence includes completed payloads, preserve and validate each
completed operation's immutable directory before proceeding, or preserve those
completed directories in the failure path before cleanup. Do not copy an
unacknowledged operation or turn recovery into a successful campaign. Required
verification is the same later-rejection fixture with a real prior payload,
normal runtime removal, and a surviving byte-identical evidence copy.

## Implementation review in progress

The inspected cold helper validates chronological request/reply serials, probes,
full acquisition-domain mapping, generation, exposure duration, payload shape
and SHA before label-based association. Its public zonal estimate uses half
the actual widened Float32 positive-minus-negative command interval. This also
handles asymmetric rounding about a nonzero reference without assuming the
nominal recipe amplitude survived unchanged. ROW_MAJOR products place
measurements last and preserve every retained sample in the declared mean.

The inspected orchestration bounds the cumulative payload reservation and one
request in flight, freezes producer reports and measured products, and retains
the original reference restoration target. No additional blocking mathematical
issue was found in this initial source pass. Final source identities, completed
negative tests, and independent installed evidence remain required; this entry
is not live clearance.

### CQR-5 repair verification

The repaired batched path copies only the acknowledged operation's numbered
directory into durable evidence and calls the existing descriptor/payload
verifier before the next probe. Later failure retains those bytes and the
original failure; recovery still restores the original reference only when
the endpoint permits it. The single-batch path retains its prior copy point.

The reviewer independently ran
`taskset -c 5 python3 -m unittest test_calibration_campaign test_copper_quality -v`
from `deployment`: all 24 tests passed. The later-rejection fixture verifies
a surviving 14,400-byte pixels file and matching SHA, known-outcome restoration
and release, and an incomplete shutdown result. Its mocked process does not
remove the runtime directory; source inspection establishes that the preserved
copy is outside the real launcher's removed runtime tree. The parent subsequently ran this same fixture against a cache-only
reconstruction that moves the new per-batch copy back after the full sequence:
`cqr5-fail-before.log` records the missing preserved pixels file, and
`cqr5-pass-after.log` passes with current source. The reviewer inspected both
logs and the loader. This is a discriminating reconstruction of the former
copy order, not an exact historical commit or a captured live failure. The
fixture, reconstructed source and logs are retained under
`~/.cache/rtc-copper-quality-20261003/`.

Python report admission now checks the declared profile, status, public methods,
scope, selected actuator, sample count, executed helper SHA, chronological
probe labels, and complete input hash mapping. It admits exactly four numerical
products with the declared shapes, ROW_MAJOR Float64 representation, units,
byte counts and SHA values. The focused tests reject changed report status,
recipe identity and product bytes. The frozen helper remains responsible for
numerical validity and complete lifecycle verification before publication.

Reviewed Python identities:

| File | SHA-256 |
| --- | --- |
| `deployment/calibration_campaign.py` | `61c3019c5d2a7780524141893a392ca60e23d55f5c95e96a3279317d41402997` |
| `deployment/copper_quality.py` | `b3c8cdb06e2b15a21cf8b0ef14c17519c0142760299af1f48cc5c871a93b74ca` |
| `deployment/test_calibration_campaign.py` | `9a549caa57323b9db66428e4c01da79abb456fce597303d9d2618d270b91d2e1` |
| `deployment/test_copper_quality.py` | `51353b541313dd96119b5dc39428589189d72b9444dbc03b39de63e0bfdc5766` |

No Python implementation blocker remains at these identities. Final Julia
verification and actual installed evidence are still pending.

## CQR-6 — Parsed integer values and JSON spelling

**Severity/confidence:** Rejected lexical test policy; confirmed parser behavior.
**Disposition:** No custom parser required; parsed-value guards retained.

The additional six mutation fixtures initially expected JSON spellings such as
`1.0` to remain floating values. The existing JSON3 reader normalizes integral
numbers to integer values, so these fixtures produced 18 assertion failures
without demonstrating a changed identity, extent or mathematical association.
The original log and sources remain under the cache's `cqr6-*` files. They must
not be presented as fail-before evidence of a scientific association defect.

RTC-DEV-029 requires integer identity/model-time fields. The inspected active
contract does not impose a separate lexical spelling requirement on this cold
analysis helper. The operational Python/endpoint path enforces its existing
metadata checks before numerical reduction, and capture files are bound by
SHA. The reviewer agrees with the parent's decision to retain the established
JSON3 reader. Explicit parsed-integer checks now cover shape extents, startup
cursors, request after-cursors, retained settling cursors and settling rules.
Nonintegral mutations and Boolean values remain invalid. A custom RawValue
parser would add an unnecessary separate parsing contract to this increment.

## Final prelaunch implementation disposition

**Cleared for the declared bounded FGN/JFG CPU pilot:** physical coordinate
139, eight samples per batch, sixteen ordered batches, zero original reference,
one completed discarded exposure per adoption, and the frozen ordinary noisy
detector/background/lamp settings. No production or live change was performed
by this reviewer. This disposition does not assert a successful acquisition
or scientific acceptance.

Final Julia identities inspected:

| File | SHA-256 |
| --- | --- |
| `deployment/hil/calibration_quality_analysis.jl` | `813c4355c423dcfc310ce39df19f3a6db646eb2a5c65c99f9fbb247d1ffd6fb2` |
| `deployment/hil/test_calibration_quality_analysis.jl` | `1ebb2474f9136574c1fcab6dcdcbafbaf6aa8baef5d34f235a34701a36a9cd11` |
| `deployment/copper_quality.py` | `ee86b28eec8c3a557a58ccb8978e657aa909acfea18772f212f3210d52e79d52` |
| `deployment/test_copper_quality.py` | `a68d394bff580181cbc689068be88840693b42d738c4095fd17f7289e05b539b` |

The last two rows supersede the earlier Python identities after stricter report
field guards. Acquisition source and its tests retain the identities above.
The reviewer reran all six final quality Python tests successfully. The final
Julia source and tests were read independently; the worker's completed exit-0
log `julia-quality-tests.log` records 230 assertions across three sets
(65, 60 and 105). Its command used CPU 6, `--startup-file=no`, and the prior
FGN reference candidate's packaged HIL project. It was a portable software
fixture run, not an installed transport or timing check.

The mathematics preserves actual Float32 commands, Float64 moments, unbiased
sample variance and signed finite-interval estimates through public AOC APIs.
Receipts and complete exposure identities precede numerical association;
invalid retained lamp samples, ADC rail hits, mismatched producer bytes and
incomplete lifecycle prevent publication. The frozen reference enters only
diagnostic comparisons. Settling validity, temporal independence, linearity,
precision acceptance, full-matrix rank and correction remain unproven.

Reported acquisition wall time includes hold/adopt/settle/capture, durable
copy/verification, restoration and release. It is not a separately measured
per-operation timing breakdown or a cadence claim. The final installed audit
must check all 128 payload sets, chronology through retained sequence 144 and
fresh restoration 145, actual engine input equality, source/package identities
and completed public shutdown before interpreting paired numerical reports.

## CQR-7 — First installed FGN result and next discriminator

**Severity/confidence:** Scientific inference boundary; installed observations and
independent numerical recomputation.
**Disposition:** Both engines passed the bounded functional and numerical audit
below. Precision/linearity acceptance remains open. No full-matrix admission follows.

The reviewer independently inspected
`~/.cache/rtc-copper-quality-20261003/fgn-pilot`: 1,808 frozen source identities,
395 sealed files, 379 deployment artifacts, all 51 correlated request/reply
records and 128 three-channel payload sets passed the checks. Requested and
adopted commands agree in their Float32 wire representation. JSON decimal
spellings can differ while encoding that same command; decimal-string or
Float64 equality is not the wire contract. Captures follow the declared sixteen
settling boundaries through sequence 144; fresh restoration completes at 145.
Restore/release/shutdown flags are true, launcher exit is zero, and the owned
runtime and recorded child PIDs are absent.

Independent NumPy reduction from actual packed Float32 pixels reproduces all
four products. Maximum absolute differences from the public-AOC products are
1.11 × 10⁻¹⁶ for means, 8.33 × 10⁻¹⁷ for unbiased variance, 2.67 × 10⁻¹⁵ for
derivative repeats, and 1.78 × 10⁻¹⁵ for derivative means. No retained ADC value
reaches the 14-bit rail: observed maximum is 66. Retained intensities range
from 26.8698272705 to 27.3523273468.

| Nominal amplitude, µm OPD | Repeat cosine | Relative repeat discrepancy | Response-space discrepancy, (2a)‖d₂−d₁‖₂ |
| ---: | ---: | ---: | ---: |
| 0.02 | 0.0467938 | 1.4121781 | 8.4586 |
| 0.04 | 0.1658959 | 1.2930059 | 8.5020 |
| 0.08 | 0.4377758 | 1.0752852 | 8.5181 |

All denominators use the actual represented amplitudes. Null-batch mean
differences have RMS 0.098311–0.101209 across 3,600 components. Multiplying their
vector norms by √2 gives roughly 8.34–8.59, spanning the signed-pair
response-space discrepancies above. This is consistent with substantial
response dispersion producing the observed inverse-amplitude derivative
discrepancy. Interpreting √2 as a statistical prediction would additionally
require covariance/independence assumptions that this pilot has not established.
These observations do not isolate a causal noise mechanism, establish
linearity, or justify a full interaction matrix.

The smallest useful new illumination discriminator is a separately frozen
one-amplitude (0.04 µm OPD), N8 pilot with opposite sign orders and null brackets:
eight batches, 64 retained samples, a fresh declared detector seed, and an
explicit tenfold calibration-lamp photon-rate setting (magnitude
3.252574989159953). Keep detector gain, background, settling and all other science
settings unchanged. Compare actual achieved intensity, response-space repeat
and null dispersion, directional mean, and first-versus-later samples. Retain
ADC rail checks; the current maximum demonstrates headroom at the measured
setting, not a guarantee for arbitrary brightness increases. This proposal
tests illumination association and avoids increasing probe amplitude; it does
not define an acceptance threshold. If lamp changes are deferred, the
same-setting N16 pilot is the conservative alternative, with any √2 reduction
in mean dispersion treated as a hypothesis to measure. Neither experiment is
authorized or performed by this review.

## Final installed paired audit

**Disposition:** The declared bounded pilot is complete and review-cleared.
No remaining code or evidence blocker was found for merging this increment.
Scientific precision/linearity acceptance and full interaction calibration
remain outside that completion claim.

The reviewer independently audited `jfg-pilot` after its files were finalized:
2,066 frozen source identities, 522 sealed files and 506 deployment artifacts
match their recorded hashes. All 51 request/reply records have the declared
serials and run identity. All sixteen requested/adopted figures match their
frozen Float32 commands without clipping. The 128 retained exposures have the
correct full-domain mapping, generation, sequences, 2 ms duration and 100 ms
model cadence, with the declared discarded exposures between batches. Fresh
restoration completes at sequence 145; public restore/release/shutdown complete,
launcher exit is zero, and recorded owned PIDs and runtime are absent.

Direct byte comparison, independent of shared-seed assumptions, confirms all
384 raw/pixels/intensity files are identical between the 128 paired FGN/JFG
exposures. All four published Float64 numerical products are also byte-identical.
Independent reduction from JFG's actual packed input reproduces the same
roundoff differences reported above for FGN. This establishes agreement for
the measured corpus; it does not turn the two engine runs into independent
statistical realizations or qualify other command directions.

Final JFG `quality-result.json` SHA-256:
`6b764cace3d53b69f5fc28fcdf522e444efe10bbe7e476656aae90bf9c65c4c3`.
Its analysis report SHA-256:
`cf2a5a7e79116e620883c3dbc27b3d7f250b326cf20b513f544017f290facd92`.
The parent's paired independent audit additionally checks 378 scalar report
metrics per run and is preserved as `paired-independent-audit.json`, SHA-256
`5a347ed383f34049b7ab4d9ee97b4137e98d8b1aead518cd541b050242089969`.
The reviewer separately recomputed all four arrays and the principal derivative
and null-discrepancy quantities; these checks are distinct from the parent's
complete scalar-metric audit.

| Observed wall-time phase, seconds | FGN | JFG |
| --- | ---: | ---: |
| Startup readiness | 45.4634 | 77.6473 |
| Composite acquisition and storage | 51.2551 | 50.5340 |
| Public shutdown | 1.0582 | 1.2528 |
| Total live stage | 97.7769 | 129.4344 |

These are single observed workflow costs including cold/runtime overhead. They
are not frame-rate, tail-latency or real-time qualifications. Both engines share
the large repeat/order discrepancy established above; byte-level processing
agreement does not resolve that scientific limitation. Any brighter-lamp or
longer-average discriminator requires a separately frozen new experiment.

### Final validation and ledger audit

Implementation commit `5cf8182` preserves the reviewed source identities. The
reviewer read `COPPER_QUALITY_VALIDATION.md` and independently checked all
91 unique immutable-cache ledger entries for file size and SHA-256. Every entry
matched; ledger SHA-256 at this audit is
`c39eeb8cfd1acf9844284b9bcc613afa6ab7524ebad8b8b8f8501e6bb7b45f47`.
Recorded source copies and packaged helpers preserve the qualified implementation
independently of the dedicated worktree. Declared numerical results and wall
costs match the audited immutable run records. No claim or numerical blocker
was found for integration of the validation documents.

The suggested brighter-lamp experiment is future work. The current maintained
CLI explicitly requires lamp magnitude to match the producing reference
candidate and rejects changing only that recipe field. Running the proposed
illumination discriminator therefore requires a matching new producer candidate
or a separately reviewed, explicit contract increment; it is not an already
implemented option for the existing candidate. No gain, detector or active
calibration change follows from the completed pilot.
