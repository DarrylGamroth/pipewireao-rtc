# Copper measured dark and reference increment

## Baseline and target

Start from RTC `2f62fd5`, with unchanged FGN/JFG science graphs and the qualified
Copper capture endpoint. The separate UI restart issue uses its own worktree.
This increment prepares reusable, non-actuating CPU calibration candidates:
a measured 64×64 detector background, a 3,600-value normalized four-pupil lamp
reference, descriptive sample variances and an independent frozen-reference
comparison. It implements the next portion of RTC-ARCH-023 / RTC-DEV-029; it
does not close the complete operational interaction-calibration requirement.

Scientific calculations reuse public AdaptiveOpticsCalibration methods:
`ReferenceFrames.DarkFrameMoments` for unsigned raw ADC samples and
`Diagnostics.RepeatedResponseMoments` for complete normalized response vectors.
RTC owns settings, association, quality policy, file layout and acceptance.
Do not introduce another reference algorithm or copy external licensed code.

## Declared sequence and coordinates

1. Validate a complete-frame Copper CPU base and explicit recipe before output
   creation or launch. Freeze source, graph, parameter, model and policy hashes.
2. Acquire noisy dark ADC frames through the ordinary transport with zero
   background startup input. Reduce all declared frames to Float64 moments;
   publish a Float32 row-major background candidate after representability checks.
3. Prepare a fresh lamp package with that measured background. Preserve flat
   calibration, four pupil origins, 900 selected positions per pupil and all
   command maps. Acquire absolute normalized pixel vectors after a completed
   discarded normalization exposure.
4. Use equally weighted per-exposure response moments, preserving pupil-block
   then row/column order. Publish the rounded Float32 reference and Float64
   sample variance. Mean intensity remains diagnostic, outside the measurement
   vector; do not construct an I4Q signal or divide averaged pixels by averaged
   intensity.
5. Acquire a fresh, independently seeded lamp batch at the same held reference.
   Compare its mean to the frozen candidate. Record maximum absolute, RMS and
   relative norm differences without choosing an instrument tolerance afterward.
6. Verify every stage's restoration, release, public shutdown and owned cleanup;
   independently compare FGN/JFG raw inputs and products. Preserve failures.

Each stage uses an absolute 277-coordinate reference in µm OPD. Transport to
AOS remains metres. Copper's later controller map has 253 coordinates. No matrix
or scalar in an active science package is replaced by this candidate workflow.
The full detector noise/ADC model remains enabled; historical gain/excess-noise,
read-noise, detector registration and DM fixtures remain explicitly identified.
The model period and 2 ms exposure do not establish wall cadence.

## Policy and numerical boundary

- Recipe declares 2–64 samples per stage, three distinct UInt32 detector seeds,
  lamp magnitude, 277 finite Float32-representable reference coordinates,
  positive bounded operation/stage timeouts and settling by at least one
  discarded exposure or positive model time.
- The declared ADC upper rail must match the detector bit depth. Rail equality
  rejects a candidate; no sample is silently removed. Lamp responses must have
  finite pixels, positive finite current intensity and true intrinsic validity.
  Dark capture may retain false WFS validity; raw detector moments remain useful.
- Validate explicit Copper startup/manifest profile, fixed shapes/types/layouts,
  full acquisition-domain mapping, chronological exposures and payload hashes.
- The reference is the mean of individual already normalized absolute vectors.
  Normalization uses the previous successful frame's mean and can correlate
  successive samples. N−1 variance is descriptive. The generic moments method's
  independence-dependent standard error is not used as a confidence interval.
- Candidate means/variances are not interaction matrices, phase truths or a
  correction acceptance test. Reference subtraction/adoption in a science
  graph, held-out inverse selection and correction remain separate gates.

## Delivery and verification coverage

| Obligation | Owning implementation | Required evidence | State |
| --- | --- | --- | --- |
| Explicit recipe/profile/budgets | maintained Python cold orchestration | malformed policy rejects before effects; Classic workflow preserved | implemented; portable checks passed |
| Fresh stage assets and measured background binding | exporter plus cold stage preparation | immutable source, exact shapes/hash, only declared settings/arrays changed | implemented; reviewed producer binding and snapshot repairs |
| Public numerical reduction | thin Julia analysis using AOC | portable asymmetric fixtures, order, means/variance, invalid/rail cases | implemented; 232 Julia assertions passed |
| Independent frozen-reference characterization | unchanged capture plus AOC response moments | distinct seed/receipts; finite residuals; no retrospective tolerance | implemented; both deployed checks passed; scientific acceptance open |
| Installed FGN/JFG path | public deployment/calibration endpoints | actual paired inputs/products, restoration/release/shutdown, cleanup | passed for both CPU engines; actual inputs/products byte-identical |
| Evidence and scope | maintained report/ledger/review | source, policies, scripts, artifacts, failures and acceptance limits bound | [validation](COPPER_REFERENCE_VALIDATION.md), [ledger](COPPER_REFERENCE_EVIDENCE.json) and final independent evidence review passed |

Live UI restart checks and calibration captures share some deployment core
assignments. Run their live windows sequentially. Cold analysis and isolated
source work proceed concurrently. Do not alter kernel policy or existing
operator services for this increment.
