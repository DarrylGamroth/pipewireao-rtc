# Fresh Classic method and reconstructor selection

## Scope and starting evidence

The finite Classic CPU baseline inverse retains 186 TSVD modes and has passed
held-out response and deployed FGN/JFG correction checks. The subsequent
selectable method sweeps are characterized in
[method measurements](CALIBRATION_METHOD_VALIDATION.md). Their retained
controller corpus has been examined descriptively and will not be reused as an
independent test for the new decision. This increment extends RTC-ARCH-023 and
RTC-DEV-029 using the same normal deployed noisy detector and completion-driven
DM/WFS acquisition. No instrument threshold or physical acceptance is inferred.

Starting RTC main revision: `110b99a`; AOC: `f79104d`. Work remains isolated in
`pipewireao-rtc-calibration-quality`. Preparation and analysis are cold cache
experiments; no new production estimator API is implied by this comparison.

## Declared candidates and equations

Compare the fixed qualified baseline inverse with new mean-matrix TSVD
candidates from complete Hadamard, physical zonal N16 and controller-modal
calibrations. Each new family uses cutoff multipliers 1, 2 and 4 of its own
empirical **controller-task spectral** repeat/order discrepancy. Public AOC
constructs inverses. Retain 221×376 ROW_MAJOR Float32 deployment payloads;
inactive measurement columns are zero. Evaluate the packed Float32 values.
The baseline's cutoff and payload remain fixed.

Physical families predict `S D Q_actual`; controller-modal predicts
`S G L U` with original Float64 controller coordinates and recorded actual
Float32 command representation residuals. Neither calibration truth nor a
physical-matrix rounding correction enters the modal prediction. Inverse loss
compares `B R z` against actual physical command Q, where
`z = (y_plus − y_minus) / 2`. Signed-pair repeats are kept separate. Bracketing
null references are audited separately and are not subtracted from z.

The measured 64-mode spatial matrix is excluded from this complete controller
candidate set because it does not identify all 221 controller coordinates.
Its span-specific prediction evidence remains preserved.


An independent pre-response spectral check gives the following declared ranks.
These are candidate characteristics, not response acceptance or selection.

| Family | Empirical controller spectral scale | Modes at 1× / 2× / 4× cutoff |
| --- | ---: | ---: |
| Hadamard | 0.98450 | 206 / 181 / 136 |
| Zonal N16 | 3.96002 | 139 / 36 / 0 |
| Controller-modal | 3.13116 | 160 / 73 / 0 |

The spectral scale has units pixel/µm OPD. Both zero-mode settings remain in
the declared candidate set and are ineligible; no cutoff is lowered to replace
them. The fixed baseline retains 186 modes.

## Fresh corpora and frozen decision

Before any new response acquisition, generate both corpus declarations:

| Corpus | Sparse controller coordinates | Mixed directions | Direction seed | Detector seed/run | Accepted exposures | Total model exposures |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Validation | 19, 78, 137, 201 | 4 | 1001 | 97 | 3,072 | 3,121 |
| Locked test | 15, 45, 72, 97, 124, 158, 184, 218 | 8 | 1002 | 98 | 6,144 | 6,241 |

Coordinates are one-based. Each direction has one ABBA/BAAB signed quartet and
two bracketing null batches, with 64 accepted exposures and one discarded
settling exposure per batch. Physical peaks 0.02/0.04 µm OPD are distributed
across different directions as declared; this is not a paired amplitude test.
Mixed directions are dense independent Rademacher controller vectors normalized
through exact B to the physical peak. Detector settings, measured offsets,
mask, lamp, plant and command maps remain unchanged apart from declared seeds.

Eligibility requires nonzero retained rank, finite values and strictly lower
forward and inverse losses than zero prediction in **both** signed-pair repeats
for **each** sparse/mixed group. Among eligible candidates choose minimum
worst-repeat physical-command mean squared loss pooled over all directions.
Exact ties prefer the fixed baseline, then the larger cutoff multiplier, then
lexical family name. Report every validation score, not just the winner.

A preparation policy binds previous reports, maps, source identities and both
fresh corpus declarations. Candidate preparation must not read the new response
files. A second acquisition policy freezes the prepared candidate report and
payload/source identities before the first validation launch. Selection then
binds that policy, validation evidence and exact chosen payload. Before locked
acquisition, a separate launch receipt freezes the selection hash and locked
input identities. The locked analyzer evaluates only that choice. A failure
retains the report and does not permit retuning against the locked outcomes.

## Validation and acceptance boundary

Validate recipes, actual figures, exact accepted identities, settled association,
canonical ordering, unchanged preparation/source inputs and complete
restoration/release/shutdown before numerical admission. Synthetic tests cover
spectral norms, coordinate representation, packed evaluation, subgroup eligibility,
tie ordering and identity failures. An independent review precedes acquisition
and verifies significant numerical results afterward.

A locked-test pass supports finite-corpus response utility. Deployed correction
at unchanged settings is a subsequent gate; the existing baseline remains the
active qualified artifact until that gate passes. Copper, unchanged HEART,
accelerator calibration, instrument acceptance and wall-cadence qualification
remain separate work.

## Observed validation and locked-test results

The frozen preparation generated all ten candidates before acquiring new
responses. Independent SVD recomputation reproduced the declared ranks and
packed payloads. Preparation initially treated the command-map inventory's
`invariants` metadata as a map filename and stopped before acquisition. The
fix restricts map admission to the six declared names; a regression reproduces
the original failure and checks metadata and payload tampering. The final
analyzer passed 78 focused assertions, including an independent bounds-enabled
run. Failed preparation logs remain in the evidence record.

All 3,072 validation and 6,144 locked accepted exposures have unique exact
completion receipts. Restoration, release and shutdown completed for both
acquisitions. The locked launch receipt bound the selection and locked input
identities before launch. Only the selected candidate was scored on the locked
corpus; no coefficients, cutoffs, gains or eligibility rules were changed.

| Validation candidate | Retained modes | Worst-repeat pooled physical-command squared error (µm²) | Eligible |
| --- | ---: | ---: | --- |
| Fixed baseline | 186 | 0.018856 | Yes |
| Hadamard, 1× | 206 | **0.008168** | Yes; selected |
| Hadamard, 2× | 181 | 0.021930 | Yes |
| Hadamard, 4× | 136 | 0.042180 | Yes |
| Zonal N16, 1× | 139 | 0.043188 | Yes |
| Zonal N16, 2× | 36 | 0.094877 | Yes |
| Zonal N16, 4× | 0 | 0.108320 | No |
| Controller-modal, 1× | 160 | 0.034741 | Yes |
| Controller-modal, 2× | 73 | 0.075867 | Yes |
| Controller-modal, 4× | 0 | 0.108320 | No |

This loss is the mean over directions of the **sum** of squared physical
coordinate errors, not the mean per actuator. It is not the normalized subgroup
loss used for eligibility. Eight candidates were eligible. The chosen payload
is the packed Float32 Hadamard 206-mode inverse with SHA-256
`bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813`.

| Selected-only locked quantity | Signed-pair repeat 1 | Signed-pair repeat 2 |
| --- | ---: | ---: |
| Pooled physical-command squared error (µm²) | 0.008309 | 0.008346 |
| Sparse inverse normalized squared error | 0.118184 | 0.110008 |
| Mixed inverse normalized squared error | 0.070767 | 0.071135 |
| Sparse forward normalized squared error | 0.040782 | 0.040876 |
| Mixed forward normalized squared error | 0.006002 | 0.006061 |

Independent recomputation reproduced validation arithmetic within 3.56×10⁻¹⁵
and locked arithmetic within 1.43×10⁻¹⁴. These are finite-corpus software and
simulation observations, not instrument acceptance bounds or confidence
intervals. The Hadamard acquisition spent 16× the integrated squared command
energy of the compared zonal settings; this selection does not establish an
intrinsic equal-energy advantage of the method.

| Stage | Startup wall time | Acquisition wall time | Shutdown wall time |
| --- | ---: | ---: | ---: |
| Fresh validation | 41.219 s | 51.847 s | 1.003 s |
| Locked test | 41.346 s | 94.209 s | 1.056 s |

Startup includes compilation/loading. The model period is 2 ms; these wall
measurements do not qualify 500 Hz execution. Acquisition-time and source
identities, full-precision scores, every receipt and the frozen decision policies
are retained in [the evidence ledger](CALIBRATION_QUALITY_EVIDENCE.json).

## Correction package admission

Both staged correction packages keep the qualified graph bytes, measured
backgrounds/references/mask, command maps, plant, detector and controller
settings. Only the inverse changes. Integrator gain −0.3, pole 0.99, antiwindup
0.99 and the ±0.8 µm OPD limit remain fixed. Independent review checked all
387 FGN and 517 JFG deployment artifact hashes, all startup parameters and the
complete scientific source trees. Both use the previously qualified live OPD
witness, solely for correction diagnostics.

The first staging attempt correctly rejected a JFG raw configuration mismatch:
the staging script selected the FGN campaign for both engines. The engine-matched
FGN/JFG campaigns have byte-identical measured products and recipes, and the
successful second staging preserves each qualified engine's constructor
snapshot. No import guard was bypassed. Two subsequent check invocations stopped
before RTC launch because the deployment argument was respectively a directory
and a nonexistent `.json` filename. The corrected invocation uses the exported
`deployment.conf`. All failed logs remain preserved.

## Deployed correction and shared-input agreement

Both new packages passed two 256-frame non-actuating live batches through
`check_hil.py`: exact ordered delivery, admission hold, mid-batch pause/resume,
rejected reset while running, stopped reset/restart and clean shutdown. Each
engine reproduced its ADC payload, adopted command payload and entire live
truth dictionary exactly after reset. All owned processes exited zero.
Observed placement excludes CPU 0/1 and retains the qualified RTC/Julia FIFO
threads. No platform policy or controller tuning changed.

| Live correction observation | FGN | JFG |
| --- | ---: | ---: |
| Residual / zero-command variance, frames 17:128 | 0.0291463 | 0.0291775 |
| Residual / zero-command variance, frames 129:256 | 0.0451180 | 0.0448490 |
| Peak adopted demand (µm OPD) | 0.425748 | 0.432245 |
| Adopted components at limit | 0 | 0 |
| Completed exposures / commands per batch | 256 / 256 | 256 / 256 |

The declared piston-removed population variance uses the same public annular
pupil and model timestamps as the zero-command diagnostic. Both fixed windows
pass the predeclared ratio < 1 correction gate. The live OPD witness and
zero-command baseline verify exactly for both engines. FGN's replayed detector
ADC also matches exactly. JFG's replay differs at 18 pixels in five frames;
its exact live witness is the verification basis. This remaining replay
mechanism is unattributed, and no ADC-exact or defect-resolution claim is made.
The final command's effect is outside the retained exposure sequence.

A separate ordinary-array **complete JFG graph** replay processes the identical
256 recorded FGN ADC frames with chronologically propagated feedback and the
same installed Float32 inverse, background, references, mask and projections.
Its maximum command difference from retained FGN demand is 1.7053×10⁻¹³ m
(RMS 3.1902×10⁻¹⁴ m). Every frame has zero requested-minus-demanded difference,
physical constraint feedback and controller constraint feedback; there are no
requested components outside the limit or demanded components at the rail.
These are measured JFG replay outputs, not independent live FGN feedback
receipts. Live demanded-command rail checks alone do not establish clipping
feedback. This separation avoids claiming agreement from clipped outputs.

FGN then JFG live sessions ran sequentially. Cold analysis used other CPUs
while JFG was active; live truth recording and loading/precompilation also add
cost. Observed wall cycle rates were about 37/46 Hz for FGN and 29/37 Hz for
JFG. They are functional-run observations, not a throughput comparison,
500 Hz wall qualification or an accelerator limit. The 2 ms period advances
simulation model time only in these finite exchanges. Optional unavailable
DBus support and cold package precompilation warnings did not prevent the
functional checks; package/source artifact identities were verified.

## Disposition and remaining scope

The selected Hadamard 206-mode payload passes fresh validation, a selected-only
locked test, deployed correction in both engines and shared-input complete-graph
agreement at unchanged settings. It is accepted for the declared finite Classic
CPU simulation case. The original 186-mode baseline and all failed evidence
remain preserved; no existing deployment is silently replaced. The accepted
payload is installed only in these explicitly staged comparison packages.
This experiment establishes neither instrument thresholds nor population
uncertainty, equal-energy method superiority, wall-rate performance or physical
actuation suitability. Copper, unchanged HEART and CUDA/AMDGPU operational
calibration remain the next extension gates under RTC-DEV-029.
