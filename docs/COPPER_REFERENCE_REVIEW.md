# Copper measured reference review

## Scope and baseline

Independent review in `pipewireao-rtc-copper-reference`, starting at
`2f62fd582be3a6e0b5fc2dcb7af4a7b77426d698`. Initial changes were the parent's
new Python orchestration/tests and plan, plus the worker's new Julia analysis/
tests. The reviewer owns only this document. No live session, production edit
or sibling change was performed. The separate recorded-FITS UI restart defect
is not assumed to apply to event-gated calibration acquisition.

Authority: `COPPER_REFERENCE_PLAN.md`, RTC-ARCH-023 and RTC-DEV-029. This is a
bounded, non-actuating Copper CPU candidate workflow: dark, training and fresh
qualification samples. It does not adopt a reference or qualify an interaction
matrix, reconstructor, correction, cadence or physical instrument.

## CRR-1 — Derived products are not bound to their producing report

**Severity:** High provenance/candidate-integrity defect.
**Confidence:** Confirmed by source and same-fixture fail-before/pass-after.
**Disposition:** Closed by producing-report and candidate-hash binding; see repair verification below.

In the reviewed initial `calibration_reference_analysis.jl`, qualification reads
`measured-reference-pixels.f32le` after checking only path, length and finite
values. It does not compare that file with the training report's artifact hash,
status, stage or recipe. The qualification report hashes the current file,
which records what it used but does not prove it used the frozen training
candidate. Existing qualification fixtures intentionally construct a reference
without a producing training report, demonstrating the absent prerequisite at
the interface level.

Likewise, Python `campaign` reads `measured-background.f32le` after the dark
subprocess succeeds without checking its bytes against the successful dark
report's artifact descriptor. Stage preparation records the consumed background
hash but does not connect it to the dark numerical result. A same-sized finite
replacement can therefore become a different lamp background or qualification
reference without rejection.

Required remedy: check the prior successful analysis identity and exact artifact
path/type/shape/length/hash before consuming either product; bind that producing
report in the later stage/result. Preserve a fail-before fixture that changes
one finite candidate element after a valid producing report, then require the
same fixture to reject before dependent preparation/reduction after the fix.
No change to the numerical estimator is required.

## CRR-2 — Campaign source freeze omits repeatedly copied inputs

**Severity:** Medium cross-stage reproducibility defect.
**Confidence:** Confirmed source behavior; repaired freeze coverage inspected.
**Disposition:** Closed by campaign-start snapshot and repeated identity checks; see repair verification below.

The initial Python source inventory freezes the orchestration modules and one
analysis helper. Each `stage_base` nevertheless recopies mutable AOC source and
all non-test `hil/*.jl` helpers, and validates the base against its current
rather than campaign-start descriptor. Per-stage inventories describe what
was copied, but do not reject a source/base change between stages. A completed
candidate can consequently mix algorithm/control snapshots despite the declared
prelaunch freeze.

Required remedy: freeze the initial base descriptor, selected AOC inventory and
all copied helper identities; validate them before every dependent stage and
bind them in the candidate record. A base with updated files and a regenerated
descriptor must still fail the original campaign identity check. Test changes
between dark and training without launching a real owner. Preserve failure
records and do not overwrite prior candidate products.

## Numerical and lifecycle source assessment

The reviewed numerical path has the intended coordinates and units:

- Raw samples remain UInt16 and convert from row-major wire order to
  row × column × exposure before public `DarkFrameMoments`. Float64 moments
  are rounded to finite Float32 background; mean and variance serialize back
  to row-major order. Asymmetric fixture values exercise this conversion.
- Pixels remain the full 3,600-element pupil-block wire vector per exposure.
  Public `RepeatedResponseMoments` averages these already normalized vectors;
  intensity stays outside the measurement vector. No ratio of averaged
  intensities or hidden optical truth is introduced.
- Sample variance uses N−1 descriptively. Previous-frame normalization can
  correlate adjacent samples; no independence-based confidence interval or
  measured standard error is promoted.
- Qualification compares its Float64 mean with the rounded Float32 candidate,
  using Float64 residual norms. A zero reference norm produces a null relative
  metric rather than division by zero. No retrospective tolerance is selected.

Input checks cover explicit Copper CPU profile, 14-bit upper rail, stage seed,
full UUID mapping, generation, probe 0, 277-coordinate adoption/restoration,
six correlated operations, exact discarded settling, non-overlapping ordered
exposures, fixed channel layouts and payload hashes before reduction. Lamp
requires finite pixels, positive finite intensity and true intrinsic validity;
dark permits false WFS validity while retaining finite evidence. Any ADC value
at or above 16,383 rejects the candidate, without silently selecting samples.

Fresh outputs and temporary-file publication prevent overwriting an existing
candidate. Analysis failure preserves a failed-candidate record, while each
ordinary acquisition stage restores/releases and shuts down before numerical
reduction. The existing deployment stage's owned-cleanup checks are reused;
launcher success must not be restated as independently recorded child exit
codes. Recipe/sample/file bounds and the little-endian guard are explicit.

No numerical ordering or aliasing defect was identified in this initial source
pass. Portable tests reported by implementers remain software evidence. Live
FGN/JFG dark/training/qualification qualification is pending CRR-1/2 closure,
frozen source verification and actual receipt/artifact review. Equal seeds
alone will not establish paired ADC equality, and reference candidates remain
unaccepted for active science use even after a successful bounded workflow.


## Repair verification and bounded prelaunch clearance

The reviewer inspected the frozen repairs and independently verified every
source, fixture and evidence-log hash in
`~/.cache/rtc-copper-reference-20261003/julia-validation.json`.
Julia analysis source SHA-256:
`ce51e54b71140a628d36c96b99c056a469bdde568a10be18b8b3a6384f135201`.
Julia test SHA-256:
`5cf2dbc4f5468786881d11e0352edfc393346fe10492fc160c5680ab2dad0696`.

CRR-1's preserved unchanged fixture first demonstrated that a same-size modified
reference was accepted despite its legitimate producing report; the repaired
source rejects that fixture (1/1 pass-after). The original relative-include
setup error is separately identified and is not used as defect evidence.
Qualification now requires successful public training status/method, recipe,
sample count, analysis source, coordinate/variance/qualification scope and prior
stage/manifest identities. It checks the exact reference descriptor and bytes
before reduction or publication and records the producing analysis hash.

Python admits each numerical product against its successful report's declared
stage, method, sample count, helper source, recipe, stage-result identity and
exact artifact descriptor/hash. It freezes product and report hashes in memory,
checks them before subsequent preparation/launch and after acquisition, and
checks them again before completing the candidate. The qualification reference
hash must equal the stored training product hash. Dark background consumption
therefore has an explicit producing-report link. Same-size background changes
and report changes are covered by portable negative cases.

CRR-2's snapshot now covers the initial base descriptor, every copied AOC path
selected by the existing `copy_package` contract (Project, src, ext, graphs and
license files), and every copied non-test Julia helper. Dictionary comparison
also detects additions/removals. The initial canonical recipe hash and Python
orchestration hashes are checked alongside that snapshot. Checks run before
stage preparation, after export before launch, after capture and at campaign
completion. Base files are additionally validated against their descriptor by
ordinary package validation; regenerating that descriptor no longer evades the
initial identity. Portable cases cover changed descriptor, added AOC source and
changed helper inventory.

The retained Julia log reports 232/232 assertions, including 47 prior-artifact
binding checks, with bounds checking and deprecation errors enabled. The broad
Python deployment log reports 175 tests, 173 passed and two environment fixture
skips; this includes eight Copper-reference tests. The reviewer inspected their
source and results without repeating the full suites. No new numerical-ordering
or lifecycle blocker was found in the repaired code.

**Prelaunch disposition:** permit the declared bounded FGN/JFG three-stage
N=8 candidate runs with distinct detector seeds, unchanged science/controls and
normal ADC/noise. This is source/software clearance, not live completion or
scientific acceptance. Final qualification still requires actual package/source
identities, measured background adoption, ordered receipts, product re-estimation,
paired-input/output comparison, fresh restoration/release and owned cleanup.
The immutable old UI failure evidence remains separate.

## CRR-3 — Final paired installed candidate audit

**Severity/confidence:** Completion and scientific-claim gate; observed artifacts
and independently derived numerical checks.
**Disposition:** Merge clearance for the declared bounded CPU candidate workflow.
CRR-1 and CRR-2 remain closed; no additional blocker was found.

The completed outputs are `fgn-candidate-v2` and `jfg-candidate` under
`~/.cache/rtc-copper-reference-20261003/`. The reviewer independently rehashed
all 260 evidence-file entries and four current source entries in
`COPPER_REFERENCE_EVIDENCE.json`, all inventory entries in
`numpy-comparison-validation.json`, and all 2,649 artifact entries across the
six installed stage packages. All matched. The installed copies also match
50 frozen AOC files and 12 frozen helper files per stage (372 comparisons).
The earlier FGN inherited-affinity rejection remains separately preserved.

Each of six completed stages has eight ordered captures at sequences 2–9,
generation 1, its own full acquisition-domain mapping, 100 ms model starts and
2 ms durations. Six correlated hold/adopt/settle/capture/restore/release replies
bind the zero 277-coordinate reference without clipping. Final source sequence
10 is fresh restoration, followed by completed pause, release and stopped
lifecycle with launcher exit 0. All recorded launcher/child PIDs and owned
runtime instances were absent when independently checked. Individual child
exit codes are not inferred from launcher status.

The reviewer checked that dark packages use zero detector background and both
lamp stages use the exact measured Float32 background bytes. Per-engine science
graph bytes are unchanged across stages; frozen recipe, detector seeds,
report identities, source copies and installed inventories are consistent.
Candidate production does not modify the original operator base or adopt
reference subtraction in a scientific graph.

Every raw, normalized-pixel and intensity payload hash was rechecked. Direct
byte comparison independently confirmed all 24 paired exposure payload sets and
all five candidate products are exact between FGN and JFG. This is observed
input/output equality, not a claim based only on shared seeds. Paired report
SHA-256: `6a83792e10b0beabcfcd63f25154baaa4abb9165bcb51bf5a7c02849e5ae36a4`.

Independent Float64 reduction of actual qualification bytes reproduced maximum
absolute residual `0.4097371995449066`, RMS approximately
`0.0983977997543304` and relative norm `0.08880739336786202` against the frozen
Float32 reference. Recomputing the training mean found the same four one-step
Float32 differences at zero-based indices 779, 868, 875 and 986. Independent
exact rational arithmetic on represented input samples verified that each
mathematical mean lies exactly halfway between the two adjacent Float32
values. The published public-AOC reduction and NumPy select adjacent results
(maximum difference `1.862645149230957e-9`); this is transparently reported, with
no algorithm or acceptance-policy change.

The plan, usage, validation and latest roadmap entry accurately limit completion
to measured candidates and descriptive qualification. An approximately 8.88%
relative norm is not promoted to acceptance without an instrument tolerance.
Previous-frame normalization may correlate samples; N−1 variance is descriptive,
not an independence-based confidence interval. Observed cold durations are not
cadence benchmarks. Reference centering/adoption, precision/linearity, 277→253
composition, interaction calibration, inverse/correction and physical/accelerator
qualification remain open; RTC-DEV-029 remains partial.
