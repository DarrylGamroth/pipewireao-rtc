# Calibration completion: independent scientific review

## Scope and baseline

Review worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-completion`, initially clean baseline `6f57ea48b2620fe13b9d09a08a02ee4aeca755ce`. The reviewer owns this document only. No live RTC or accelerator runs, source modifications, gain changes or external code copying were performed. Bounded independent array inspection uses recorded parameter bytes; numerical ranks below are Float64 SVD calculations, separate from scientific response measurements.

RTC-ARCH-023 and RTC-DEV-029 govern the operational procedure. The analysis-methods skill is used to trace models, representations and evidence. The existing Classic selection, Copper reference/pilot and Julia migration/package qualification records are historical evidence, not results of this new study. Public AdaptiveOpticsCalibration source is clean commit `f79104ddec1fcd609ea60d5a081f72dfb280ff73` at initial review.

**Current disposition — 2026-10-04: all five selected finite simulation study gates are accepted.** The retained evidence covers illumination/probe characterization, repeated matrices, zonal/Hadamard/partial-span spatial comparisons, held-out inverse selection and physical/controller composition, and selected FGN/JFG/unchanged-HEART correction with available CUDA/AMDGPU simulation. This combines explicitly bound historical and current cohorts; it does not claim a complete engine/backend Cartesian matrix or rerun every cohort on the final source.

Native Copper's accepted source6 experiment and native Classic's accepted source10 experiment both complete two 256-frame windows, exact reset reproduction, zero restoration, public shutdown and same-backend detector/direct-truth/zero-command replay. Independent final Classic audit binds 1,573 files; its fixed-window residual/zero variance ratios are 0.0442815144 and 0.0344010802 in both batches. The explicit normal-response policies retain Copper's two rail pixels per batch and Classic's 236 dropout frames/544 subaperture events per batch. Failed earlier attempts remain failed. Neither policy changes calibration's strict valid-probe admission.

**Remaining scope limits:** CCR-017 ordinary native Copper streaming remains open; the selected deferred completion-driven fixture does not close it. CCR-006's generic private-core completion timeout reproduces on the exact API parent and candidate and remains unresolved separately from the verified selected native associations. Physical instruments, DU860 electronics, instrument-specific error/dropout tolerances, progressive latency, wall-clock rates and untested configurations remain unqualified. Accelerator labels refer to the simulated plant backend, not RTC graph execution.

The table below records final dispositions. All later “pending,” “open,” and “not yet qualified” statements inside earlier checkpoint sections describe the evidence available at that historical stage; final acceptance and its exact source scopes are recorded in the closing sections.


## Findings and study gates

| ID | Severity if ignored | Confidence | Evidence class | Disposition |
| --- | --- | --- | --- | --- |
| CCR-001 | High | High | Recorded command-map bytes and independent SVD | Coordinate constraint verified and enforced in actual physical-basis study; no prefix/rank assumption |
| CCR-002 | High | High | Existing deployed absolute-pixel representation versus derivative inverse | Closed for selected cohorts: physical-basis/reference rejection, held-out utility and deployed correction verified |
| CCR-003 | Medium | High | Exact detector configuration and noise implementation | Model limitation retained explicitly; no physical detector/electronics acceptance |
| CCR-004 | High | High | Baseline method owner had Classic-only contracts | Closed for selected Classic/Copper operational methods and retained actual acquisitions |
| CCR-005 | Medium | High | Previous-frame normalization and balanced pilot chronology | Empirical repeat/order interpretation retained; no confidence-interval claim |
| CCR-006 | High | High | Constant native Header sequence cannot prove freshness | Selected native association verified by actual held/active evidence; generic private-core timeout remains unresolved separately |
| CCR-007 | Medium | High | Initial full-cohort text left estimator and primary loss ambiguous | Closed: pre-acquisition freezes and actual absolute-score/winner/locked recomputation verified |
| CCR-008 | Medium | High | Same isolated counterexample before/after remediation | Closed: absolute-cutoff tie-break independently verified |
| CCR-009 | High | High | Same isolated incomplete-corpus call before/after remediation | Closed: exactly two independent bound acquisitions required and verified in actual admission |
| CCR-010 | High | High | Exact FGN recurrence, preserved graph coefficients and copied plant OPD addition | Closed: estimator/controller polarity, actual packed bytes and deployed negative-feedback utility verified |
| CCR-011 | High | High | Isolated chronology mutation accepted before fix, rejected afterward | Closed: consumed preparation files and frozen directions now checked |
| CCR-012 | High | High | Cross-stage identity checks and isolated mutation rejection | Closed: shared checked inputs now cover inverse and spatial scoring |
| CCR-013 | High | High | Synthetic bypass rejected; actual complete FGN and JFG corpora independently recomputed | Closed for reviewed FGN v1/JFG v2 tuples; separate actual selected correction evidence accepted |
| CCR-014 | High | High | Frozen validation/locked runs are both [1,2], contradicting global uniqueness | Closed: distinct capture seals and seeds required; local run numbers accepted |
| CCR-015 | High | High | Owned shell-child missing-state/ignored-signal/terminal-state probes | Closed: fallback cleanup and terminal status independently verified |
| CCR-016 | High | High | Original counterexample rejected; actual N2 native payloads, means and shutdown independently verified | Closed: actual native payload/mean/lifecycle binding verified through the full selected cohort |
| CCR-017 | High | High for failure; medium for precise race interleaving | Actual ordinary reference-2 native error102 and committed invalid gradient record | Open for ordinary streaming; explicit deferred fixture is separately qualified |
| CCR-018 | Medium | High | Same actual AMD scoring result fails before serialization repair and passes afterward | Closed: immutable v2 serializer/preparer verified; scientific mathematics unchanged |
| CCR-019 | Medium | High | Same accepted operational Classic base fails old configuration helper and passes exact measured-input conversion | Closed: exact operational offsets and final native Classic transfer/correction verified |
| CCR-020 | Medium | High | Fresh generation with previous journal counters rejects its first evidence record | Closed: fresh journal counters and actual two-generation reset independently verified |
| CCR-021 | Medium | High | Actual cold active export exceeded unchanged deployment-name bound | Closed: bounded names verified with the same public profile check |
| CCR-022 | High | High | Same unsealed-helper counterexample executes before v3 and rejects before execution after v3 | Closed: pre-admission guards, actual maintained score issuance and exporter replay verified |
| CCR-023 | Medium | High | Classic CUDA calibration name is41 characters against unchanged40 limit | Closed: same public validator rejects old name and accepts bounded Classic name; Copper unchanged |
| CCR-024 | High | High | Actual native zero-DM record exists but source blocks before allowing RTC host/link creation | Closed: public startup ordering and actual two-window stop/reset/restart verified |
| CCR-025 | High | High | Actual1561 frames have2ms period but1.896ms exposure; verifier uses exposure as period | Closed: narrow source fix, diagnostic replay and fresh successful public capture/manifest verified |
| CCR-026 | High | High | Native RUN→CORRECTING intentionally rotates files; active reader rejects multiple files | Closed for selected Copper/Classic: both15-file windows, reset and cleanup verified |
| CCR-027 | High | High | Exact-sync tests and actual restore bucket257/sync256 with zero physical payload | Closed: actual startup0/sync0 and restoration257/sync256 physical-zero receipts verified |
| CCR-028 | High | High | Same actual Classic admission fails v4 and passes v5; consumed-helper mutations reject | Closed: precise helper closure and actual full Classic characterization verified |
| CCR-029 | High | High | Actual sealed labels fail old loader and pass typed loader; schema negatives reject | Closed: actual full numerical result independently verified |
| CCR-030 | Medium | High | Native correction rejects rail hits that original normal correction permits and reproduces | Closed for scoped fresh Copper run under explicitly revised policy; two rail hits retained/disclosed |
| CCR-031 | High | High | Actual Classic package and cold load_contract reject correct24 profile flags against global Copper13 | Closed: exact profile flags, packaged loader and actual Classic startup/CORRECT verified |
| CCR-032 | High | High | Actual Classic setup selects nonexistent pwfs_frame despite prepared shwfs_frame | Closed: actual profile boundary, CPU recorder/truth/reset and full Classic windows verified |
| CCR-033 | High | High | Actual linked native E input passes seal but strict decoder rejects unresolved runtime symlink | Closed: hash-checked runtime map resolution, mutation rejection and actual startup verified |
| CCR-034 | High | High | Actual first Classic response and native/FGN threshold semantics | Closed for fresh selected source10 Classic experiment; classified dropouts retained, finite utility/reset/replay verified |

## Chronological findings and verification checkpoints

The following sections preserve the original observations, decisions, counterexamples and intermediate status. Final dispositions above supersede historical outstanding-gate wording.

### CCR-001 — Copper has 253 wire coordinates but fewer actuated dimensions

The exact recorded FGN science bases under `~/.cache/rtc-deployment-functional-20261001/delivery/revolt-{classic,copper}-fgn-frame` were inspected through their provenance metadata and ROW_MAJOR Float32 calibration payloads. Physical command order is 277 HSDM coordinates for both instruments. Controller extent is 221 for Classic and 253 for Copper; these extents are not interchangeable with physical coordinates or identifiable rank.

Let C map controller to active VDM, E complete active to full VDM, P map full VDM to physical DM, F map physical feedback to full VDM, T select active VDM, and V map active VDM feedback to controller. The forward map is B = P E C; the feedback map is L = V T F.

| Recorded base | B shape | Observed structure | Numerical rank | Feedback observation |
| --- | --- | --- | --- | --- |
| Classic | 277×221 | C, P, F and V are identity at their declared extents; E is extrapolation, T is selection | 221 | T E = I and L B = I exactly for these bytes; E differs from Tᵀ, maximum difference 0.99457 |
| Copper | 277×253 | C, E, T and V are 253×253 identity; P columns 1–3 are exactly zero | 250 | F rows 1–3 are zero; ‖L B − I₂₅₃‖F ≈ 10.63015 |

The Copper rank result has an exact structural basis: three zero columns. Remaining singular values are positive down to approximately 2.5870×10⁻⁵. This does not establish optical observability of the remaining directions. F is an established feedback projection, not an algebraic inverse that may be silently replaced.

Impact: a claimed full-rank 253-coordinate inverse, an all-coordinate nonzero-probe generator, or an identity round-trip assertion would be incorrect for this tuple. Keep the 253-coordinate wire contract; explicitly record unactuated/unobservable directions and score physical B u against the actual represented command. Do not infer that controller coordinate i is physical actuator i. Normalize dense probe amplitudes in the physical command domain after mapping and Float32 representation.

Required validation: freeze the newly selected base maps, reproduce this audit for those exact bytes, preserve null coordinates in reports, and test physical/controller composition and reverse-feedback separately. This is a confirmed constraint, not a defect requiring map changes.

Map identity evidence:

- Classic provenance: `ca21db22088e1db4febeae385e8398ac680a19caec804074e603de954b311338`.
- Classic E: `8c6c942d40ea6f2814db19c407ebba2d2159eaf29876ed08114967a1c96c0e81`; T: `f8293d858992ae5acac10cc67dd6fd887cf72d5f3b489e6d42866b787d8dccaa`.
- Copper provenance: `5ba17b070bc31c25a7369c4a1bfad33ddf9de81861636f2112cf9e63f4526a43`.
- Copper P: `19d2e6ef5f5eb43e535a6076fca5a2ac2cb835b8c746c05876d6fa25f43fcd92`; F: `05fd64b56ca512946a07991ed547478fcf29558c7574ee0160e3f04957a07f55`.
- Copper identity C/E/T/V: `9d9fe9d8cd3311ade1604497cb88edf7872699935d79c972703b6ef828986e6f`.

### CCR-002 — A derivative inverse does not automatically reject absolute-pixel baseline

Copper calibration observes 3,600 absolute normalized four-pupil pixels, in pupil-block order. `COPPER_REFERENCE_USAGE.md` explicitly states that the measured reference is a candidate and does not introduce subtraction into the active graph. `PyramidPixelImageF32` publishes normalized pixels; the deployed reconstructor consumes them.

A derivative estimate identifies differences δy ≈ D δq. An inverse R selected using signed differences can perform well on R δy while producing a nonzero R y₀ at the reference figure when deployed on absolute y. A successful push/pull prediction therefore does not prove zero-command equilibrium or correction. This is a confirmed algebraic gate; no failed new inverse is asserted before one exists.

Required remediation/design: declare and freeze a baseline treatment that is actually implemented by each selected engine. It may require a compatible reference path or a candidate constrained to reject the reference; that choice belongs to the primary. Do not subtract a reference only in offline validation and then deploy an absolute-input inverse. Evaluate the packed Float32 candidate on fresh zero-command lamp measurements, signed held-out responses, and the actual deployed graph before correction acceptance. Preserve reference uncertainty and any residual bias in reports.

### CCR-003 — The historical Copper fixture is not a characterized DU860 EMCCD

The retained Copper `fgn-reference-v4/dark-base/hil/plant.toml` selects gain 1, excess-noise factor 1, CIC 0, QE 0.95, dark current 20 e⁻/pixel/s, read noise 1 e⁻, 2 ms exposure, 14 bits and full well 16,000 e⁻. Photon and read noise are enabled. At gain 1 and excess-noise factor 1, AOS's selected multiplication model has zero conditional multiplication noise; the fixture is a provisional noisy unity-gain detector. It is not evidence for a configured physical DU860 multiplication register.

In AOS `detectors/emccd.jl`, the default multiplication approximation is clipped Gaussian. Its conditional standard-deviation factor is √(F² − 1), floored by the explicitly configured minimum. The idealized unsaturated input-referred variance is F²(λphoto + λdark + λCIC) + (σread/g)². This expression is explanatory, not an exact promise after clipping, quantization, normalization or finite sampling.

`detectors/frame_capture.jl` scales detector output by (2¹⁴−1)/16000 = 1.0239375 ADC/e⁻ and clamps to the ADC interval. The HIL wire conversion rounds to UInt16 with nearest/ties-to-even. Calibration uses these transported ADC values. Dark mean is only 0.04 generated e⁻/pixel per exposure before read noise and nonnegative output clipping; dark offsets and variances must be measured after the actual encoding, not replaced by this expectation.

The reviewed detector/source implementation files are byte-identical in current AOS and the retained reference base: `emccd.jl` SHA `305ef7f9a6906d75d06e7f5c111f175f270ce1e496f876a12eb9b3e69f7ecbf6`, `frame_capture.jl` SHA `e39d6b4a7be8e9c4e99a185102830e86a97512806d3573bf31c67a4c213b7a68`, `optics/source.jl` SHA `9542170a703c622fa253228926455235eca260b5088514f47670d3d925f64e87`. This does not assert equality of all dirty AOS sources.

Required scope: keep this detector tuple fixed for the first illumination discriminator. Any changed gain/ENF/CIC/read-noise study needs a separate explicit configuration and regenerated measured backgrounds/references. No physical detector qualification follows from this task alone.

### CCR-004 — Existing general method acquisition is Classic-specific

At baseline, `deployment/julia/src/calibration_method.jl:retained_startup` calls `classic_snapshot` and requires a 352×352 background, 188×2 reference slopes and 188-entry active mask. `deployment/hil/calibration_method_analysis.jl:prepared_specification` defaults to 376 measurements. The existing Copper directional pilot acquires 3,600 measurements but is not the full zonal/Hadamard/spatial method workflow.

Required remediation: use the existing operational acquisition and public AOC estimator interfaces with an explicit Copper measurement/startup contract. Verify shape/order, represented commands, complete chronology-to-canonical permutation, hashes, rejected clipping, restoration/release and save-before-advance before long acquisition. Do not claim existing Classic method success establishes Copper support. A full physical 277-coordinate balanced AOC Hadamard design uses order 512, excluding its DC column; spatial modes only identify their declared span unless a complete independent spanning set is actually measured.

### CCR-005 — Pilot repetition differences do not identify independent shot noise or linearity

`PyramidPixelImageF32` sums all four full pupil rectangles to obtain the current mean and multiplies selected calibrated pixels by the reciprocal of the previous successfully committed frame mean. The previous mean is zero after reset. The output is therefore yₜ = xₜ / μₜ₋₁, not xₜ / μₜ. One valid discarded frame after adoption primes normalization for a held command; the current settle receipt does not expose that discarded frame's intensity or validity.

Adjacent outputs share random numerator/denominator information and can be correlated. The two historical traversals also reverse sign order and amplitude order together. Their derivative discrepancy combines noise, temporal variation, normalization history and possible nonlinearity. Byte equality between FGN and JFG with the same seed demonstrates implementation agreement, not independent repetitions. N−1 variance is descriptive; dividing it by N is not a validated standard error for this sequence.

Required study: retain raw, normalized pixels and current intensity; inspect first versus later frames and lag dependence; use separately seeded repetitions and distinguish paired engine comparison from independent precision measurement. Preserve all declared samples or reject the whole scientifically ineligible batch under a frozen rule. Do not retrospectively trim difficult first frames or fit away drift without declaring a new study.

## Equations, sign and units

For fixed source band and geometry, AOS `optics/source.jl` uses Φ(m) = Φ₀ × 10^(−0.4 m). Reducing magnitude by 2.5 multiplies input photon irradiance by ten. Expected incident/photoelectron counts additionally depend on optical propagation, throughput, pixel footprint, QE and the declared 2 ms exposure. The previous maximum ADC of 66 suggests substantial ADC headroom but is not a bound for all brighter or densely poked images; every candidate illumination/probe must be checked against actual transported rail values.

The plant composes uncompensated OPD plus DM surface OPD (`native_nodes.jl:pupil_opd_composition`), so positive DM commands add OPD. FGN/JFG physical commands are in µm OPD and the simulator scales by 10⁻⁶ to metres. The unchanged HEART bridge carries metre OPD. These are OPD coordinates, not mirror mechanical displacement; do not introduce an extra reflective factor of two.

For one physical direction, with actual adopted represented commands q⁺ and q⁻, d = (ȳ⁺ − ȳ⁻)/(q⁺ − q⁻), in normalized-pixel/µm OPD for Copper. Use the represented interval, not a decimal label. Structured AOC estimators use interleaved positive/negative response rows and retain measurement×command output orientation. Controller response is A = S D B; S is the actual Classic slope selection, or the declared Copper measurement projection. Packed deployment inverse is controller×measurement. Physical inverse loss compares B R z with the actual held-out physical figure, not with an arbitrary controller coordinate norm.

The deployed correction sign must be checked against this measured derivative and the actual existing controller recurrence. Held-out forward/inverse success alone does not establish a stable closed-loop sign, baseline, leakage, delay or clipping-feedback convention. Preserve gains, poles, command limits and feedback maps unless a separately reviewed engineering basis justifies a change.

## Low-cost discriminators and admission sequence

1. **Freeze inputs before screening.** Bind source package, detector/model configuration, binary, command maps, pupil selection, measured background/reference, source helpers and exact seed/order declaration. Any compatible adapter/AOS tuple is selected by actual source bytes, not a clean commit label alone.
2. **Screen illumination while holding detector and command settings fixed.** A predeclared decade-spaced flux screen is informative because the model has a known magnitude scaling. Retain null and balanced signed batches at the existing amplitudes; log raw sums/quantiles/rail counts, intensity, normalized means and first/later behavior. Increased brightness is a new calibration condition and needs matching measured reference evidence.
3. **Separate signal, precision and nonlinearity.** Compare repeated derivative discrepancy in response units (multiply by actual command interval), sign-pair midpoint against bracketing nulls, and amplitude-dependent derivatives. Use independent seeds and separated/reversed ordering. No single cosine or maximum ADC proves a full matrix is adequate.
4. **Freeze the matrix acquisition policy.** Select the illumination/amplitude/exposure/averaging tuple using only the screen. Declare full repetition counts, order and cost. Acquire separately seeded FGN/JFG matrices with complete manifests and no changed figures. Report physical and composed controller spectra and null dimensions; use equal physical command constraints when comparing zonal, Hadamard and spatial families. Equal per-actuator peak does not imply equal total command energy or equal optical linearity for dense patterns.
5. **Freeze selection before held-out acquisition.** Reuse the established Classic pattern of declared candidate families/cutoff policy, separate validation and locked test, eligibility against zero prediction, and scoring of packed Float32 payloads. Empirical repeat spectra are discrepancy scales, not confidence bounds. Do not transfer Classic's rank 206 or numerical cutoff to Copper. A spatial-span result is not a full controller result.
6. **Demonstrate deployed correction.** Use fresh held-out disturbances and unchanged control settings, with both zero-command baseline and physical residual/constraint diagnostics. Compare against an explicit no-correction baseline and preserve failures. Never infer convergence from transport success or controller-state norm alone.
7. **Qualify unchanged HEART and selected accelerators separately.** Confirm actual measurement/reference/order/command units and available public operational control before sharing a matrix. CPU agreement does not prove CUDA/HIP detector random streams are identical. Compare declared statistical/numerical responses and correction; keep latency/cadence and physical-instrument claims separate. Mere CUDA device enumeration or successful preparation is not acquisition evidence.

No arbitrary instrument tolerance has been introduced here. A complete predeclared recipe and selected acceptance policy remain to be independently reviewed before full acquisition. The recorded Classic 206-mode result may remain accepted within its original finite corpus and deployed CPU correction scope while new Copper and accelerator gates remain open.

## Frozen first-screen review

The primary’s `CALIBRATION_COMPLETION_PLAN.md` and the two cache recipes were inspected before full-matrix acquisition. The declared magnitude change from 5.752574989159953 to 3.252574989159953 is exactly a factor ten in source irradiance. The existing detector tuple, 2 ms exposure and one-frame settling rule remain selected. The zero physical reference has 277 finite coordinates.

| Frozen recipe | SHA-256 | Declared sample policy |
| --- | --- | --- |
| `bright-reference-recipe.json` | `2fc827a9a8434e35251a6baf5635205d8482ede1b6f72071e2926646b20bed7f` | Dark/training/qualification: eight frames each; independent seeds 511/512/513; 30 s request, 300 s stage |
| `bright-pilot-recipe.json` | `04f7e4bdd09127f354481253f29d306f70ec925519333aa7e5b9c401d6380d1c` | Actuator 139, represented amplitude 0.03999999910593033 µm OPD; eight frames per batch; two opposing sign orders; seed 514; 30 s request, 900 s stage |

The pilot schedule is null,+,−,null followed by null,−,+,null: eight retained batches (64 exposures), eight discarded settling exposures and restoration. The reference and pilot declarations agree on lamp, physical reference and rail. This is an admissible bounded discriminator. It does not by itself admit a full matrix, establish amplitude linearity, or yield two independently seeded repetitions. Relative to the old pilot it also changes the detector seed and measured reference/background realization; it is not a controlled causal measurement of flux alone. The previous pilot failed to establish adequate precision; no previously supplied instrument precision threshold was available to fail.

All six command-map payloads in the actually selected `fgn-reference-v4/dark-base` were independently compared byte-for-byte with the recorded Copper base used for CCR-001. They match. The active 277×250 map has maximum/minimum singular values approximately 0.0769811461 and 0.0000258701776 (condition ratio about 2975.7). This is a coordinate-map condition measure, not a sensor or interaction-matrix condition estimate. The accepted older adapter tuple used for HEART is not assumed to be the calibration endpoint tuple; each workflow must seal its actual compatible source set.

## Proposed absolute-baseline rejection policy

This is a mathematical proposal for primary adjudication, not an implemented or qualified reconstructor. It preserves the existing matrix-only application interface and therefore can be carried by unchanged HEART if its observed pixel ordering, calibration and units match the declared input.

Freeze a finite nonzero matching-lamp measured reference r ∈ ℝ³⁶⁰⁰ before candidate construction. Define the orthogonal measurement projection

```text
Q = I − r rᵀ / (rᵀ r)
Q r = 0
```

Fit the inverse to the **projected** forward operator. A direct controller-coordinate candidate is

```text
A = D B
J = Q A
R = TSVD_AOC(J) Q
```

The deployed graph still computes R y on absolute pixel vectors. Algebraically R r = 0, so no new subtraction stage or hidden runtime offset is required. Implement Q A as A − r(rᵀA)/(rᵀr), and K Q as K − (K r)rᵀ/(rᵀr), rather than allocating a 3,600×3,600 projector. AOC remains the public inverse estimator; these are explicit input/output coordinate compositions.

Applying Q only after fitting the unprojected A is generally wrong: it nulls the reference but changes the fitted forward/inverse relation. The same Q must enter candidate spectra, repeat-discrepancy policy and construction. Do not silently substitute an unprojected matrix’s cutoff or rank.

### Physical-coordinate regularization

The recorded Copper controller basis is far from orthonormal. Singular cutoffs on D B penalize that chosen controller parameterization; they are not invariant to a harmless rescaling of controller coordinates. This is not automatically a defect, but the choice must be explicit in a method comparison.

For candidates intended to minimize Euclidean physical actuator error, a useful common task basis follows from the **fixed command map**, independently of measured responses. Let H embed the 250 structurally actuated controller coordinates 4–253 into the 253-coordinate wire vector, and take the thin, full-rank SVD

```text
Bₐ = B H = U Σ Vᵀ              (277×250)
J  = Q D U                     (3600×250)
K  = TSVD_AOC(J)                (250×3600)
R  = H V Σ⁻¹ K Q               (253×3600)
B R = U K Q
```

U is orthonormal in the declared physical actuator Euclidean metric. Therefore the inverse selection acts in a common physical-command basis, and wire coordinates 1–3 remain literal zero rows through H. This does not replace the established reverse feedback map F, or assert that physical actuator Euclidean loss equals optical wavefront loss. Both metrics have distinct roles in correction evidence.

Keep every nonzero map singular direction; any additional map truncation would be another policy requiring declaration. Use the exact original B in packed physical scoring. Zeroing only the three structurally null coordinates is established by the actual map, whereas truncation of weak measured directions is selected from the declared response/discrepancy policy.

### Bounded algebra check

A deterministic NumPy synthetic calculation (seed 139; 12 measurements; a 7×5 command map with two exactly zero columns and three differently scaled nonzero directions; random linear D; positive reference r) compared the three policies. It uses no simulator output and establishes algebra only.

| Construction | ‖B R r‖₂ | ‖B R D U − U‖F |
| --- | ---: | ---: |
| Unprojected pseudoinverse | 0.576738 | 2.28×10⁻¹⁵ |
| Unprojected fit, then input projection only | 1.65×10⁻¹⁶ | 0.183115 |
| Projected fit and input projection | 2.30×10⁻¹⁶ | 1.56×10⁻¹⁵ |
| Same final matrix rounded to Float32, evaluated in Float64 | 3.71×10⁻⁸ | 4.05×10⁻⁸ |

The final implementation must test the public AOC construction and actual packed input/output contract. The synthetic numbers are not proposed acceptance tolerances.

### Required qualification of this policy

- Report unprojected and projected response energy/singular spectra and any lost rank. Reference rejection can remove physically informative response parallel to r; it is not free information.
- Freeze r from training and test on separately acquired flat-lamp data. Exact cancellation of a noisy training reference does not establish an unbiased true flat response. The present eight-frame reference is a pilot input, not automatically an adequate final reference estimate.
- Evaluate the packed Float32 matrix and actual engine arithmetic, including R r, fresh-flat B R y, signed held-out physical prediction and closed-loop response. Numerical cancellation after packing is approximate.
- Keep zero-command/null groups separate from strict “better than zero-command prediction” eligibility: their true command is zero, so that baseline already has zero command loss and cannot be strictly beaten. Report null bias/noise, and use nonzero declared held-out direction groups for the existing utility criterion. No instrument null-bias tolerance is invented here.
- Declare forward-loss representation before selection. Raw signed-response prediction and projected-response prediction answer different questions; retain raw diagnostics so removal of a response component cannot hide disagreement. Score reconstruction in the actual physical domain, including out-of-span components where present.
- Use the same projected task basis and cutoff rule across comparable complete method families. A partial spatial-sine result must not be promoted to a full 250-dimensional estimate; either compare its actual span or acquire a declared spanning basis with its own conditioning evidence.

At that earlier screen checkpoint, CCR-002 and the full-matrix policy were pending. The subsequent construction and full-cohort review below supersede that disposition. CCR-001 and CCR-003 remain accepted input constraints, CCR-004 requires operational qualification, and CCR-005 remains an interpretation limit.

## Cold inverse implementation verification

Reviewed helper `deployment/hil/calibration_inverse_analysis.jl` SHA-256 `4a885b5f2301e91e7545bdb6cffb4dc66f315b5cdd9c92fc4387989d8491342c`; focused test source SHA `7a0fff604ac133fcbc0bc2209cf74c9c41bdc72153c0f653c4612f5d1fe4909e`.

The implementation follows the proposed physical-coordinate composition. `physical_coordinates` excludes exactly zero columns, performs a thin SVD, forms U and W with B W ≈ U, and embeds W into the original wire extent with exact zero inactive rows. Its recorded relative tolerance is numerical map-rank classification, not a sensor precision cutoff. `candidate` forms D U, rejects the normalized frozen reference before fitting, uses public AOC SVD inverse methods, rejects the reference again on the inverse input, then packs to finite Float32. It returns projected/unprojected response energy, retained rank, map-composition error and the packed physical baseline response. No scientific tolerance is selected inside the helper.

Independent bounded Julia 1.12.7 checks used one Julia/OpenBLAS thread, no live transport, no package installation and no broad suite. The actual Copper map yields rank 250, null coordinates [1,2,3], ‖B W − U‖F = 1.2928943904928197×10⁻¹² and ‖UᵀU − I‖F = 3.2322874555479854×10⁻¹⁴. A separate synthetic seed-183 calculation compared the helper to an explicitly materialized projector and direct pseudoinverse: relative matrix difference after Float32 packing was 2.4154390906583606×10⁻⁸, scaling the reference by 1000 left the packed matrix identical, exact null rows remained zero, and the packed physical baseline norm was 8.966117915829694×10⁻⁹.

The first attempt with the canonical AOC project stopped during package loading because its selected SpecialFunctions dependency was unavailable. The successful check used the already prepared `fgn-bright-reference/training-package/hil` environment; its copied public AOC `svd_inverse.jl` was byte-identical to the clean canonical source (SHA `640e941fc54c0c933fdb63d5b90603d4ca542e7eb9a32e1bfbeb178a00837c90`). This is environment selection, not an algorithm remediation. No canonical dependency environment was changed.

The primary reports 25 focused synthetic assertions passing; the reviewer additionally read those tests and performed the independent checks above. No selected-scope formula, packing or null-coordinate defect is identified. CCR-002's **construction** gate is satisfied for this helper. Its scientific gate remains open: fit actual accepted matrices with frozen reference/cutoff policy, inspect projected rank/sensitivity loss and fresh-flat bias, score packed held-out predictions, and demonstrate the same matrix in deployed correction. In particular, `ExactPseudoInverse` is an explicitly requested numerical policy that can amplify arbitrarily small nonzero singular values; its synthetic success does not justify selecting it for a noisy measured matrix.

## CCR-006 — Native zero Header receipt requires external freshness evidence

**Severity if ignored:** High. **Confidence:** High. **Evidence class:** direct transport/API source and state-machine inspection. **Disposition:** narrow API semantics reviewed; operational association and private-core regression qualification remain open.

Reviewed PipeWireAO worktree `/home/dgamroth/workspaces/codex/pipewire/PipeWireAO-heart-calibration`, baseline `3c846025113eacb851b437c585c63f15bc057136`. Changed `src/ndarray_exchange.jl` SHA-256 is `3655fd47eed5e2b010592e27943762a076b6333aed2d4b7911d82f6643ee1f10`; focused test source SHA is `e4a6ceeb41c3fbcc1e127f823384b20797b2d210f08aca8d0565737e8daf83c8` at this checkpoint.

The new `allow_zero_sequence=true` admits an exact `UInt64(0)` expectation. Default zero rejection remains, and an `AcquisitionIdentity` still requires a positive sequence. The receive path continues to require exact Header equality, valid flags, exact payload contract, matching acquisition metadata when requested, and matching Header/acquisition sequence when metadata exists. The loop lock and pending/acknowledged/waiter checks are unchanged. Receive completion still returns the buffer before publishing the completed phase; duplicate or unarmed arrival faults rather than silently replacing the payload. No new concurrency defect is identified in this narrow change.

A constant native zero header cannot distinguish successive receipts after rearming. In particular, a delayed native reply with the same held figure could pass payload equality. The API explicitly makes no freshness claim. The owning HEART calibration protocol must establish the exposure/command fence and independently correlate native telemetry progression, actual applied physical figure, exact raw detector bytes and the admitted source acquisition identity. A relay-generated increasing sequence proves relay ordering only; it does not by itself prove freshness of the native payload. Unknown or inconsistent outcomes must fault and retain the existing ownership/restoration rules.

**Historical checkpoint:** The primary reports 164 focused exchange assertions passing. A separate existing private-core test observed only one available loan where its assertion requires at least two, followed by a timeout. Source inspection alone cannot establish that this is unrelated to the candidate. A matched before/after run with the same environment and private-core setup is required before attributing or clearing that failure. The reviewer has not launched a private core or host test. Evolving native telemetry/relay and OPD witness code are not covered by this narrow API review and require a later frozen-source verification.

**2026-10-04 follow-up:** the selected native held-calibration and Copper active exchanges now have actual full-rate association, payload, state/flag, reset and lifecycle evidence documented later in this review. This satisfies the operational obligation for those selected experiments; zero Header alone still establishes no freshness. The retained `zero-header-private-before.log` and `zero-header-private-after.log` each report7 passes and1 completion-deadline error in `wait_array_source!` at test line142. Their SHA256 values are `a790f84d2fa67e78b48f76b046caf8c8af72fcaa10f140b2ef4ab63814c1f168` and `1625bc6e3b4205ef15dc1bd0328ca7be95522142fb7be70f5e54e1fa60a5b3a8`. Those logs do not contain the earlier loan-count assertion failure. They establish occurrence of the deadline symptom both before and after; exact command/environment equivalence is still being reconstructed. The general private-core timeout is unresolved and is not represented as caused by, fixed by, or demonstrably unrelated to the opt-in API change. No new private-core run was performed by this reviewer.


## CCR-007 — Freeze the estimator and the deployed loss before selection

**Severity if ignored:** Medium. **Confidence:** High. **Evidence class:** direct plan comparison and algebra. **Disposition:** policy ambiguity resolved before acquisition; execution and final results remain unreviewed.

The first full-cohort wording said to fit D, use half the projected repeat difference, and score both absolute and signed outputs. It did not specify the paired estimator, whether the repeat discrepancy included the physical basis, or which loss determined eligibility and ranking. These choices can change the selected rank and matrix without changing the measured data. The primary clarified the plan during review:

```text
D̄ = (D₁ + D₂)/2
δ = ½ ‖Q(D₁ − D₂)U‖₂
cutoff candidates = δ, 2δ, 4δ
J = Q D̄ U
R = W TSVD_AOC(J) Q, with B W = U
primary loss per direction = Σ± ‖B R y± − (±q)‖₂²
```

Here q is the actual represented Float32 physical probe, R is the packed candidate, and y is absolute native measurement input. Signed-difference loss is a diagnostic, not the eligibility or ranking rule. Candidates must beat the zero-command predictor in every declared nonzero validation direction group in both repetitions. The winner minimizes worst-repeat physical squared error, with the declared larger-cutoff/family tie order. Zero-rank and nonfinite candidates are ineligible; an empty eligible set is an outcome to retain, not permission to retune the grid.

This is scientifically defensible as a finite-corpus comparison. The scale δ includes noise, order effects and other repeat differences; two matrices do not provide a calibrated confidence interval or a bound on true operator error. Independent validation and the selected-only locked test test utility without claiming such a bound. All projection, spectra and discrepancy calculations must use the same frozen reference and physical basis. The helper's numerical B-rank tolerance retains all 250 nonzero directions for the actual map; the measured optical rank remains an experimental result.

The stated signed command-energy ratio is correct: `(1024 × 277 × 0.01²)/(554 × 0.04²) = 32`. The signed-batch/exposure cost ratio is 1024/554 ≈ 1.848, not 32. These refer to different resources. Report both, with settling/restoration overhead, so any Hadamard benefit is not attributed solely to estimator family. The single-actuator precision screen does not establish dense-probe linearity; held-out forward and deployed reconstruction/correction evidence must supply that check.

The fixed validation/test physical-basis columns plus independently seeded mixtures are adequate for the expressly finite-corpus utility claim. They do not certify every direction in a 250-dimensional space. The separate 64-direction spatial study must freeze its exact represented basis, rank, amplitudes and seeds before admission and score its measured span; it cannot inherit full-domain acceptance from the zonal/Hadamard studies. FGN/JFG comparison must distinguish paired identical-input implementation agreement from independently seeded repeat precision.

If y± are N=64 batch means, selection validates those means. Preserve that fact in the score schema. It does not establish single-exposure command variance, rate performance or feedback stability. Per-frame packed-output diagnostics and actual deployed correction remain separate evidence. Fresh flat-lamp bias and lost projected sensitivity must remain visible even when the frozen training reference is nearly cancelled.

Required remaining verification: bind the precise plan/reference/maps/U and Float32 held-out files, recipes and operational source snapshot before admission; independently check candidate construction, actual cutoff units, eligibility/group aggregation, tie handling and locked-test separation against those frozen bytes. At this checkpoint, the clarified plan SHA-256 is `41b194f4339877e512c69a3a2090a8e16050ced4ec9d66d49eae6efe9494f35f`. The inverse helper remains `4a885b5f2301e91e7545bdb6cffb4dc66f315b5cdd9c92fc4387989d8491342c`. This is a review checkpoint, not an assertion that later plan edits share that hash.

Current method source now selects Classic/Copper explicitly, derives 376/3600 measurement extents, requires the Copper 14-bit rail and at least one discarded exposure, and checks retained **completed** owner diagnostics for upper-rail saturation. These changes address the prior hard-coded scope at source level. This bounded review has not qualified the final installed method run or all backend paths.

## Native HEART owner source checkpoint

Reviewed `deployment/hil/heart_calibration_owner.jl` SHA-256 `6b9e823f22d3e1312d52a573009cdf7b995691f805b71c5ba20f539503337d07` and `deployment/hil/heart_calibration_telemetry.jl` SHA-256 `d7e0a3781da3b4eb06b954d1f831cd67dba01cbe6fded1968b6d690223ea5097`. No native host launch or new broad test suite was performed by the reviewer.

The source-level association argument is coherent for its declared fresh, exclusive, serialized topology:

- Native `hrtTfcBlock.c` assigns no RUN processing callback; `hrtClwcBlock_run` performs state changes without ordinary integration. RUN preserves the WFS/native output path needed for direct physical probes. The owner requires a fresh supervised generation, zero admitted source cursor, and RUN/ENABLE acknowledgements before exposing the calibration endpoint.
- Each physical shape is immutable, one zero-ID receive slot is armed before the native command, and the next DM telemetry bucket must have sync zero. The public SPA decoder uses Float32(Float64(native µm) × 10⁻⁶), exactly the conversion checked by `confirm_probe`. The received metre vector is then relayed with a separate positive probe token and checked against actual public plant adoption. Native clipping is reported from actual versus requested physical bytes. Multiple outputs caused by native slew retries are not silently relabelled as one accepted next bucket.
- One exposure is armed before publication. Exact raw ADC bytes, consecutive raw/measurement buckets, next native sync, stable mapped acquisition domain/generation, consecutive source sequence and nonoverlapping model intervals are checked before source completion. The session-local domain value 1 is backed by the full domain retained in the ordinary owner report; it is not a truncated UUID. Association disagreement faults reuse.
- Copper preserves `cbHoGrad0` values and separately reads calibrated telemetry for the intensity diagnostic. The preceding completed pupil mean determines native normalization. One valid discarded lamp frame primes it; the diagnostic calculation does not replace native normalization. Classic order/scale are explicit configurable conventions; defaults preserve native units/order and establish no cross-frontend angular equivalence.
- Release requires no pending association, receipt, publication or plant exposure. Restoration is still enforced by the shared calibration coordinator. This initial-calibration owner finishes in held native RUN and shuts down; ordinary correction requires a separately prepared deployment. Finite file bounds and common operation deadlines do not establish real-time latency guarantees.

No confirmed consequential unit, hold or association defect was found in these selected source paths. This does **not** close CCR-006: first bucket/sync assumptions, effective native flags, exclusive fresh UDP endpoints, absence of delayed commands, full-rate file publication, actual adoption, restoration/release and fault cleanup require live evidence. A matching zero-header payload alone remains insufficient evidence of a fresh command. Native PID existence checks are not a replacement for the supervising process owner's lifecycle identity and exclusive ownership. Final qualification must bind the actual native configuration and transport topology as well as these source files.


## Selection implementation review

Initial reviewed `calibration_selection.jl` SHA-256: `e963d231e1629240a2f6886bd2de7a1a013b220bdbaea541035fd67c143b377a`; initial test source: `b7e2bebe857e571d1faecb4b9586e9b589f27665bc3177a3c35288fb580891d7`. This module is cold analysis, not acquisition or deployed correction.

The implementation correctly averages the repeated forward operators, measures the spectral norm of their reference-projected difference in orthonormal physical coordinates, and supplies an absolute TSVD cutoff with zero relative tolerance to the public AOC helper. Candidate matrices are packed Float32 by that helper; zero effective rank is exposed as ineligible. Signed probe pairs must be opposite physical figures around zero. Groups must partition their pair indices. Absolute scoring includes the baseline in each measured input, then computes physical B R y and loss against represented ±q. Signed-difference loss is separate. Forward diagnostics retain both raw and projected response discrepancies.

The synthetic bias fixture is discriminating: an inverse with perfect signed-difference recovery but a constant physical offset produces absolute SSE 8 and is ineligible. A source-level qualification limit remains: these scores evaluate packed coefficients with Float64 accumulation, not the native engine's Float32 accumulation sequence. Their result must not be described as an actual deployed arithmetic measurement. Preserve the separate engine/correction check. Scoring callers must also reconstruct actual Float32 figures from any JSON plan before Float64 analysis; a shortest Float32 decimal parsed directly as Float64 need not equal the exact represented command.

The frozen-direction `identity.json` independently matched all 19 listed file SHA-256 values at this checkpoint. Validation and locked-test plans contain 16 signed probes and N=64, with detector seeds 551/552 and 553/554 respectively. The actual plans, not a regenerated later SVD, remain authoritative for direction identity and chronology.

### CCR-008 — Tie-break compares grid index instead of physical cutoff

**Severity:** Medium. **Confidence:** High. **Evidence class:** directly reproduced policy mismatch. **Disposition:** corrected and independently verified in the source checkpoint below.

Affected code: `CalibrationSelection.select_candidate`, tuple used by `sort!`. The frozen rule prefers the larger cutoff after equal worst-repeat physical loss. Initial code uses `-candidate.multiplier`. Because each family has its own empirical repeat scale, multiplier ordering is not cutoff ordering across families.

Independent Julia reproduction used two otherwise eligible candidates with equal losses in both repetitions: zonal multiplier 1/cutoff 10, and Hadamard multiplier 4/cutoff 4. Initial code returned index 2; the declared rule requires index 1. This is an implementation discrepancy, not a proposal to change the scientific policy.

Remediation: sort on the finite positive absolute cutoff, then the declared lexical family order. Validation: retain this exact unequal-scale counterexample, a same-cutoff lexical tie, and ordinary unequal-loss ordering. No measured data is needed to adjudicate this defect.

### CCR-009 — A single repeat can authorize selection

**Severity if promoted:** High. **Confidence:** High. **Evidence class:** directly reproduced admission gap. **Disposition:** corrected and independently verified in the source checkpoint below.

Affected code: `CalibrationSelection.select_candidate`. Initial admission requires only a nonempty score list, while the frozen cohort requires both independent repeated validation acquisitions. The same isolated call accepted a candidate supplied with only one passing score. An omitted or failed second acquisition could therefore be silently excluded unless a separate caller happens to reject it.

Remediation: this fixed-policy selector must require exactly two validation score sets per candidate, or require and verify an explicit immutable repetition identity set. A count check prevents accidental omission; orchestration/provenance must separately prove that the two supplied records are distinct declared acquisitions. Validation: reject empty, single and extra-repeat inputs and any failed/nonfinite required repeat; accept the complete two-repeat corpus. Do not fill a missing repeat by duplicating an existing score.

Both counterexamples were run independently with Julia 1.12.7, one Julia thread, `--compiled-modules=existing`, and the already prepared `fgn-bright-reference/training-package/hil` environment. No package environment mutation or native transport was involved.


### Selection remediation verification

Final reviewed helper SHA-256: `571838afb86b1434cea903f4c409b7dece284d93e070abb715f30aeb4fe076e1`; test source: `f9d06c1db4fb152faca5b4338b5a5411a0ebfe34d53fc928291be3786c3ecb68`.

The primary changed the sort key to negative absolute cutoff and required exactly two scores for candidate eligibility. Independent replay of the identical unequal-scale counterexample now returns index 1. Independent replay of the one-repeat call now throws `ArgumentError`. The focused selection suite was also run independently: 22/22 assertions passed (14 absolute-scoring/selection and 8 repeat-scale assertions). This closes CCR-008 and CCR-009 at helper level before full candidate analysis. Final orchestration must still bind the two distinct declared repeat identities, actual packed physical figures and score-to-candidate hashes; two references to the same score would not be independent evidence.

No remaining selected-policy formula defect was identified in this helper checkpoint. The previous finite-corpus, averaging, deployed-arithmetic, forward diagnostic, locked-test and correction limits remain in force.


## CCR-010 — Distinguish the estimation inverse from the correction polarity

**Severity if ignored:** High. **Confidence:** High. **Evidence class:** observed source/configuration and derived feedback equations. **Disposition:** confirmed composition requirement before deployment; no completed wrong-polarity correction run is alleged. The primary identified this issue before validation or correction and requested independent verification.

### Source evidence and conventions

The exact Copper qualification base is `~/.cache/rtc-calibration-completion-20261003/fgn-high-reference/qualification-base`. Its `graphs/graph.conf.in` SHA-256 is `62a142981a1d17f07a071a56990263ec12583b57bf4d8d771be3f567bc3184b8`. It connects reconstruction directly to `control:residual-error`, selects gain **+0.01**, pole **0.99**, anti-windup gain **0.99**, hidden-mode gain **0**, and physical command bounds ±0.8 µm. Its 277-element system-flat payload is exactly zero. The graph adds the system flat after the forward controller/VDM maps and before physical clipping.

The FGN provenance binds algorithm revision `518a57897004deb70000f2e71c3fe240911f4937`. Independent `git show` inspection of that revision's `crates/calculon-algorithms/src/algorithms/control/closed_loop_correction.rs` confirms subtraction of delayed constraint feedback followed by **addition** of gain times residual error. The current Julia `FilterGraphAlgorithms` implementation has the same recurrence. This source comparison establishes the recurrence; it is not a new binary-equivalence measurement.

The copied AOS `hil/packages/AdaptiveOpticsSim/src/algorithm_graphs/native_nodes.jl` SHA-256 is `924dd7ff58ea9db27424c165a7762443c12fec8ff3c3fa1afb2410cac59e874f`. `step_graph_node!(_PupilOPDCompositionOwner)` adds surface OPD to uncompensated OPD. Both are optical path difference, and the physical command conversion from µm to metres introduces no sign change or factor two.

Let c be the 253-coordinate controller output, f the delayed mapped constraint feedback, p the pole, g the loop gain, a the anti-windup gain, and e the reconstructor output. With hidden-mode gain zero, the source recurrence is

```text
stateₖ = cₖ₋₁ − a fₖ₋₁       (after the first committed output)
cₖ     = p stateₖ + g eₖ
q_req  = B cₖ + q_flat
q_dem  = clip(q_req)
φ_res  = φ_uncompensated + DM_OPD(q_dem)
```

Constraint feedback is derived from requested minus demanded physical commands through the retained reverse maps. It is zero when there is no clipping; no assumption that the reverse map is B's inverse is needed for the unsaturated sign argument. Initialization uses the declared initial state with no previous feedback, rather than inventing a previous physical command.

### Required artifact composition

The measured forward operator has the convention δy ≈ D(+q). Therefore the selected estimation inverse `R_est = W K Q` is evaluated as `B R_est y ≈ +q` on represented positive probes. A cancelling correction with the preserved **positive** Copper loop gain requires

```text
R_ctrl = −R_est
B R_ctrl y ≈ −q
```

This sign is a declared output-coordinate/polarity composition. It changes neither the measured D nor its cutoff, retained rank, reference rejection, controller gain, pole, anti-windup or physical limit. Keep separately named/sealed estimation and deployment artifacts and record the factor −1 in provenance. Do not negate D, negate the training target silently, or apply the sign twice during installation. The earlier selected Classic configuration has a negative gain (−0.3), so this Copper sign must not be applied indiscriminately to Classic.

The frozen estimation selection remains unchanged. Equivalently, the deployed-polarity matrix can be scored against the negated physical target:

```text
‖B R_est y − q‖₂² = ‖B R_ctrl y + q‖₂²
```

Negating finite Float32 coefficients is exactly representable, preserves zero null-coordinate rows numerically, and leaves reference-response norms unchanged. Native engine accumulation and installed matrix identity still require their separate checks.

### What the preserved leaky controller can establish

For a deliberately ideal scalar retained mode, assume a constant equivalent disturbance h, exact reconstruction of that mode, no clipping, zero system flat, and one-frame command feedback. Correct polarity gives

```text
cₖ = (p − g)cₖ₋₁ − g h
h + c∞ = [(1 − p)/(1 − p + g)] h
```

For p=0.99 and g=0.01, the scalar multiplier is 0.98 and the limiting residual fraction is 0.5. Wrong positive estimation polarity instead gives multiplier p+g=1 and a nonzero constant driving term; in this idealization the command drifts rather than cancelling. Thus the sign is consequential even though leakage makes the wrong-sign scalar multiplier exactly one rather than greater than one.

A bounded arithmetic illustration from zero state gives residual 0.5087939733 h after 200 correct-polarity updates, versus 3 h with the wrong sign. This is an analytical recurrence illustration without clipping, detector noise, unretained modes, variable atmosphere, delays beyond the declared step, or a native transport. It is not simulated or hardware correction evidence and is not an acceptance threshold. Actual correction need not approach zero with these fixed coefficients; judge the predeclared finite deployed utility and retain physical OPD diagnostics.

Required validation: seal both polarity-related matrices and their exact relation before correction; verify actual installed reconstructor bytes, unchanged controller properties and map/units; check a bounded positive/negative physical mode for opposing initial correction and retained finite output; then run the separately declared correction corpus with clipping, normalization, latency and optical residual evidence. Scientific inverse selection does not itself close this deployment gate.


## Cold cohort-driver review before held-out scoring

Reviewed cache drivers `analyze_copper_cohort.jl` and `score_copper_cohort.jl` under `~/.cache/rtc-calibration-completion-20261003`. These are separately identified cold scientific drivers, not production acquisition changes. No new native run, full matrix fit or held-out acquisition was launched by the reviewer.

The fit uses two distinct detector seeds/runs, checks equal represented canonical physical figures, averages the physical interaction matrices, and calls the reviewed selection helper. `CalibrationClient.prepare_plan` converts command figures and amplitudes to Float32; `validate_result` likewise returns Float32 reported batch means. Applying the inverse chronology permutation after validating increasing exposure identities restores the canonical signed-pair order. This is correct only when the chronology and actual plan files are themselves verified; CCR-011 below establishes the missing check found in the initial driver.

Candidates retain separate packed Float32 estimator files and Float64 mean forward operators. Selection evaluates all candidates on both independent N=64 validation acquisitions, with the fixed first-four basis-direction and last-four mixed-direction groups. It selects by the reviewed worst-repeat absolute physical loss and packs the controller artifact as the exact negative estimator. The locked-test path reuses only those selected bytes, writes the failed result before throwing if utility fails, and does not refit. Fresh-flat physical and controller command norms are reported separately; these norms characterize the one retained independent flat mean, not a population confidence interval or per-exposure distribution.

The partial spatial calculation is dimensionally correct: F contains the represented positive physical figures divided by their declared mode amplitudes, the measured matrix estimates D F, and `(D F) F⁺` is an extension on the measured physical span. It is not a full-coordinate inverse. Independent NumPy SVD of the actual frozen Float32 figures yields F shape 277×64, rank 64, singular extremes approximately 15.8618593 and 3.0883108, and numerical rank tolerance 9.7561×10⁻¹³. The driver reports held-out span residual and raw/projected forward errors. Utility outside that span is not established. A geometric residual caused solely by representing a mixed held-out figure as Float32 must remain visible rather than be silently projected away.

All 30 `cohort-admission-identity.json` file hashes independently matched at this checkpoint. The frozen polarity identity's policy and addendum hashes also match. The copied selection/inverse helpers match the previously reviewed fixed hashes. Training/validation/test identities remain separate; no new loss, cutoff or sign convention is selected from held-out results.

### CCR-011 — Unverified chronology could silently change response association

**Severity:** High. **Confidence:** High. **Evidence class:** isolated fail-before/pass-after experiment. **Disposition:** corrected and independently verified before held-out scoring.

The initial `read_method` verified the hash of `prepared-identity.json` but did not verify the files listed within it. It then used `prepared-specification.json` and `canonical-order.json` to regenerate figures and reorder numerical means. Its comment claimed validation against ordered figures, but the CLI response batches contain only values, validity and exposure identities. `CalibrationClient.validate_result` validates run, extents, completion and chronological exposure identities; it cannot compare a command that is absent from that response format.

In an isolated copy of the completed FGN zonal-1 evidence, the reviewer reversed only `canonical-order.json`. Initial `read_method` accepted it, returned reversed numerical responses against unchanged canonical figures, and returned the same preparation identity hash. Observed output was `changed_order_accepted=true`, `same_seal=true`, `same_figures=true`. Original acquisition files were not changed.

The primary added checks of every prepared file and package-file hash, stage-result hash, actual recipe/method against the independently frozen files, canonical public plan against its sealed representation, frozen direction plan when present, and ordered plan against the sealed actual interaction plan. Independent replay on a complete fixture accepts the unchanged copy and rejects the identical chronology mutation with `evidence hash differs: canonical-order.json`. The retained pass-after fixture is `ccr011-review-u4yk3so3` under the study cache; unchanged inputs are read-only hardlinks and the mutated chronology is a separate copy. This closes the demonstrated association defect. It does not make the CLI response alone a proof of physical command identity; that still comes from the sealed operational plan/coordinator evidence.

### CCR-012 — Candidate and score inputs must share the original maps/reference

**Severity if promoted:** High. **Confidence:** High. **Evidence class:** direct source omission and independent mutation rejection after remediation. **Disposition:** full inverse and spatial paths corrected; independent verification is recorded below.

The initial scoring driver reopened the command-map provenance, reference pixels and independent flat qualification mean without comparing them to the candidate preparation identities. Locally valid current files could therefore score a candidate against a different input tuple. Hashing such a file only in the final report would describe what was read but would not enforce the previously fitted tuple.

The primary added `selection_inputs`, which verifies the frozen policy, candidate base-provenance identity, reference-result manifest identity, every manifest artifact, exact fitted reference and independent flat hashes before returning inputs. Candidate preparation verifies the complete reference manifest and records these identities. Locked scoring additionally checks the selected preparation and polarity identities.

Independent isolated fixture `ccr012-review-xv_vrvop` accepts the unchanged input set. A single-byte change to reference pixels is rejected at that artifact's hash check; the same change to the flat mean is rejected at its hash check; a provenance-byte change is rejected as `candidate command-map provenance changed`. Each mutated file was separately copied and restored; original study inputs were untouched. No full candidate matrix or held-out measurement is needed for this check.

At this checkpoint, `spatial_forward` still read its projection reference directly and did not bind that reference in its output. The reviewer requested reuse of the checked reference path and retention of its identity. This is a provenance correction, not a changed spatial estimator or threshold.

Driver checkpoint hashes after the full-inverse remediation: analyzer `cfb3af5dca54da15c770f00997e02c0037acfbbb95f8e14894df4adf45bf8a61`; scorer `487f6fd6693c4360f0b8f387be5d610cd0f6d1d4229c6ff22719e23e09ab3d10`. Final scoring outputs must bind the final driver/helper hashes and the distinct retained acquisition identities, not just these review-time filenames.


### Final CCR-012 verification and actual FGN training-grid audit

Final scorer SHA-256: `0c2d722ca7ad3748250854e1f8197051d73968e2aeda45a33526415affb9963d`; analyzer remains `cfb3af5dca54da15c770f00997e02c0037acfbbb95f8e14894df4adf45bf8a61`. `spatial_forward` now obtains its reference through the same checked `selection_inputs` path and retains reference, reference-manifest, candidate-preparation, analyzer and helper hashes. The reviewer repeated the isolated input mutation checks with this final source: unchanged inputs pass; changed reference, flat mean and command-map provenance each fail at the corresponding identity check. CCR-012 is closed at driver level. The spatial acquisition/scoring run itself is still pending and is not claimed by this source/fixture verification.

The controller packing code now explicitly writes positive Float32 zero in rows 1–3 after verifying that these are exactly the zero columns of B. The other rows remain the exact negative estimator. This preserves the stated literal-zero wire contract without changing physical predictions.

The six actual FGN/CUDA training candidates are bound by `fgn-candidates/preparation.json` SHA-256 `18ef48e356e0a2f1326dc15d229ed19474ba3a7882130f98c32c71a6bb7213d4`. They were independently inspected with NumPy and one OpenBLAS thread. The audit re-read and hashed the four measured Float32 interaction matrices, recomputed both Float64 paired means, rebuilt the orthonormal physical basis from the exact command-map bytes, independently evaluated both projected spectral repeat scales and singular-value cutoffs, checked every packed candidate/mean-forward artifact hash, and checked finite Float32 values and literal positive-zero null rows. All checks passed. The recomputed scales agree within relative 10⁻¹²; retained ranks agree exactly. The recomputed packed physical reference-response norms agree within relative 10⁻⁷ and absolute 10⁻¹², a cold cross-library numerical check rather than a scientific tolerance.

| Family | Multiplier | Absolute cutoff | Retained rank | ‖B R_est r‖₂ after packing |
| --- | ---: | ---: | ---: | ---: |
| Zonal | 1 | 4.64009127 | 221 | 3.81890209×10⁻⁶ |
| Zonal | 2 | 9.28018255 | 185 | 9.09618105×10⁻⁷ |
| Zonal | 4 | 18.56036509 | 135 | 9.28324535×10⁻⁸ |
| Hadamard | 1 | 0.82306637 | 248 | 1.35884809×10⁻⁵ |
| Hadamard | 2 | 1.64613273 | 235 | 7.77829835×10⁻⁶ |
| Hadamard | 4 | 3.29226546 | 219 | 3.30842417×10⁻⁶ |

Training identities record independent seeds 531/532 and 533/534. Recorded relative matrix repeat discrepancies are approximately 0.256791 for zonal and 0.0460814 for Hadamard. Recorded signed command energies are 0.88639996 versus 28.36479873, preserving the declared factor 32. Per repetition, accepted exposures are 8,864 and 16,384 respectively, excluding discarded/restoration exposures. These statistics describe unequal-cost training experiments. A lower repeat discrepancy or higher retained rank is not by itself held-out utility, accuracy or closed-loop acceptance. No candidate has been selected by this review.


## Correction preparation and diagnostic review

The cache-only `prepare_copper_correction.jl` initial reviewed SHA-256 is `7e467455d4e242f5f93821dba4cc64fae255242583da9888a820a2d5a58dcf4a`. Its test fixture SHA is `06c701331d576244fed133cf49a2de2446203a7c039158559a2c8912e518a31c`. The primary/worker reports 86 synthetic assertions; the reviewer read those tests and independently invoked the input-admission function on the provided synthetic fixture. No actual correction package was launched.

The preparation implementation preserves the pinned complete baseline identity, validates the FGN/JFG/CUDA tuple and startup reconstructor binding, and requires a fresh nonoverlapping output. It verifies the exact −R_est controller bytes with positive-zero rows 1–3, the frozen polarity declaration, measured background/reference/flat identities, unchanged maps, graph, plant and package environment. It retains the normal seed-1 moving atmosphere, 2 ms exposure/model interval, declared 100× brightness and noisy 14-bit detector. Only the selected reconstructor, four explicit diagnostic/owner helper files, bounded frame count and diagnostic option are replaced; the new package and source/input checks are sealed afterward. The complete baseline check preserves anti-windup and other graph coefficients even where individual assertions mention only gain/pole. These are appropriate cold packaging constraints, subject to the selection-admission gap below.

### CCR-013 — Initial correction admission did not establish frozen validated selection

**Severity:** High. **Confidence:** High. **Evidence class:** independent isolated admission experiment. **Disposition:** primary independently confirmed the finding; the software admission gap is corrected and independently verified below. The actual FGN complete-corpus pass-after is recorded below; other engine/tuple admission remains conditional on its own approved corpus.

`selected_inputs` initially accepts `locked.passed=true` with two `eligible=true` score entries and two distinct identity/seed values, plus internally consistent selection/locked file hashes. It does not require the selected estimator/name to be one of `preparation.candidates`, require the two validation scores that selected it, or bind the retained validation/locked identities and seeds to their independently frozen plans and actual acquisitions.

The supplied synthetic fixture is useful for testing matrix installation, but also exposes the missing scientific admission gate. Independent invocation of `selected_inputs` returned successfully with:

```text
accepted_selection=synthetic-test-only
candidate_grid_present=false
validation_scores_present=false
locked_seeds=[1041,1042]
```

The reviewed frozen locked seeds are 553/554. This experiment used temporary evidence only, no GPU kernels, no transport and no deployed correction. It does not allege that the real scoring driver generated a false result; it shows that the final preparer cannot yet distinguish that result from a self-consistent incomplete record.

Required remediation: verify candidate membership by name and exact estimator hash, verify the validated winner through the reviewed policy and bound two-repeat scores, and bind validation/locked acquisition identities, CLI result hashes and exact frozen recipes/plans/seeds. The full raw scientific analysis need not be repeated during package copying if a complete immutable scoring record is checked. A hash-linked `passed` flag alone is not that complete record. Preserve the no-retuning/selected-only locked-test policy and fail before creating a correction package when any required evidence is missing. Required validation includes this same no-grid/no-validation fixture, a substituted non-grid estimator with refreshed internal hashes, omitted or wrong held-out identities/seeds, and a complete correctly bound passing corpus.

### OPD diagnostic source checkpoint

Reviewed production helper hashes:

- `analyze_correction.jl`: `09ed414d161c3b06364b5b96c684f64b0f51b718651f4d934525701dba00699e`.
- `correction_truth.jl`: `711fcbdd593195691da7bf4d9b1dfe2880cf672cbc5874980f0e714b57675b50`.
- `simulator.jl`: `98218568068ed65a9121802f268347129f0f35ba07a523279e8c2cceed470a47`.
- Focused analyzer test source: `5b60a5b05f709a354cfc0266be3fc86f8737b3e1fe6991ef7eeb1fb6c99c6649`.

The new Copper path requires a direct live OPD witness and selects the recorded CPU/CUDA/AMDGPU backend without fallback. It validates the package/backend and exact graph/payload/helper identities; the detector contract is 64×64 UInt16 within the 14-bit rail. Replay first advances the graph, measures frame n, and only then adopts retained command n for frame n+1. Source-side witness recording after exchange reads the completed frame's public OPD outputs before another model step. The witness is never passed into calibration or reconstructor inputs.

The public pupil mask is materialized once on the host. Three prepared Float32 staging matrices receive atmosphere, pupil and DM surface products before host variance/hash operations. Inspected local CUDA/AMDGPU copy implementations synchronize device-to-host completion; no scalar device iteration or silent CPU simulator substitution is introduced by these calls. This is source-level transfer review, not a GPU timing or determinism measurement. Hashing and transfers are opt-in diagnostic overhead excluded from cadence qualification.

The metric remains uniform public pupil-support population spatial variance after piston removal, in metre-OPD squared, accumulated in Float64. No wavelength or reflection factor is inserted. A present direct witness must match replayed per-frame hashes, variances, sequence and model time exactly; ADC equality cannot override a witness mismatch. The separate zero-command replay checks the same atmosphere, zero surface and pupil equal to atmosphere before any correction ratio is promoted. ADC mismatch remains reported when direct OPD agreement supplies the verification basis. Classic CPU retains its previous no-witness exact-ADC gate.

No consequential numerical, unit or frame-order defect was identified in these helper changes. Actual backend replay, unchanged-package identity during acquisition, finite correction utility, saturation/command-limit behavior and final process cleanup remain experimental gates. The diagnostic's rail-proximity statistic is explicitly not requested-minus-demanded clipping feedback, and the final recorded command has no subsequent observed frame.

Independent focused verification of `deployment/hil/test_analyze_correction.jl` completed with **264/264 assertions passing**, using Julia with one thread and existing compiled modules. These tests include device-like fixtures and mocked backend selection; they launch no RTC or accelerator kernels and do not establish real GPU replay or correction acceptance.


## CCR-013 remediation verification

The public preparer now requires the frozen six-member zonal/Hadamard grid and the exact selected estimator membership before installation. A mandatory fresh cold checker runs in the captured HIL project, loads the reviewed reader/scorer source snapshots, and verifies the source ledger, frozen plans, acquisition aliases, preparation/package seals, lifecycle/ADC checks, CLI results and intended seeds. It recomputes all twelve validation scores, the reviewed winner, fresh-flat norms, forward scores and both selected-only locked scores. It also verifies the packed controller is exactly −R_est with literal positive-zero rows 1–3. The package copy receives the fresh checker report and rechecks its bound input hashes before installation. The separate installation-only test seam is not scientific admission evidence.

The independently reviewed FGN preparation hash is pinned in the source ledger; fitting its six TSVD candidates is not repeated in this copying gate. JFG scientific admission is deliberately rejected until its own actual candidate preparation receives review and is approved. This is an explicit study boundary, not a general-purpose arbitrary-source trust mechanism.

The reviewer independently reran the former synthetic fixture through public `prepare`. It now throws `missing frozen candidate grid or intended seed identity`, and the output path remains absent. All fifteen source-ledger entries independently match their bytes. The reviewed tests also cover substituted estimator membership, missing scores, changed numerical scores/winner, wrong seeds/source/alias identities, and the four actual training acquisitions. The primary's reported 102 SDK assertions exercise installation mechanics and admission negatives separately.

Actual FGN validation is retained in `fgn-selection/selection.json`, SHA-256 `dac2771178e3f019e6b2baf04cceaff0ffebf560f89b4f2703cfd1eaccabead6`. The two N=64 captures use the declared seeds 551/552 and logical-to-physical retry alias. A read-only recomputation checks all twelve reported inverse scores exactly, the selected `hadamard-1` name and bytes, all six physical/controller fresh-flat norms, and four family/repeat forward scores. Exact equality is supported for this captured Julia/HIL/BLAS tuple with one Julia and one BLAS thread; no cross-library exact reproducibility is claimed. These checks do not replace the locked tests or a deployed correction experiment.

Reviewed remediation source identities:

- `prepare_copper_correction.jl`: `1dc08a3525a03b25e0640dbdb46265335da711042f3507b7d098e8c1e4b7b1d2`.
- `check_copper_correction_admission.jl`: `350b892fddb12511ba2896b3ab17439ad9fe4e3503fd12a0262635995ad45880`.
- `test_copper_correction_admission.jl`: `837bc31898da2eb7d46556345231ada105a8ddc67e17015edfe6ab1adb574071`.
- `copper-correction-admission-sources-v1.json`: `80be93945c6278a339d0146427b83e14956fbba7ac948c5ae9408cb0f22a6e17`.

Independent final execution of the cold HIL test file passed **70/70 assertions**, including the actual two-repeat validation recomputation. The retained reviewer log is `ccr013-independent-cold-admission.log`, SHA-256 `0024910f3b84a3a3dc4e251784b2893f163325b3bbf721cf3238040944f7eed3`. It used the captured FGN CUDA HIL project with existing compiled modules and one Julia/BLAS thread; it launched no RTC or accelerator kernels.

At this earlier checkpoint, a complete successful public admission report remained required after both actual locked-test captures existed. The following final checkpoint supplies that actual FGN result; no synthetic passing flag was promoted to it.

### CCR-014 — Global run-number uniqueness rejected the frozen held-out plan

**Severity:** High, as an admission blocker. **Confidence:** High. **Evidence class:** actual frozen metadata and independent discriminating replay. **Disposition:** corrected and independently verified.

The first CCR-013 checker required four unique run numbers across validation and locked acquisitions. The independently frozen plans use runs `[1,2]` in each family. Their detector seeds and bound acquisition identities distinguish them; the run counter is local to its plan family. The former condition therefore rejected every intended complete corpus before scoring, even though no acquisition was reused.

The corrected `held_independence` requires exactly seeds 551/552/553/554 in order and four distinct bound acquisition hashes. It retains unequal run numbers within each repeat pair. Independent replay reads the actual frozen plan numbers `[1,2,1,2]`: the old uniqueness condition is false and the corrected function accepts. Reusing a validation acquisition hash in the locked pair or substituting a detector seed is rejected. The focused regression additionally rejects duplicate run numbers within one family. No frozen plan, seed or scientific threshold changed.


## Complete FGN admission and Classic GPU analyzer final checkpoint

The checker now enters the newly loaded scorer world through one `Base.invokelatest(validate_corpus, …)` boundary. Inspection confirms that the extraction retains the previously reviewed grid, source, training lineage, acquisition, numerical, polarity and final hash checks. It changes Julia loading semantics, not the estimator or selection rule. Checker SHA-256 is `bfa1f96b9af64b70f87726d4d489959bd1925f26d3982746089905461e2216db`; the preparer and source ledger retain their identities above. Append-only audit `copper-correction-admission-identity-v4.json` SHA-256 is `75fcc73bdf74901f50bab19fe6f72041362e9490c8bf47a6314dfc68565ac2e6`.

The reviewer checked 4,145 audit/report source and input hash entries with no mismatch, including 4,125 inputs retained by the complete admission report. Independent full cold execution under the captured HIL project, one Julia/BLAS thread and `--depwarn=error` exited zero with an empty diagnostic log. It recomputed all validation and selected-only locked scores and passed. Its output `correction-admission-checks/fgn-reviewer-final.json` has SHA-256 `ae436c79560198c7300d920905b82d5a50c5b911e84efd0ab49c60946a369e5d`, byte-identical to the worker's retained final report. The selected member is `hadamard-1`; both actual locked repeats are eligible. CCR-013 is closed for this reviewed FGN tuple. This is finite frozen N=64 inverse utility and provenance admission, not deployed correction, hardware validation, timing acceptance or JFG grid approval.

The Classic GPU analyzer extension reuses the already reviewed same-backend OPD replay. It explicitly validates the selected Classic CUDA/AMDGPU package/provenance/owner arguments and backend dependency, requires the captured 12-bit detector contract and direct live OPD witness, and uses the 4095 ADC rail. It preserves the Classic CPU legacy admission path and Copper 14-bit contract. No backend fallback, gain change, reflection factor or numerical acceptance threshold is introduced. Direct witness and zero-command baseline failures remain disqualifying even if ADC bytes match.

Analyzer SHA-256 is `b9cac5e62f1bfa546c293169ab7a53c383c9f6535f8f876e45fc49670970fcea`; focused test SHA is `7824474299fc9b3979ee86b4258d10eb983d5c16cfdb5347d1083fdf961a4884`. Independent execution passed **324/324 assertions**, including the 60 added Classic GPU contract/replay checks. Reviewer log `ccr-classic-gpu-analyzer-independent.log` SHA is `ce940fb4dde23900dde9f99fd9d807862deb55827d51566508552912eea2506b`. Tests use mocked/device-like products and do not launch a GPU plant. No additional confirmed defect was found in this bounded analyzer extension; actual selected GPU replay is still required.

### CCR-015 — Finite correction runner can leave its launcher alive after shutdown failure

**Severity:** High. **Confidence:** High. **Evidence class:** source analysis and isolated shell-child fail-before. **Disposition:** corrected and independently verified before live correction; the original and first-remediation failures remain recorded below.

Initial cache runner `run_finite_correction.jl`, SHA-256 `3471775c8527ce278c064ee9332db617eff3fd132274221be25c1919cc79cac8`, records exceptions from `Deployment.shutdown` and then exits without signaling or waiting for the still-owned launcher. Public shutdown can throw while the process remains alive: absent startup state, rejected or timed-out control, or expiration of its caller-supplied 55-second wait. The function does not itself terminate the child in these cases. Merely retaining `shutdown_failure` does not clean up that owned process.

Independent isolated replay starts only `sleep 30`, invokes the same public shutdown against a fresh directory with no state file, and follows the runner's catch path. It records `runner_catch_leaves_child_alive=true`. The investigative probe then explicitly terminates and reaps its shell child; no RTC/private core/GPU runs are involved. Evidence `ccr015-shutdown-fail-before.log` SHA-256 is `496bf93f2eaae5f6137a246a770668182e16c76a146b6e2c6ffc4bd92cd6c324`.

Required correction: on public-shutdown failure, signal the known owned launcher with SIGINT and wait within the declared cleanup allowance; retain all cleanup outcomes and require its terminal status. A failed scientific batch must remain failed even if fallback cleanup succeeds. Validate the same missing-state shell-child invariant and the normal public-shutdown path before live use.

The normal batch sequence is otherwise consistent with inspected source: finite completion pauses the source; payload hashes are checked and copied before stop/reset; successful reset writes the reset report before its acknowledgment; restart follows that acknowledgment. Exact reset comparison uses scientific ADC/commands/direct OPD witness and excludes wall-clock timing. These source observations do not by themselves establish deployed reset repeatability.


CCR-015 first remediation checkpoint: a shared owned-process helper sends SIGINT with the campaign's 300-second cleanup allowance, then bounded SIGKILL and wait if necessary. Independent missing-state and signal-ignoring shell-child cases now pass. An additional already-exited child exposed `getpid(process)` throwing ESRCH outside the helper's catch, which would prevent lifecycle-record retention after a failed terminal launcher. This is a confirmed failure-reporting defect in the first remediation, not an unreaped child in that particular terminal case. The unchanged three-case reviewer probe is retained as `ccr015-independent-cleanup-probe.jl`, SHA `5351d4b48522800f21fde7771352f577524c8d0f21e99baf5432603837a7e094`; the initial helper SHA is `c6d549359e7efd5b80b069bc1891022b581dd36c3c320cd60527ffb05047bb72`. Fail-before log `ccr015-independent-cleanup-probe.log.getpid-fail-before`, SHA `3411851d12d37c1974fe0e58eb0a0dc0e9fc9e4301bf8d4d6fa10ccc1bbe7020`, records nine passing assertions and the terminal-PID error. The primary was notified; all probe children were reaped.


### CCR-015 final independent closure

Final helper `owned_launcher_cleanup.jl` SHA-256 is `47c1855355e0bf7437c05a5601a8cb4e7fdddf3a060e22f468ccdba60db791ed`. PID lookup is now observational and optional: an already-exited process retains `pid=null` while its known process handle supplies wait/exit/signal status. Final runner SHA is `4cd134284e469606e421bae67b71315e7bc7be54e52ae117d77f481b13f9a58f`. Its public-shutdown exception path records the failure and calls the helper; it never sets public-shutdown or scientific success from fallback cleanup.

The exact unchanged three-case reviewer probe now passes **10/10 assertions**: missing-state public-shutdown failure followed by SIGINT/reap; an intentionally SIGINT-ignoring child followed by short-grace SIGKILL/reap; and an already-exited child without a queryable PID. The pass-after log `ccr015-independent-cleanup-probe.log` SHA is `2f75b663b943a8968776736e28ea0d3fae4bb56244f787f14cf8cc0e6a53d5e0`. A separate already-failed `false` child verifies retained exitcode 1, reaped status and no signal, with log `ccr015-exited-failure-status.log` SHA `3cc2ab4da9be3ec681f35cde6733e2f1f3bf2a73df78f58cf89eff1dea905686`. All investigative children are gone. These are owned-process cleanup checks, not live deployment shutdown or descendant cleanup proof after forcibly killing a stalled supervisor.

The runner also now resolves the CLI/project through `pkgdir(PipeWireAODeployment)`, selecting the SDK already loaded by its explicit launch environment. It passes the immutable scientific package separately through `--deployment`; it no longer assumes that an HIL science package contains its own `julia` directory. The selected SDK must remain bound by the enclosing experiment's source ledger. No RTC/private core/GPU was launched during this verification. CCR-015 is closed at runner/helper level; actual lifecycle evidence remains part of the correction run.


## Classic GPU correction package preparation review

The reviewed cache-only preparer copies the already selected Classic CPU correction packages onto explicitly selected CUDA/AMDGPU simulator environments. It does not re-dark, change the selected inverse or regenerate graph coefficients. Source `prepare_classic_gpu_correction.jl` SHA-256 is `d1bbd95d8f6214b1a79949526af412ce2e19cba8176c09a11a7e33a414ca5a13`; its frozen baseline ledger `classic-gpu-correction-bases-v1.json` SHA is `9da1845c470ab9ea4d49135e7300f59962a75323e8f49428e7c7fb65507ffa7a`. The ledger pins the complete FGN/JFG CPU package bytes and the historical selected/locked proof files. The retained 221×376 Float32 inverse SHA is `bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813`.

Independent inspection of all four `backend-bases/classic-{fgn,jfg}-{cuda,amdgpu}-selected-v3` outputs checked 4,545 baseline, companion and deployment-artifact hash entries with no mismatch. Every actual file is covered by the artifact set except the descriptor itself, which the complete companion identity covers. There are no unexpected changes to retained baseline files outside the explicit descriptor/provenance, HIL project/manifest and four finalized correction helpers. All six local scientific package paths in each HIL manifest are present and contained within its own package. Graph, plant, calibration maps/background/reference/mask and local scientific sources remain byte-identical to the pinned CPU packages.

The retained model is the normal seed-1 moving atmosphere, noisy seed-0 12-bit detector, source magnitude 2, 2 ms model step and 1.896 ms exposure. Controller gain −0.3, pole 0.99, anti-windup 0.99, selected matrix polarity and physical constraints remain unchanged. CPU-derived simulated offsets are explicitly retained; this is a backend-transfer experiment and does not establish a GPU-specific detector calibration or physical-offset equivalence.

Actual resolved environments select CUDA 6.4.1 or AMDGPU 2.8.0. Independent comparison finds exactly the declared shared-record changes: `UnsafeAtomics` 0.3.3→0.3.2 and the `Pkg` weak-dependency representation (Pkg remains 1.12.1). No additional shared manifest change was observed after offline resolution. The failed original dependency-resolution attempt and preliminary v2 package remain separate historical evidence. Successful resolution and valid paths are environment-preparation evidence; GPU loading and scientific correction must still be measured. The AMDGPU environment explicitly retains the captured device-version override; it is not a claim of broader vendor hardware support.

The worker's retained preparation suite reports 184 assertions. The reviewer did not rerun this mutating suite. Instead, independent existing-package profile/analyzer contract checks, complete companion equality, occupied-output rejection and resolved symlink/input-overlap negatives passed **22/22 assertions** without acquisition, preparation or GPU imports. Reviewer script `classic-gpu-independent-review.jl` SHA is `77ce908c85d9260e94f3f2357aca66a69df06c3ae4ab7c3d13db3f557d7c0f23`; its log SHA is `bd6e8bd1e22d81edaf90a2bc9626bfc9f54381e179b3acc7047e74b18270d66c`. Audit `classic-gpu-correction-preparation-identity-v1.json` SHA is `e7d21a647caca6096750884d4b44c1699ba60a82ab99046ff6efab5d1d18fa1b`; all 35 additional source, descriptor, companion, declaration and helper bindings checked from that audit match.

No confirmed blocker was identified in this bounded preparation review. The result admits the four sealed packages to their separately owned experimental checks; it does not close backend replay, finite correction utility, unchanged HEART, cadence or hardware qualification.


## Full native HEART calibration review checkpoint

Prepared package `heart-calibration-copper-zonal-cuda-prepared3` has descriptor SHA-256 `93be47c8c7d2199ad6a59cae4cecce778c012cfe185097de67e9c3a277a1e4ed`. All **490** declared artifact hashes independently match. Its frozen physical interaction plan is byte-identical to the original `fgn-zonal-1/interaction-plan.json`, SHA `dfd2c32ba4e56d211eb4f8ee5bfc971d916d7972e125d9109cca8a533214ab1c`. The matched frozen method identity SHA is `67c40f966ebd01224fd172a96f91fcb748ae443b7068772f3f675b75d55775ed`; it binds detector seed 531, chronological plan/permutation and the exact public AOC/client bytes. The actual owner selects CUDA explicitly, normal noisy 100× lamp input, native integration hold and the serialized direct-command relay. The backend change does not move HEART's own scientific workers onto a GPU.

For 554 probes, N=16 accepted exposures and S=1 discarded exposure per adoption/restoration, the derived counts are 555 native DM records, 9,419 WFS exposures and 8,864 accepted captures. The selected limits are 200,290,944 capture bytes, 227,065,856 per native file/evidence stream and 70,693,888 public result bytes. Native raw/calibrated/gradient exact file sizes follow their 1,024-byte header and padded bucket layouts. The limit arithmetic uses checked products and additions. The frozen plan is neither reordered nor rescaled by the exporter. A full plan remains unlaunched at this checkpoint.

The live owner publishes one detector exposure, reads its raw/calibrated/gradient records, checks the complete integer acquisition identity, exact next native bucket/sync and raw ADC digest, then completes the corresponding plant exposure. Native DM receipt uses the intentionally exact-zero header option, a separate advancing relay token and exact native DM telemetry/physical figure checks. Thus header zero is not promoted to freshness. Final count verification checks each record's bucket, sync, completion, committed total and exact EOF extent, including absence of extra held-controller output. The first primary exposure failure is retained separately so a later reader teardown error cannot overwrite it. Unknown operation outcomes fault the owner. Native row pacing is an explicit transport setting; it is not proof of scheduler timing or sustained cadence.

### Independently checked bounded native pilot

The retained successful `heart-calibration-copper-pilot-evidence-v12-retry1.lifecycle.json`, SHA `bcbf7ade33035ba74e3c3a94462db36345791b2cca3651145f7e0c2468b05a2e`, reports restoration, release and public shutdown. Independent decoding of its retained native files confirms exactly 10 raw, 10 calibrated and 10 gradient records, plus four DM records, with no partial/extra bytes. Decoder log `ccr-native-pilot-count-review.log` SHA is `26a705d349e994f505f394f6e7e9fe322195f4de4e01514da2363ab9bf405e3c`.

The external owner evidence has exactly its reported 236 records and 75,295 bytes, SHA `14bc7addf2ea66caabc4fa89b7d208ca9a435264597619572fb811712acc8adf`. Its 10 exposure witnesses advance sequence/native sync 1–10 and bucket 0–9; only the declared first settling exposure is invalid. ADC diagnostics record maximum 4,417 and zero upper-rail pixels/frames. Final state is stopped and unadmitted; all six retained launcher/core/HEART supervisor/simulator/RTC/native HEART PIDs are absent from `/proc`, and the recorded runtime instance is gone. This confirms the retained bounded CPU/debug pilot's protocol outcome. It does not establish a full CUDA plan, a scientific interaction matrix, an inverse, correction, cadence or a hardware threshold. The nondebug prepared CUDA package is separately identified above.

### CCR-016 — Reduction accepts non-native results without acquisition or shutdown identity

**Severity:** High. **Confidence:** High. **Evidence class:** independent end-to-end cold reduction counterexample. **Disposition:** corrected and independently verified, including the actual positive bounded N2 collection/shutdown/reduction below. Full scientific cohort acquisition remains separate.

The initial `reduce_plan` accepts a state file with `phase=stopped`, no error and no cleanup errors without establishing that it belongs to the acquired deployment/session or that the owned instance/processes are gone. It then trusts three completion booleans and self-consistent hashes of a public calibration result and count JSON. It does not validate the count JSON's contents, actual native telemetry, retained capture files, raw/native association record, final owner report or their relationship to the supplied calibration means. Public `CalibrationClient.validate_result` validates numerical extents, finite means and increasing exposure identities; that common wire format does not identify which RTC produced them.

The reviewer supplied the real sealed prepared3 package and its exact expected descriptor hash, copied the already valid FGN zonal-1 CLI response into an isolated evidence directory, wrote an unrelated minimal stopped-state file and synthetic completion/count JSON, and called the actual public `reduce_plan`. No package or original acquisition bytes were modified. The function produced a 3,600×277 matrix labeled `engine=heart`, `status=complete-unaccepted-candidate`, although the fixture contains **no native telemetry or capture evidence**. This is a provenance error even though the artifact explicitly remains scientifically unaccepted.

Reproducer `ccr016-reduction-probe.jl` SHA is `364bee054d95a9f84422121851c036272103f0c5c89ae3b053a59625ff4293d3`; log `ccr016-reduction-probe.log` SHA is `e23de9b8d12f2b02b2e739777cf595f9ad7d8a60ff45c4263d2bbbaf7485e574`. Fixture `ccr016-fixture-1vkkCn` remains under the study cache. The probe performs only cold public AOC reduction; it launches no RTC, native HEART or GPU plant.

Required remediation is a complete native evidence contract: bind the admitted deployment/SDK source, runtime/session/native-child identity, frozen plan/seed and actual association; retain and reverify native telemetry, capture contents, command/response association and owner diagnostics under the declared ADC policy; require final shutdown of that same instance and retain its result. Bind/recompute actual response means rather than accepting refreshed self-consistent hashes of unrelated public results. The same fixture must fail before candidate creation, and a genuine complete retained native corpus must pass after public shutdown. No new algorithm, gain, threshold, extra exposure or HEART source change is required to fix this admission boundary.


## Frozen AMD transfer admission review

Reviewed cache driver `run_copper_amdgpu_transfer.jl` SHA-256 `202d378aa673e7ef1aa0492a1ea09eb0ae69c9f2343e84d9948d5a9235b2023b` and preparer `prepare_copper_amdgpu_correction.jl` SHA `d6052d1208b0fb5523c90a3923e03397cd2c1b178634f443a64ec50e4ee4af2b`. Frozen policy SHA is `37b9924e5787ee8cc331f069bf722ef0cdb706813a4902f41566ce2be7526155`; source ledger v2 SHA is `83b9ffe3eda8a6ec2029e5758957f20eca3741dce5281155f66fda7c371681d6`. Independent verification checked all 1,880 ledger file/root entries without mismatch.

The transfer keeps the actual CUDA-selected estimator and the two frozen N=64 locked directions/seeds 553/554. It uses the already reviewed immutable capture reader, requires the actual AMD backend/source/base/recipe/plan seals, exact 1,041 completed exposures per repeat, normal noisy 14-bit lamp, zero invalid/rail frames, restoration/release/public shutdown and physically identical represented commands/maps. It scores absolute physical errors through B R_est on both sparse and mixed groups in both repeats. It recomputes the unchanged CUDA locked scores for comparison; there is no AMD inverse fitting, reranking, reference replacement or threshold change. Matched seeds are explicitly not independent backend noise corpora.

The correction preparer requires a passing actual AMD pair and fresh cold full-report recomputation before creating the output package. The cold process selects the exact AMD HIL project with the explicitly pinned SDK v5 stack and one Julia/BLAS thread. It then copies the normal AMD base, the exact reviewed negative controller matrix and four frozen correction helpers, preserving all other scientific, environment and dependency bytes. Complete seals are rechecked after copy. The original CUDA preparer is unchanged. No confirmed significant admission or numerical defect was found in this bounded review.

Independent execution of the focused transfer tests passed **77/77 assertions** with `--depwarn=error`; log `amdgpu-transfer-independent-review.log` SHA is `afcb36740e2795ce9440c2979f1adb2e8eb55a386e18369c2c3344bb047d4c3b`. Tests use actual frozen CUDA captures for numerical checks and explicitly reject missing actual AMD transfer evidence before output creation. They import neither CUDA nor AMDGPU and launch no owner. Actual AMD acquisition, successful positive transfer admission and normal dynamic correction remain required; this review does not pre-approve those outcomes.

## Actual JFG grid construction review and bounded ledger approval

The new JFG preparation is `jfg-candidates/preparation.json`, SHA-256 **`9ca3f99d3aebed4e24a9edfd36cb1888120657ae2bcd29e3364aa5f47877fe17`**. Independent verification checked 2,524 prepared file/package seals across all four training acquisitions, their completed lifecycle flags, detector seeds 531/532/533/534 and zero invalid/upper-rail counts. Zonal repetitions report 9,419 total exposures each, Hadamard 17,409 each. Four raw interaction matrices, public CLI result files, canonical plans and chronological permutations are byte-identical to their corresponding FGN acquisitions. All nine scientific parameter payload identities match FGN; the fitted reference, independent flat, policy and numerical helper identities also match. The newer analyzer identity is the already reviewed reader version that adds alias/normalized-input handling, not a changed fitting equation.

An independent NumPy/OpenBLAS-one-thread calculation rebuilt B, its rank-250 physical basis and controller lift, Q, paired Float64 means, projected repeat scales and SVD inverses. Both stored forward means match recomputation exactly. The six ranks remain zonal 221/185/135 and Hadamard 248/235/219; spectral scales agree within relative 10⁻¹². The packed matrices are finite, have exact positive-zero rows 1–3, and differ from independently reconstructed Float64 inverses by relative Frobenius errors about 2.52–2.54×10⁻⁸, consistent with their declared Float32 representation. Packed reference-response norms were independently recomputed. This numerical comparison is not a new scientific acceptance tolerance.

The six JFG packed inverse files are **not byte-identical to FGN**. Only 8–17 of 910,800 coefficients differ in each file; observed relative Frobenius differences range from 1.75×10⁻¹¹ to 3.39×10⁻¹⁰, with maximum absolute coefficient difference at most 9.54×10⁻⁷. The input/map/reference mismatch hypothesis is excluded by exact bytes. The precise original floating-point execution cause of the last-bit differences is not established from retained evidence, and no specific SVD/BLAS mechanism is asserted as proven. The actual distinct JFG matrices must be carried into JFG validation and locked scoring under their own hashes.

The reviewer approves the exact JFG preparation hash above as a construction input to a **new, separately identified admission ledger/checker**. The original FGN v1 ledger/checker must remain unchanged. This approval does not authorize JFG correction before its own selected-only locked admission; it establishes the six-member candidate grid's numerical construction and lineage.

Independent audit script `jfg-grid-independent-review.py` SHA is `9dec7b1cb4a00ad4a5c31e6b43b693f51f400a7cd41a16429c9b308225776142`; numerical report `jfg-grid-independent-review.json` SHA is `bc3fb262334906f04bd088c80f106a6b2ac374247ffab34dbbc43f8db0fca31f`. No live or GPU work was launched by the reviewer.


### CCR-016 remediation independent verification

Reviewed frozen `HeartCalibrationExport` SHA is `660577211b6a6be48f671348cdd85e2756327b6ff10fc04e618427a8150de5c8`, new `heart_calibration_evidence.jl` SHA is `5a8853197b5c04f3e502a9a10580ac69fc559cfbce0194d5dec3cdab30ce3536`, and updated native owner SHA is `ee14b631a7d6cc34808ad56677a3ea92d6d536795c274c3992f2813cfa82f923`. The public AOC method helper remains `4c07744f56c2e4731523247306e786a22b653284cc1857d54b815ac59abdfcfe`.

The standard `rtc-calibrate` full-plan path uses `collect!`, not the optional per-exposure `CaptureStore.capture!`. The appropriate native capture evidence is therefore the full-rate raw/calibrated/gradient/DM telemetry plus serialized owner association records. The remediation retains and hashes those records and native command/hold/configuration evidence. It revalidates every chronological physical DM figure, exposure domain/generation/sequence/interval, raw/calibrated/gradient payload hash and native bucket/sync. It recomputes normal ADC maximum/rail/validity diagnostics and requires the declared no-rail gate. It independently accumulates actual accepted native gradient values in Float64, converts each N-frame mean to Float32 and compares its bits against the public CLI result. This matches `CalibrationServer.collect!` arithmetic; it does not substitute a newly normalized offline frontend.

The retained acquisition identity includes the runtime instance, launcher/process/native-child PIDs, native ready session, declared deployment, source owner and complete acquisition-domain mapping. Reduction requires the same stopped, unadmitted runtime, matching source sequence, no reported cleanup errors and removal of the owned instance. It verifies the retained evidence manifest and reruns native payload verification before invoking the sealed public AOC reducer. The cold gate uses the trusted supervisor's final state; actual launcher exit/PID absence is additionally checked by the owning wrapper and live qualification, rather than inferred from arbitrary elapsed time.

The unchanged reviewer counterexample now throws `missing actual native runtime identity` before creating a candidate. Pass-after fixture is `ccr016-fixture-2hhaBx`; log `ccr016-reduction-probe-pass-after.log` SHA is `ef1c5066939f274e0a95d05bc43292e5827ad545b898ff57b7ab63cd665fe639`. Independent native-evidence tests passed **10/10 assertions**, including changed actual gradient/DM payloads, reordered adoption, missing raw stream and changed public means with refreshed self-consistent hashes. Log SHA is `ae483f825e64ef4d73ca2958cfcda0415117ddc28e7f307058972e26c1cceddd`. Independent exporter/runtime tests passed **82/82 assertions**, including wrong stopped-runtime identities and retained instance rejection; log SHA is `595e6012514f9ff32ea36beae640f7b307a4898bbbe54b691cb808cfbe4d2405`.

Fresh full-plan package `heart-calibration-copper-zonal-cuda-prepared4`, descriptor SHA `152921622a165e2a3414e64a032f555dabab693b0587ba89d9d1238972fef91b`, and bounded nondebug CPU package `heart-calibration-copper-nondebug-n2-prepared1`, descriptor SHA `f9b059ccafb05803aa0f5a26cffd87060a20ce653685ac14bb6436b2741df20f`, independently pass all **492 artifact hashes each**. The latter uses the sealed single-actuator ±0.04 µm modal plan, N=2 and S=1: seven WFS records, three DM records and four accepted frames. It is a protocol/reduction smoke experiment, not the frozen scientific cohort.

The cache wrapper `run_native_plan.jl`, SHA `3f82e2de3815447f04465576284d4f1bfa61e8ae0b4b28a5671b7990cacd2ff0`, validates the expected descriptor and fresh paths, uses the prepared package's existing SDK CLI, waits for process-aware admission, invokes standard `run_plan`, performs public shutdown in `finally`, and invokes reduction only when both collection and normal shutdown pass. The reviewed owned-launcher fallback never sets these success gates. No new confirmed blocker was found in this software review. Actual fresh nondebug `run_plan → shutdown → reduce_plan` completion remains required before promoting full native qualification. No live/native/GPU run was performed by the reviewer.


## JFG v2 admission wrapper independent verification

Reviewed v2 source ledger SHA `1ee5fe36109c2baffba8d0e8baf525e960bf496a7637fca61b3dd7bf58445af8`, checker SHA `30b1870718625846bd874eadf80405a9e35ca529675521b1c1e5950a96b7abc4`, and `prepare_copper_jfg_correction.jl` SHA `adac5c0a07848e1f1b81c52a98ab2665543d994c432ef0ee843e7233ec0125bc`. All 16 ledger source entries match. The preceding 15 entries and original v1 ledger/checker/preparer bytes are unchanged. The new ledger binds the independently approved actual JFG preparation `9ca3f99d…` and numerical review report `bc3fb262…`.

The checker preserves the reviewed all-12 validation and two locked-score recomputation, winner, physical flat norms, forward diagnostics, frozen seeds/plans, actual capture/CLI/ADC/lifecycle and source-seal requirements. The wrapper requires that full cold check before calling the unchanged installation mechanics. It rechecks the captured inputs and baseline, then updates and reseals the final package's declaration to identify the actual v2 ledger/checker, wrapper and unchanged installation contract. It does not substitute FGN coefficients for the distinct JFG coefficients.

Independent focused cold tests passed **31/31**, and actual-selection/missing-locked public preparation tests passed **9/9**, rejecting before output creation. Logs `jfg-admission-v2-independent-review.log` and `jfg-preparer-independent-review.log` have SHAs `40c2a1d045c0803d5d825bab101fbd6c4d517e1e0846fc238d60bd749f7e047a` and `7d05dd8edbd8f3dcd55d1fcf4e008b82de16748e58dfa527219bf7ef0af57437`. No significant new defect was found. Actual JFG locked captures, positive complete admission and constructed-package verification remain required before JFG correction; they were absent at this checkpoint.

### CCR-016 actual positive N2 verification

Actual lifecycle `heart-calibration-copper-n2-evidence1.lifecycle.json` SHA `241fe007e921d1bb9bf02265d7655a9e828c34ccfffc6a5e3c1153cc42c03377` has successful collection, public shutdown and reduction. Independent cold execution of the sealed native verifier confirms seven records in each WFS stream, three DM records, four accepted frames, maximum ADC 4,451 and one invalid declared initial settling frame. All accepted measurements match the actual native Float64-accumulated/Float32-packed means. Verifier log SHA is `b12d6073027e557c2a2a85c3e59c14ae3d5ed369f4e3fe8679bcd7d300688b74`.

All 71 retained evidence-manifest entries match. The completed candidate and native-completion hashes match. Independent reconstruction of the public AOC Float32 central secant, including its precomputed reciprocal multiplier, matches all 3,600 output coefficients bitwise. The resulting 3,600×1 artifact remains explicitly `complete-unaccepted-candidate`. Final state belongs to the captured session/launcher/instance, is stopped and unadmitted with no errors, and the instance and all six recorded owned PIDs are absent. This is a successful bounded end-to-end regression for CCR-016, not acceptance of a native scientific grid or active correction.

## Native reference preparation checkpoint

`run_native_reference.jl` SHA `729e996f5d19554677ff485708223a5b76350505f195823dbffa06120c87f0dd` validates the expected descriptor and all-zero single-probe N=32/S=1 reference plan with seed 522 or 523. It uses the standard collection API and public shutdown in `finally`; owned fallback cleanup cannot set either success gate. No derivative reduction is attempted for this reference-only plan.

Both fresh reference packages independently pass all **484 artifact hashes each**: training descriptor `59eff9f8b71b924f5fe6b7dda330151112af19a7f8038e59ddf20c5152e7aef7`, qualification descriptor `71ee25da23a89e46a99b0352d276693fd1cbf9a48c6395fd6485ced20717e79e`. The zero physical command and seeds are exact; each plan declares 34 total WFS records, 32 accepted and two DM adoptions including restoration. Preparation SHA is `0192f879000d18c72f92a6f42e7117e7dbbe5679a6f31c9de5baf59be0b4f837`.

The planned native Q must use its own completed, retained Float32 reference. The independent qualification mean remains a Float64 diagnostic and must not be used to refit Q. The native reader/grid/admission pipeline is still under implementation/review. Reference-2 subsequently failed as recorded next; neither the reference pair nor a full native cohort is accepted at this checkpoint.

### CCR-017 — Native reference acquisition publishes an invalid measurement after a streaming reader skip

**Severity:** High. **Confidence:** High for observed acquisition failure; medium for the exact scheduling interleaving. **Evidence class:** actual retained telemetry and native diagnostics, plus source-derived mechanism. **Disposition:** open native acquisition gate; no production/native source change approved by this review.

Actual qualification reference under `heart-native-reference-v1/qualification-reference` fails on exposure 4, after three completed exposures. Independently decoded retained `hn-ref2/native-telemetry` contains four complete records in each WFS file. Record bucket 3 in raw and calibrated streams is ready with sync 4. The corresponding gradient record is deliberately invalid (state −1), progress 0 of 3,600 and stale sync 3. The owner correctly rejects it; no reference output can be accepted.

The retained `hn-ref2/native-logs/heart-1.log` explicitly reports native `hrtWfsProcBlock_getBuckets` error 102: its reader counter jumped from 2 to 4, followed by deliberate invalid output publication (`hrtWfsProcBlock.c` error path). This rules out an incompletely appended telemetry file or Julia decoder readiness as the sole explanation. Retrying or accepting the same committed invalid record would not repair the failed acquisition.

Source inspection identifies a plausible, discriminating mechanism. `hrtWfsInputBlock.c` initializes the next calibrated bucket's progress state before blocking for the next detector frame. `local_setReaderMostRecent` in `hrtCircBuffer.c` selects a non-empty current write bucket for streaming reads. A delayed processing trigger can therefore observe that next preinitialized bucket rather than the latest completed frame. The retained stream has no fifth completed raw exposure. The exact intervening thread schedule is not recorded; the mechanism must not be promoted to a measured interleaving without a trace or controlled reproduction.

Required next evidence is a bounded trace of trigger arrival, calibrated write counter/current-bucket state and the streaming reader's selection, or a controlled reproduction of those states under the unchanged native implementation. Transport pacing may measure the failure envelope but elapsed-time grace alone is not a proof of ownership. Preserve exact state/sync/sequence rejection, the failed reference package and logs, and require a fresh complete reference pair before any native scientific cohort is admitted.

### Independent native coordinate and recurrence check

Independent decoding of the actual native primary FITS files as Float32 confirms P is 277×253 and exactly equals the common frozen B=P E C, with E and C exact identities. The separately loaded 253×277 clipping-feedback map exactly matches the common feedback payload; it is not assumed to be P⁻¹. Independent SVD gives physical rank 250 and exact zero columns 1–3. Native `modalCtrl=1` bypasses zonal extrapolation (`hrtClwcBlock.c:1879`); native projection loading requests Float32 (`:8640`). Thus the coordinate proof uses actual native loading representation, not merely matching filenames or Float64 FITS values.

Source-derived native recurrence, with the reviewed configuration and without unrelated optional feedback, is:

```text
eₙ       = R_ctrl yₙ
vₙ       = 0.99 sₙ₋₁ + 0.01 eₙ
uₙ       = clip(P vₙ)
sₙ       = vₙ − 0.99 F(P vₙ − uₙ)     [clipping feedback enabled]
plant OPD = uncompensated OPD + adopted DM OPD
```

TFC applies the positive 0.01 gain (`hrtTfcBlock.c:2864`); CLWC scalar is 1 and leak is 0.99 (`hrtClwcBlock.c:2286`), and clipping feedback subtracts 0.99 times the projected excess (`:2643`). Therefore a positive-displacement estimator requires `R_ctrl = −R_est` for correction with these coefficients. This verifies polarity composition without changing any gain or treating the held calibration owner as an active controller. Actual enable flags, resets, output association, clipping and direct residual OPD must still be verified in an active-correction experiment.

Independent map audit script `native-map-independent-review.py` SHA is `cc68abe79666e192bf12ffa372a3a17ed579dab279a73833845c3f0c3fd2a611`; its report SHA is `70731708121dd290a6ce3ef5c45721d5678170b0c3ec9812b80fff72bbead01f`. The combined N2/reference seal audit `ccr016-n2-reference-independent.json` SHA is `3bb0daef61289e0b1c6e6b7c9fd32af5c2b7d60bc06430cf8fb84ef7d3c5261f`.

### CCR-017 configuration audit and bounded discriminator

The retained ref2 placement identifies `HOP0.wfs.w` on CPU4, `HOP0.proc.w` on CPU6 and `HOP0.recon.w` on CPU8, each FIFO priority15. Current read-only host observations are RT runtime 950,000 µs per 1,000,000 µs period. These values establish a possible throttling mechanism; they do not prove that CPU6 exhausted its budget during the failed exposure. Aggregate native process CPU consumption is insufficient to identify the delayed worker.

The source-level wait contract matters:

- `hrtHopLopPipe.c:754` creates the WFS processing worker with semaphore triggering; `hrtWfsProcBlock.c:2870` selects the default worker, which calls `sem_wait` between frames (`hrtBlock.c:1867`). There is no idle WFS-proc polling interval to tune in this path.
- During an incomplete frame, WFS processing uses `daoRT_pauseUsecFraction(0.05)` (`hrtWfsProcBlock.c:4265`). Its implementation executes CPU PAUSE instructions, not a scheduler sleep. Reconstruction similarly uses `daoRT_pause(5)` while waiting for streamed gradients (`hrtHoReconBlock.c:2436`). A profile is needed to determine whether either loop was active continuously in the failed schedule.
- The standard WFS handler fixes `isStreaming=true` (`hrtStdWfsHandler.c:928`); input `streamingFlag` is derived from that handler (`hrtWfsInputBlock.c:1054`). No supported public switch for disabling that input stream was identified. `CONTROL_MVM_STREAMING_INPUT` concerns the reconstruction path, not input-bucket preinitialization.
- The socket requests 50 µs busy read, clipped by the host setting. Ref2 explicitly reports clipping to **0 µs**, so active socket busy polling is not supported as the cause of this run. Telemetry `pollPeriod` controls file observation, not the processing trigger.
- `HRT_THREAD_PRIORITY_MAX=0` is a documented process-local diagnostic option (`hrtThread.h:100`, `hrtThread.c:303`); zero selects SCHED_OTHER in `daoRealtime.c`. It requires an explicitly different diagnostic placement declaration: silently applying it would violate the sealed FIFO15 contract. A changed-scheduler pass would establish sensitivity, not by itself prove RT throttling as the unique cause.

The lowest-cost next measurement is a short, root-owned repeat of the bounded reference protocol with identical scientific inputs and gates, recording the existing native trace plus owned worker execution statistics. The exact sealed `scaoTemplate` exports `hrtProgressTrace_active`, `hrtProgressTrace_now` and `hrtProgressTrace_recordAt`; therefore `HRT_PROGRESS_TRACE_FILE` can activate already compiled, fixed-buffer instrumentation without a native source change or rebuild. It records WFS receive/progress/frame-done and WFS-proc progress in CLOCK_MONOTONIC units. Retain its lost-event counts and note that the exporter runs only on orderly process exit. The failed `getBuckets` path occurs before proc-progress events, so the trace alone cannot identify why the worker did not run earlier.

Sample only the owned native worker TIDs' `/proc/.../schedstat`, task state and wait channel at 20–50 ms intervals from admission through the bounded exposures. A short 49–99 Hz user CPU profile of the same native PID can distinguish an in-frame spin from semaphore/socket blocking. If permitted, filtered `sched_switch`/`sched_wakeup` events add direct runnable-delay evidence. Tracefs event-format reads were permission denied for the reviewer; no host permissions, scheduler policy or tracing configuration were changed.

Interpretation must remain discriminating: sustained CPU6 runtime near 950 ms followed by a roughly 50 ms runnable gap would support RT budget exhaustion, whereas a short scheduling delay spanning final packet arrival and next-bucket initialization would support the bucket-selection race without that mechanism. Either can coexist with other delays. Packet row count/readout pacing can measure sensitivity of that interval, but must not be represented as a general scheduling guarantee. No live experiment was performed by the reviewer.


### Actual JFG v2 positive admission and prepared package

Both actual JFG locked captures are now present. Independent execution of the complete v2 checker under the exact captured JFG HIL project, Julia/BLAS one thread and `--depwarn=error` succeeded with no warning output. Reviewer report `correction-admission-checks/jfg-reviewer-final-v2.json` SHA `b5c88c436b987660de7e402f1c7835ff11db026c24f26f572e0eba6ea562ae06` is **byte-identical** to the preparer's actual complete admission report. It recomputes all twelve candidate-validation scores, the selected `hadamard-1` winner, two selected-only locked scores and the retained scientific/source contracts. This supersedes the earlier missing-locked checkpoint for this exact JFG tuple.

The constructed `jfg-correction-cuda-v2` descriptor SHA is `f5a3bb8efbb14f02db16193dac818e09c55f4c4d61ffc84b138e510516dc7fb7`; companion SHA is `7266f0a217c25654a2da2eb5cb559f91b1519c1c349d831f2b4a56c5ada3d2c7`. Independent verification checked all **521 companion package files, 520 descriptor artifact entries and 5,141 admission input hashes**, without mismatch. The companion declaration equals both installed `correction-preparation.json` and the installed provenance declaration, including the exact v2 ledger/checker and reviewed JFG grid.

The selected estimator SHA is `eda9372b72e78629d01e31ed8ffd4ec4259fe75f9c468e91a3c4c11060179267`; installed controller SHA is `8cfeba562c55ff99de362e77d5046cbb1d4011c21bce334b93ab50912596c043`. Independent array comparison confirms exact Float32 negation with literal positive-zero null rows 1–3. Comparing every baseline file shows changes only to deployment descriptor, provenance, the explicitly refreshed correction analyzer and reconstructor payload. Graph coefficients, normal atmosphere, noisy detector, brightness/background/maps and dependency sources remain byte-identical. The producer's actual public preparation test passed 43 assertions; the reviewer did not rerun this output-creating script.

This closes the scientific-admission/preparation gate for the reviewed JFG v2 tuple. Actual dynamic correction, direct residual-OPD comparison, cleanup and accelerator qualification remain separate experimental claims.

## Explicit deferred native fixture: independent pre-run approval

Primary-agent adjudication permits the already compiled `HRT_DEFER_WFS_INGRESS=1` comparison fixture for completion-driven Copper calibration/correction qualification. This is a distinct ingress contract. **CCR-017 ordinary streaming remains open**, and a deferred-mode pass cannot establish ordinary progressive ingress, hardware behavior or cadence.

The selected unchanged HEART source is `6a5c06b11a8b934effeb6328a73a70895b2af94a`. In that implementation, both ordered 32-row datagrams are received and checked first. It then publishes the first 32 rows, waits for the same-sync WFS-proc snapshot of those rows and the same-sync reconstructor snapshot of 1,800 inputs, and only then publishes the remaining 32 rows. The handshakes use atomic acquire/release observations with bounded five-second waits that yield in 10 µs sleeps. These are actual consumer-progress handshakes, not elapsed-time guesses. They deliberately alter delivery timing while retaining the selected two-chunk calculation. No HEART source or binary was modified for this selection.

Frozen RTC source hashes are:

| File | SHA-256 |
| --- | --- |
| `deployment/julia/src/heart_owner.jl` | `4b857c19537d19e440101224d8435237164b2799a1dc83810914fce01f97337f` |
| `deployment/julia/src/heart_calibration_export.jl` | `4c77d0a531ae522e63c200aebe72fa93de1aaf5489e356087529225bd69c7b1a` |
| `deployment/hil/heart_calibration_owner.jl` | `392978e97da9c2acfd039ed67178792ba3e3a1ba7b1f573c2418186d32a9f31c` |
| `deployment/hil/heart_calibration_evidence.jl` | `fef6675ceae84d47512cfd7cebd599bd40e75741867b92f3211685b6a5222367` |

The explicit mode defaults to streaming and overrides inherited environment with `0`; selecting deferred sets `1`. Export checks Copper 64×64 pixels, exactly two 32-row datagrams, the reviewed source revision and the existing compiled binary markers. The native supervisor reads the actual child's `/proc/PID/environ` before INIT and retains the observed mode. The acquisition hold and final evidence validator bind that observation, mode, declared packet shape and exact native binary to the same child/generation. Invalid modes, missing/duplicate/wrong environment entries, wrong profile/dimensions/source revision and missing compiled support reject.

Preparation `heart-native-deferred-v1/preparation.json` SHA is `ad541150851df1d21ff162579e8e9ae3bc1259ba6e8dc3994b17b2903221a002`. Independent verification confirms all **7,379 artifact entries across 15 unlaunched packages**, exact frozen plans, matching mode in both owner arguments and environment, source/driver seals and initially absent external owner directories. Native binary SHA `1c0862686dc79d127033845a12d32a0d12ac4ccc24a28396f69d0233b16ef9d1` is byte-identical to the previous ordinary-streaming reference package. Independent package report `deferred-packages-independent.json` SHA is `2d92068ca668036313c98079ab170c53e2c03a99f192512232aa9a144731b773`.

Independent focused suites passed **230 assertions**: exporter106, acquisition owner87, native evidence11 and supervisor26. Their log SHAs are respectively `a47c4c75e62a8c3e35efbb80210fafd0dd3785a7009c1b4bec429e07433d5271`, `831612704bfc51437d97cc9754d642ac38064ba00c148a07287d9c4eebba5799`, `ae5ed248d20197b7fada6dc4e35d22107797b99e43c061f76c4f82b89c4d4411` and `f3f32dcdba2cc2afc3bf2305a1d28db7f058237122a2352e412b7948485595e9`. These cold suites launch no RTC/native HEART/GPU plant.

The reviewer approves the exact N2 descriptor `da655a2f60b4e8046e1f68a7165e0ac34d96d61c69d14b0a4962693b10ee678c` for the root-owned bounded experiment using `run_native_plan_v2.jl` SHA `2e270160d9d45b6643d5c2126f48ac3295974718318160ab0b5e278e37a71e27`. The wrapper preserves public collection, finally-shutdown and reduction-after-success, recording phase timing without presenting it as steady-state latency. Reference wrapper SHA is `fd77dc00878b778d4a8bee5dc4174cff8c6cc7b03fc854e28672ca323f450dda`. At this pre-run checkpoint actual positive deferred collection/shutdown/reduction was pending; the subsequent actual reference verification is recorded below.

### Later-stage cache helper follow-ups — historical pre-v3 checkpoint

`freeze_native_reference_v2.jl` now revalidates descriptor/artifacts before invoking the sealed helper, all retained manifest entries, and actual runtime state equality with the lifecycle's final state. Source review nevertheless found that its separately included current-worktree telemetry decoder was not in the consumed-source ledger. The worker was asked to bind that actual include's SHA and equality to the selected sealed decoder before freezing numerical means. This is a reference-freezing provenance obligation, not a blocker for acquiring fresh reference evidence.

The new cohort coordinator also needs explicit reference/cohort ingress-mode equality and owned child cleanup if its wait is interrupted; its direct child wrappers already implement shutdown and fallback correctly. These cache-only follow-ups do not change the approved sealed N2 package or repair the ordinary-streaming issue. Full native reference freeze, cohort fitting, validation/admission and active correction remain separately reviewed stages.


## Queued cold reviews: actual references and accelerator preparation

This checkpoint independently reviews the frozen Classic runner, native v3 cache helpers, and AMD serialization/preparation route. It permits the primary agent to run the corresponding selected experiments. It does not admit unmeasured correction results or close the broader five-part scientific study.

### Classic single-case GPU runner

`run_classic_gpu_correction.jl` SHA `8a5914fd577e4fe953cf2ae7cdfb6b99c65dd08afd20a1ec6e2f8fda14756f8b` and run-source ledger SHA `4141e14903edee48ada4d74039a62cabdeb85ca21c9bf9d83624d332fbc10bc5` were inspected. The consumed finite runner is now SHA `233919fb7629746ca19690c25b611afaf9a8af7b27fcdb93e68da713de4e48d2`, with the explicitly enlarged 900-second preparation/readiness budget and unchanged completion/reset/shutdown science contract. Owned cleanup remains SHA `47c1855355e0bf7437c05a5601a8cb4e7fdddf3a060e22f468ccdba60db791ed`.

The runner selects exactly one declared engine/backend, obtains the actual source owner from the descriptor, and preserves its backend environment. It requires two exact 256-frame reset batches, successful public stop/reset/restart/shutdown, direct OPD truth, unchanged selected inverse and package sources, and the installed same-backend analyzer. Both complete predeclared windows must improve their verified zero-command baseline. Fallback cleanup cannot confer scientific or public-shutdown success. Static analyzer loading uses the required latest-world boundary.

Independent execution passed all **135 assertions** under Julia 1.12.7, one Julia/BLAS thread, existing compiled modules and `--depwarn=error`. The suite rechecks all four sealed package preflights, source/fresh-path/backend negatives, exact analyzer schema/windows and lifecycle/reset negatives; it confirms no CUDA/AMDGPU module was imported. Adapted Copper schema fixtures are software checks only. The exact runner is approved for a root-owned single selected experiment; actual Classic GPU correction and replay remain experimental gates.

### Native v3 helper remediation and actual deferred reference pair

`freeze_native_reference_v3.jl` SHA `eae6f96d775340123de28ef87e83ace37cf1697c22700ffd7d17dc09af1ee651` closes the consumed-helper observation above. It records the actual telemetry include SHA before and after inclusion, requires equality to each sealed package helper, and retains that file in the input ledger. Descriptor/artifact validation precedes executing the packaged verifier. It checks the retained manifest and actual runtime state against the captured lifecycle, then reconstructs the 32 accepted frames in Float64, verifies the public Float32 mean and freezes the actual represented reference. Seeds 522 and 523 remain distinct; Q is formed from the frozen native reference rather than silently substituting the common-engine reference.

`run_native_cohort_v3.jl` SHA `ccc84a9d680f47d9fbcedf872f43643f4fb183ab8323488e289a3e9553a22f64` requires reference/cohort policy and deferred-ingress equality. It revalidates all frozen reference inputs, allows only the explicitly requested stage or same-family pair, and uses finally-cleanup for an interrupted owned wrapper. A failed stage cannot start the next stage or promote fallback cleanup to acquisition success. These source-level follow-ups are resolved before first use of these helpers.

The reviewer independently verified both actual deferred reference stages: **970 package artifact entries and 132 retained evidence-manifest entries** match. Their actual runtime files equal the lifecycle final states, both stopped/unadmitted/error-free; both owned instance directories and all twelve recorded owned PIDs are absent. Lifecycle SHAs are `f464e023bc83ef258c72cf2af5557a98ab10507cb41057800e51ae52dd0e0f67` and `4c0aa185a056db008fe83d6f20d5f420fe2c9786e41098c8bd999c4b8d2d7c9d`.

Independent execution of each sealed cold payload verifier passed: each stream has 34 raw/calibrated/gradient records, two DM records and **32 accepted frames**, with exact native/public mean agreement. Each has one declared invalid first-settling frame; observed maximum ADC values are 4038 and 4009. Invalid data was not reclassified as accepted. The v3 freezer and coordinator are approved for the selected completion-driven deferred study. This evidence does not repair or qualify ordinary streaming CCR-017, native full-matrix inversion or active correction.

### CCR-018 — Actual AMD score could not be serialized

**Severity:** Medium. **Confidence:** High. **Evidence:** same actual paired scoring object fails the original writer and passes after normalization. **Disposition:** closed for the frozen immutable v2 route.

The original frozen mathematical scorer returned nested JSON3 objects in ADC/timing metadata. `Common.write_json` requires string-key dictionaries and rejected those Symbol-key objects after the actual pair had already been acquired and scored. This was a report-generation defect, not failed held-out utility. Original sources, failed log and both captures remain preserved.

`run_copper_amdgpu_transfer_v2.jl` SHA `865695c8b4ccf4eef138d0399179e64321319e727d3a5a4dc681f6b8b5c941a1` calls the exact original `score_pair`, then its existing semantic normalization before writing. No measurement, estimator, direction, seed, score, policy or gate is changed. Separate preparer SHA `dc8fa2785949665d7458a20f1efa518dc2ad5b6006e587f31392cc91338505a4` pins this serializer and requires a fresh full cold recomputation before copying a correction package. Metadata truthfully distinguishes the mathematical driver from the serialization driver.

The independent standalone `verify` recomputed the retained report exactly. Independent focused suites passed **42 serialization/admission assertions and 37 read-only package assertions** with `--depwarn=error`, including the same-result fail-before/pass-after writer counterexample, actual two-capture math, fresh cold admission, retained science bytes, null-coordinate signs and overwrite rejection. No GPU module or owner was launched. An additional independent hash audit checked all **1,806 capture-lineage entries, 11 audit files, 392 companion package files and 391 descriptor artifacts** without mismatch.

Report SHA is `f9c8785ee661e54b962af89885eeb4c287ddf2d77d26b87f5b5bf7191a7a9acc`. Actual seeds 553/554 yield absolute physical SSE 0.02336354320135136 and 0.02334527008517761 against zero-command SSE 0.6817856422690091; both sparse and mixed groups pass in each capture. Each capture completed 1041 exposures with zero invalid or upper-rail samples. These are matched-seed finite backend comparisons, not independent backend uncertainty estimates or a new full AMD calibration matrix.

The approved normal-correction package is `fgn-correction-amdgpu-v2`, descriptor SHA `8f06d785a20530cf2d2631e03295d7fd0a6ef45cfd67a26472f22a6ccb2c836a`, companion SHA `5ec08f830a6a22d3cca46160be50d3edbb4cfc26cf828b21832ad88100dd7d44`. It retains the normal plant, detector, maps, graph coefficients and backend dependencies, and the selected negative estimator with literal positive-zero null rows. Actual dynamic AMD correction and same-backend zero-command replay remain separately required.

### Retained independent evidence

The cache report `queued-cold-reviews-independent.json` SHA `55ddc08981cea2149ab62a0850e04524e620742c7481f855e73a752141106792` binds exact sources, actual reference lifecycle/descriptor identities, process-absence observations and AMD package/lineage counts. `queued-cold-reviews-validation.json` binds that report and all six independent logs: Classic135, two native payload verifiers, AMD standalone recomputation, AMD42 and package37. These are cold/software and retained-evidence checks; no reviewer live launch, GPU import, host policy change or native source modification occurred.

Validation ledger SHA-256: `6c1c3395d5b2e4ddcc6c8234b869b6c97efff84e2965dc87e428b74e5e3ff8d6`.


## Native cohort reader and grid — current review checkpoint

The primary found two cache-coordinator admission defects before full launch: v3 placed Unix sockets under the long durable evidence path; v4's new path helper required `String` while CLI splitting supplied `SubString`. Current v5 SHA `bb6ee9b9de0db0c1af300fdcd3817af88802da9fda216fc2d6422c2d2bc43dfc` separates a fresh explicit short `/tmp` runtime root, normalizes parsed names once, pins the helper SHA `71099720d2a7e0d99603e2c98ccc352d9764099cdfd5eee4b2ae335917c00746`, and offers a no-effect CLI check after all admissions. Independent source inspection and **25 focused assertions** verify the original long-path and SubString counterexamples reject, short valid paths pass, and relative/traversal/linked/occupied/duplicate inputs reject. The historical v3 approval above is superseded by this v5 path/CLI correction for operational use.

Initial native reader `c4b00084c3fe0a7587dc28a3bfcc6549b713486b241acc241ffaecda63bf7b0e` and grid `27244704f77aee03b63a4b1f102e90a1adb456b84ee8620956283bcc3680c06d` were inspected. Their intended fit uses the native reference, actual Float32 native projection equal to B, public AOC physical-basis inverse, and the already reviewed repeat-noise cutoff grid. Only the six predeclared training stage names enter fitting; held-out validation and locked captures cannot enter this grid. Spatial observations remain outside the full-rank inverse family. A grid remains unaccepted until independently associated held-out scores and locked tests pass.

The independent actual paired-zonal reader probe repeated retained native payload verification and public AOC reduction for both completed captures. Matrix shape is 3600×277, absolute means are 554×3600, each capture completed 9419 exposures, and actual native B is 277×253 with rank250 and null columns1–3. Both repeats have identical represented physical figures and distinct detector seeds/local runs. **7,813 assertions passed; one final consumed-source assertion rejected** the worker's concurrent reader change from `c4b00084…` to `5006fc76…`. The latter adds an explicit derived null-column guard. This is a source-identity rejection, not a native payload or numerical disagreement. The failed checkpoint log is retained as `native-zonal-reader-independent.log`; no clean frozen-source approval is inferred from it. Final helper guards and a clean replay remain pending at this checkpoint.

The new active native correction owner/telemetry were read as evolving source only. Their final contract, runtime flag proof, held-versus-active lifecycle, per-exposure command association, projection/units, reset retention and deployed direct truth require a frozen implementation checkpoint before approval. No draft owner is authorized by this review.


### Frozen native v2 reader/grid approval

Reader SHA `37b587ac1968680de0428a7f127b35b99e23e2423b6ff6fdf19b399016d0b6f4` and grid SHA `13c2cff7a7df56f2baf4619f96e7381faf8ce540520867336f20fb9d1acaf299` preserve the reviewed numerical construction. The reader records actual included sources before inclusion, checks them afterward and binds those identities to consumed inputs. The grid revalidates every input after capture verification, after fitting and immediately before publishing preparation metadata. Exact derived null coordinates must equal `[1,2,3]`.

The clean frozen-source paired-zonal replay passed **7,817 assertions**, including both complete retained-native payload checks, repeated public AOC reductions, exact candidate payload equality, matrix/absolute-mean extents, independent seeds/runs, common represented figures, actual B/rank/null geometry and every final consumed-input hash. The focused source/path/layout/map suite passed **19/19**, including changed-file, wrong-hash, linked-file, path escape, wrong extent and nonfinite payload negatives. These are actual-capture cold checks and bounded synthetic guards, not a new acquisition or GPU execution.

The review harness's optional JSON publication raised `UndefVarError: proof` after all 7,817 assertions completed because that local test variable was referenced outside the test scope. Its nonzero exit and full log are retained; it is not described as a successful entire script invocation. A separate audit binds the completed test logs, exact sources, actual candidate matrices and terminal process observations. Both actual zonal instance directories and all twelve recorded owned PIDs are absent.

The exact v2 reader/grid are approved for **cold construction after all six declared training captures complete**. The grid accepts only zonal1/2, Hadamard1/2 and spatial1/2 from the frozen cohort, requires paired represented figures and independent seeds/runs, and does not select using validation or locked observations. Existing `Selection.family_candidates` computes D̄, the empirical projected spectral repeat scale and the public AOC cutoffs 1×/2×/4×. It uses the native reference in Q, actual native B and Float32 packed estimators; the declared controller sign remains a later negative composition. Spatial observations do not become an additional full-rank inverse family. An actual produced native grid, subsequent absolute held-out scoring and active correction remain separate verification gates.

Audit `native-reader-grid-v2-review.json` SHA-256: `8e2deffcfe46642ddfabdc94196b2cb24ca62d3dc8242bff585df94103932791`. The earlier concurrent-source rejection and v1 sources remain preserved. Active correction owner/exporter approval remains pending its final implementation checkpoint.


### Active-correction frame/command ordering: source-derived check

The selected adapter's `_stage_calibration_exposure!` executes `step_hil_exposure_at!` and synchronously stages the ADC frame before publication. `complete_pipewire_exposure!` only clears the correlated pending-exposure record. Later `adopt_pipewire_probe!` calls `adopt_hil_probe!`, which validates and copies only the exact graph command input and advances its probe token. It does not step the graph or rerender the DM surface. Graph outputs are separately allocated; the DM surface and pupil composition change only when their graph nodes execute.

Therefore the draft active owner's post-exchange `Main.record!` retains the staged **exposure-n ADC and newly adopted command-n**, while `record_correction_truth!` reads the still-current **exposure-n atmosphere, DM surface and pupil OPD**. Command n first affects exposure n+1. This matches the frozen correction analyzer chronology; no extra exposure or rerender is introduced by command adoption. This conclusion follows from inspected source, not a new live experiment. The final active package must bind these exact underlying source bytes before the conclusion is promoted to that package.

Native `cbClUnclipped` is declared as active virtual-actuator Float32 data. The unchanged CLWC implementation writes its integrator vector with a null header after integration/processVDM and before post-processing feedback. A zero sync on that channel is consequently not an exposure identity. The draft owner pairs its monotonically checked bucket/count with exactly one positive-sync physical-DM record and the serialized exposure; the final validator must preserve that distinction. Whole-exchange clocks include generation, transport, telemetry and adoption work and cannot establish native RTC latency or hardware cadence.

Source proof ledger `native-correction-frame-order-source-review.json` SHA-256: `4bc1c63592024dc4d083de9bafb6fdcd7e7c2a1a27852145e7e425fa2ab77a87`. Final active owner/exporter and retained-evidence verification are still pending; this source-order check alone does not authorize launch.


### Frozen native scorer: source and software approval

`score_native_grid_v1.jl` SHA `b6cdf03344ddb9039dcb9b6168911d742322a088cfa824d9611e3a2f56eff116` and `native_grid_inputs_v1.jl` SHA `9c5b32acc830007ab9f0585f095d42c8c7664259a2d63afec517d760d7329cf3` were independently inspected. The approved reader/grid remain byte-identical. Before and after loading/scoring, consumed helpers and input identities are checked. Actual captures are associated with the exact frozen cohort, source package, runtime/lifecycle/native payloads and repeated public AOC reduction; merely supplying response arrays is insufficient.

Selection applies the unchanged absolute physical loss to packed Float32 estimators with sparse pairs1–4 and mixed pairs5–8. Exactly two independent validation repeats are required, with identical represented figures. Eligibility and worst-repeat ranking use the existing helper, including the larger absolute-cutoff tie rule. Fresh-flat physical and controller norms are retained as diagnostics, without inventing a new threshold. The producer writes `R_ctrl = −R_est` with literal positive-zero null rows1–3; selection is frozen before selected-only locked testing.

The locked branch checks grid membership and selected estimator/controller payload hashes, scores only that estimator, and rejects reused training or validation identities/seeds. The spatial branch uses the recorded directional span and its geometric pseudoinverse only for forward prediction, retaining span residuals and rank; it neither creates a full-coordinate inverse nor enters the full inverse selection family. All branches retain truthful failure results without retuning.

Independent execution passed **49 assertions**: 27 include/final-hash/path/layout/map/repeat guards and 22 unchanged Selection numerical checks. The exercised Selection helper is byte-identical to the frozen selection-owner copy, SHA `571838afb86b1434cea903f4c409b7dece284d93e070abb715f30aeb4fe076e1`. There were no GPU imports or owner launches. No actual native validation/locked positive result is asserted by these software checks.

The frozen scorer is approved for cold evaluation of the reviewed actual grid, reference and capture ledgers. Before native correction preparation, the produced grid and complete actual validation/locked scientific record still require independent numerical/source admission; a stored `passed` boolean alone is insufficient. Audit `native-scorer-independent-review.json` SHA-256: `17d13d0478f0b9e5c404a69cc9fa01120fc08246b732ccdf3010aef8d0a958ac`.


## Actual native full training grid: independent approval

Produced `native-grid-v2/preparation.json` SHA `c3fcdea1bbbeefeb97d08452c6b689869adbf36068d51d679ba71159196da14c` is approved for the predeclared held-out validation stage. The independent cold review completed with **123/123 assertions and exit0**, one Julia/BLAS thread on CPU14, without GPU imports or owner launches.

All **21,566 published consumed-input entries** match. The reviewer reconstructed all six training response matrices from the retained, chronologically validated CLI means using the exact public AOC method and obtained bit-identical candidate-response payloads, including the partial spatial matrices. Both zonal native payload streams had already received the independent complete native decoder/reducer replay above. This grid check does not claim a new full telemetry decode of every Hadamard/spatial frame; their retained payload/source hashes and the producer's complete native verification are bound.

The reviewer then repeated the two full-family fits and checked every packed Float32 coefficient bitwise. The repeat-noise scale was also calculated with the explicit equivalent projection `M − r(rᵀM)/(rᵀr)`, independently of the helper's normalized-vector form. Float64 mean matrices, cutoffs, singular-value retained ranks, rejected/total response norms, reference-command norms, physical-map rank250 and exact positive-zero null rows all agree.

| Native family | Empirical δ | Cutoffs δ, 2δ, 4δ | Retained ranks |
| --- | ---: | --- | --- |
| Zonal | 4.640094504489607 | 4.640094504489607, 9.280189008979214, 18.560378017958428 | 221, 185, 135 |
| Hadamard | 0.8230676277219505 | 0.8230676277219505, 1.646135255443901, 3.292270510887802 | 248, 235, 219 |

These are empirical finite-corpus cutoffs, not detector noise confidence limits or instrument thresholds. Dose context remains essential: signed command energy per repeat is 0.8863999603748326 for zonal and 28.364798731994632 for Hadamard (32×), with 8,864 versus 16,384 accepted exposures. Rank and repeat-scale differences alone do not establish intrinsic method superiority.

All six captured final runtime states still equal their recorded lifecycle states, stopped/unadmitted/error-free. All six instance directories and all 36 recorded owned PIDs are absent. The producer's 21.730318729-second `public_AOC_grid_fit_including_first_call` phase includes its post-fit full source/input hash recheck; it must not be described as pure inverse-fitting time or a latency benchmark.

Independent numerical report `actual-native-grid-v2-independent.json` SHA `ce7149859bdf398896715389a40cfc276e95c01fba3dbc54a13c98da63139136`; full log SHA `a874633d33fada241eeed9fd3b9778014c86e0b60eb7c5d22fd77e927e2d7262`. Source/report/terminal-observation ledger `actual-native-grid-v2-review-identity.json` SHA `9f2e5a0a6b51b49d2e127874e8c791520176a75d76f81cd3d7ea69749104fce9`. This approves the exact unaccepted grid for frozen validation, not a selected native inverse, locked utility or active correction.


## Actual native validation selection: independent approval

The frozen selection `native-selection-v1/selection.json`, SHA `cc3bbf1084ba385e5d2ed50c18eb524ca35c6aab0d754741b316327effc14214`, is approved as the validation-stage choice for the selected-only locked test. It chooses **Hadamard1**, rank248, cutoff0.8230676277219505. The selected estimator SHA is `19c3d1f15b1d5c0af51b3b8eafa488d343854e48d56fc0a92f5b3091531f6e71`; negative controller SHA is `7b65491be869943e8b56f05ecba792950fdbcdf795d0bdd38927f323c6144858`, including literal positive-zero null rows1–3.

The reviewer executed the complete frozen scorer independently under the declared sealed SDK/HIL environment with one Julia/BLAS thread and `--depwarn=error`. It revalidated both actual native validation captures and repeated public AOC reduction, checked **22,861 consumed input hashes**, and exited0. Every semantic report field agrees exactly with the producer except the freshly measured phase-duration fields. Both selected binary payloads are byte-identical. Reviewer selection SHA is `9768671ae1e90c7d3914cc3b6fd5a1fc7991dc9f50214a303c64e0134455b688`.

A separate calculation evaluated `B * (R * y)` one physical figure at a time, rather than using the scorer's matrix multiplication association. It passed **107 assertions**, checking absolute and signed-difference group losses, both-repeat eligibility, winner, fresh-flat norms and signed/null-row bytes. Maximum absolute SSE difference from reassociation is 5.620504062164855×10⁻¹⁶. The independently grouped zero-command sum is one Float64 ULP above the published sum; the initial exact-equality test failure is preserved, and the final comparison permits only numerical roundoff (8ε relative for that sum). No scientific acceptance threshold or result was changed.

| Selected native validation repeat | Absolute physical SSE | Zero-command SSE |
| --- | ---: | ---: |
| Seed551 | 0.01821031952804709 | 0.6015053821160901 |
| Seed552 | 0.018708450218747768 | 0.6015053821160901 |

Both sparse and mixed groups improve their baseline in each repeat. The independently reproduced fresh-flat physical command norm is **0.024843234951975424 µm OPD in the physical vector's L2 norm**. It remains a retained diagnostic; no new flat-bias threshold is invented. These are finite held-out estimation results and do not establish closed-loop residual improvement or native Float32 execution behavior.

Both actual validation final states equal the recorded lifecycle states, stopped/unadmitted/error-free, with both instance directories and all twelve recorded owned PIDs absent. The source/report/log/terminal audit is `native-selection-independent-review.json`, SHA `acfd5b41d850871ec7c0c221a4a6f5dc0b61be646dda0c95c4b9b00e4ef517df`. The selected-only locked pair and final active owner/exporter/scientific admission remain required before correction launch. No reviewer live or GPU execution occurred.


## CCR-019 — Accepted operational Classic offsets were not exportable

**Severity:** Medium. **Confidence:** High. **Disposition:** closed for the reviewed configuration/resource extension; active correction admission remains separate.

The old configuration helper unconditionally accessed `hil.simulated_calibration`. The actual accepted Classic correction base declares measured operational offsets instead, so the old helper fails with `KeyError("simulated_calibration")`. Falling back to historical native calibration files would not preserve the accepted frontend: the original native reference differs, and the historical mask enables four ROIs excluded by the accepted measurement basis.

Frozen remediation: `deployment/julia/src/heart_configuration.jl` SHA `0ff46ac75ee815b135a31a54ea4ecda0d99254bae3725a6c9a030e3414ef35f0`; `heart_export.jl` SHA `dadeed2e408c39aea0b7546d591c460bfa4d60a5ece396b89599be554a92a981`. The new branch requires an explicit operational Classic mode and zero physical reference, validates canonical bindings/descriptors/payload hashes, estimator snapshot, graph and plant, and checks the actual native coordinate weights, thresholds and ROI order. Conflicting simulated/operational declarations reject. Existing simulated Classic/Copper paths retain their behavior.

The accepted Float32 measured background and reference become bit-preserving native FITS. Bool eligibility false becomes signed native **−1**, not transient inactive0; true becomes active1. The unchanged native mask loader uses TINT and treats −1 as permanently disabled. Accepted zero-based exclusions85,86,101,102 are therefore preserved.

The reviewer independently passed **76/76 focused configuration assertions** and repeated the actual same-base fail-before/pass-after experiment in fresh cache directories. Every resulting file hash and metadata field agrees with the producer. The YAML duplicate-key error printed during the suite belongs to its intentional rejection test. No native owner or GPU was launched.

### Accepted Classic coordinate and measurement proof

Independent NumPy decoding checked **450 pinned input hashes**. Explicit controlled indices from the actual profile define S277×221 and T=Sᵀ; they are not a contiguous prefix. Actual native Float32 coefficients satisfy `E_native S = B` bitwise and equal the accepted Float64 physical map after representation conversion. Native singleton truncation equals `S T`. The accepted positive estimator `bb9aa68345a3402445b65a350e796b212e048453bf917245cee7f36efa015813` lifts as **R_native = S R_accepted**, preserving221 rows and filling56 inactive rows with literal positive zero. Applying B before the native extrapolator would apply extrapolation twice and is not the reviewed construction.

Padded native row-major Float32 matrix SHA is `795702802929efb45950bf4bb5f7da88ec919552662efea7847db948c0508d00`; native FITS SHA is `df3bf5c06416b2600e282b6415386d7804c6147853a242c2cda4ef7bac54e47f`, with axes376×277. All188 native coordinate-weight blocks match the accepted compact coordinate pairs after actual Float32 loading. Pixel/flux thresholds and ROI order agree; converted measured offsets and permanent exclusions round-trip exactly. This establishes the selected source/coordinate basis, not native floating-point runtime identity or near-threshold equivalence.

The narrow patch and proof are approved for constructing a fresh sealed native Classic package. **The generic configuration still retains the historical control-matrix template.** The active correction exporter must explicitly install this accepted padded inverse and bind all operational background/reference/mask inputs. Actual finite calibrated-pixel/gradient/validity/reconstruction behavior, controller flags and recurrence, active correction, reset, direct OPD and public cleanup remain separate launch/acceptance gates. No gain or coefficient retuning is authorized.

Independent source/log/proof ledger `classic-operational-independent-review.json` SHA `6e1d15cd4c57a8e9a6c3e1f47ced5d59e8c201d581b8ef9723f2dd7ad4651baf`. Producer proof artifacts were preserved unchanged; reviewer outputs use separate cache paths.


## Actual native selected-only locked utility: independent approval

The locked report `native-locked-v1/locked-test.json`, SHA `fa3f23719478ed21b6807d99c9ad3788902dba20d5e834aefbaf8a37f7b4627c`, is approved for scientific admission of the frozen native selected estimator/controller. Selection remains Hadamard1, rank248, cutoff0.8230676277219505. Estimator SHA `19c3d1f15b1d5c0af51b3b8eafa488d343854e48d56fc0a92f5b3091531f6e71` and negative controller SHA `7b65491be869943e8b56f05ecba792950fdbcdf795d0bdd38927f323c6144858` are unchanged from the pre-locked freeze. This test performs no refit or candidate reranking.

The complete frozen scorer was independently executed on CPU15 with one Julia/BLAS thread in the sealed SDK/HIL environment and `--depwarn=error`. It repeated actual native payload verification and public reduction, checked **24,148 consumed input entries**, and exited0. Every semantic report field agrees exactly apart from newly measured phase times. The independent report SHA is `9a304b39def0892af6d4c941c854087fbe75466215e6e64bc3179d576d110f09`.

| Locked repeat | Absolute physical SSE | Zero-command SSE |
| --- | ---: | ---: |
| Seed553 | 0.02768032881439883 | 0.6817856422690091 |
| Seed554 | 0.027675448104554697 | 0.6817856422690091 |

Sparse and mixed groups each improve the baseline in both repeats. Capture identities and seeds are distinct from validation551/552 and the training corpus. A separate per-vector calculation of `B * (R * y)` against actual Float32 physical figures passed **21 assertions**, including absolute and signed group losses, selected estimator/controller bytes and literal positive-zero null rows. Maximum SSE reassociation difference is 5.551115123125783×10⁻¹⁶; numerical comparison tolerances are unchanged from the prior validation check and do not introduce a scientific threshold.

Both runs completed1,041 exposures and all plan/shutdown/reduction gates. Actual final state files equal the recorded stopped, unadmitted, error-free lifecycle states. Both instance directories and all twelve recorded owned PIDs were absent during review. No reviewer owner or GPU execution occurred. Source, reports, logs and terminal observations are bound by `native-locked-independent-review.json`, SHA `85bbb6d292cac927fb2b428b9a54782fb0099518d3528fcaab1753b1107fe1cc`.

This establishes finite held-out estimation utility for the explicit deferred native calibration fixture. It does not establish actual native CORRECT behavior, closed-loop residual improvement, hardware performance, or resolution of ordinary streaming CCR-017. Final active owner/exporter/admission review and actual correction evidence remain required.


## Actual native spatial forward evaluation: independent approval

Report `native-spatial-forward-v1/spatial-forward.json`, SHA `c27d14b41b71e08e93a8142b7dbead3b033e7be2b62ca35a66f087b0b61fd7a1`, is approved for the recorded partial-span forward comparison. This uses two training repeats with seeds535/536 and two independent held-out repeats557/558, with the frozen native reference and policy. It does not construct a full-coordinate inverse.

The independent cold review passed **50/50 assertions and exit0**: 31 retained-input/public-reduction checks and 19 numerical checks. All **22,861 consumed input hashes** match. The four chronologically validated CLI mean sets reconstruct their exact public AOC response matrices bitwise. The actual input coordinates give rank64 at the recorded geometric tolerance, and the held-out figures' residual outside that span is 1.5253059415140936×10⁻⁸. Relative training repeat difference is 0.0166860186437223.

A separate per-vector implementation computes the forward predictions and explicit `Qx = x − r(rᵀx)/(rᵀr)` projection, without calling `Selection.score_forward`. Raw and projected prediction loss, raw and projected zero baseline, and removed reference-component energy agree with the published results to at most 2.220446049250313×10⁻¹⁶ absolute numerical reassociation difference.

| Native spatial held-out repeat | Projected signed forward SSE | Projected zero-response SSE |
| --- | ---: | ---: |
| Seed557 | 1.0961437827424299 | 1461.9837376414 |
| Seed558 | 1.0950181408852206 | 1461.7767559273004 |

All four actual final state files equal their recorded stopped/unadmitted/error-free lifecycle states; all four instance directories and24 recorded owned PIDs are absent. The producer's retained native payload-verifier reports and complete telemetry manifests are bound. This check repeats public reduction of the actual means and numerical prediction, **not a new full decoder replay of every native telemetry frame**. No reviewer live or GPU execution occurred.

Numerical report `native-spatial-actual-independent.json` SHA `13c0b3eaf775ff5723ab623b5c4897d79a382d3e511213c1c84bfec12927f498`; source/log/report/terminal ledger `native-spatial-independent-review.json` SHA `bcad3dadf4f3ab47d74b4b7bcb9be4de4c239278f241fde10cb6db80f0558e06`. These results support finite held-out forward prediction in the recorded spatial span. They do not rank spatial probes as a full inverse against zonal/Hadamard, establish an instrument threshold, prove active correction, or close CCR-017.

## Frozen bounded Classic native transfer plan

The cold handoff identity `classic-native-selected-proof-v1/identity-v1.json` SHA `b90f9370a82fa7e3a7dfe9a30e17c6ecd886fd371f3949f6c6a7108e4517de4a` and plan SHA `583fcb45ba2cd637852b105f63095e005c220734c970debfe576d531e0a91c1b` are approved for the declared four-direction transfer experiment, subject to the separate public Classic runtime gate review.

Independent Python/NumPy inspection checked66 file hashes, exact copied recipe/labels/figures, and bit-exact Float32 physical commands from the accepted B times the original controller figures. Directions1/8 retain sparse coverage and9/16 mixed coverage, with original0.02/0.04 µm amplitudes, alternating ABBA/BAAB order and bracketing nulls. N64 and one discarded exposure per batch yield24 batches:1,024 accepted signed frames plus512 accepted null frames,1,561 completed exposures including restoration, and25 DM records.

The frozen accepted estimator and forward model are retained without fit, reranking or threshold tuning. Predeclared utility compares paired signed-difference forward and physical inverse losses against zero separately for both groups and both original signed-pair repeats. This is a bounded transfer check; it does not establish absolute-baseline rejection. Seed98 is reused, but trimming chronology changes the later noise sample stream. Neither same-seed equality with the original experiment nor a new independent noise corpus is claimed. Four directions do not certify221-dimensional behavior.

Audit `classic-native-probe-independent-review.json` SHA `1962d54884d1b95c47b97d7f166d3dd657a8fe9bef8a5b47e94e7b169029fa71` binds the reviewer script and checked inputs. No owner/GPU launch occurred. The evolving Classic public export/decode/evidence gate remains unapproved by this cold plan review.


## CCR-020 — Reset must rotate native evidence counters with its directory

**Severity:** Medium. **Confidence:** High. **Disposition:** closed in active source checkpoint v1; actual two-window reset qualification remains required.

The primary implementation review identified that changing the native evidence directory while retaining the previous generation's journal byte/count state makes the first record in the new directory fail its consistency check. A bounded independent fixture demonstrates that failure with stale counters. `begin_evidence_window!` now requires an empty directory and resets command-log serial, evidence count and evidence bytes, while the plant's scientific lifetime probe token is preserved separately across reset. The same fixture writes the new generation successfully and verifies that the previous journal bytes remain unchanged. Six reset-specific assertions passed within the independent28-assertion owner suite.

## Active Copper source checkpoint: cold approval, package/runtime gates retained

All twelve files match `native-correction-source-checkpoint-v1.json`. Core identities are owner `abb5a05f503f6c4b90c8582e337c5191f4aac407d49ce14bee450cc94b9af1ab`, telemetry `984a3e982511b77270c15f365057036220da32808ced27cba977c1e3951ce5cc`, analyzer view `34c7394e309ae904deb810823419aefe9b47bf8eb9e5a38f7db0fbf739f69042`, cold admission `9a6e08bb9a51e38c4c9721b80ae5b77f409c340744d6e84e61e30e16c0e3fd9b`, and exporter `1e993063a4cf70da06c6301e03069462c2e801f9d9c1029578dd36c1d2d8842e`. The public two-window wrapper is `run_native_correction_v1.jl`, SHA `cb99c372c01c5466ccdce7257e0232b874a5c52ef79acc5e8715418e3a6da39d`.

Source review found no confirmed launch-design blocker in this checkpoint. It is approved for fresh cold package construction. Independent bounded execution passed **74 assertions**: owner28, telemetry20, analyzer26. The last group contains four retained-payload checks and22 timing-view checks; alternate grouping of those four with owner checks gives the same total, not a different checkpoint.

The source establishes these boundaries:

- Exact INIT inputs, native binary and13 required public flag ACKs precede active CORRECT proof. The proof asserts public command semantics, not private effective-state readback. Active and held-calibration states remain distinct.
- Each serialized admitted exposure requires one positive-sync physical DM record and one VDM record. VDM's null-header sync remains zero and is never called exposure freshness. Its exact bucket/count is combined with the positive physical DM sync and external admission fence.
- Native micrometre commands must match the normal transport's Float32 metre bytes. Actual native Float32 P times retained VDM must explain the unclipped physical demand within the documented Float32 arithmetic bound and strictly inside±0.8µm. Extra additive paths are excluded by config/ACK conditions; the projection check alone does not prove them disabled.
- Source ordering retains generated ADC and OPD for exposure n. Adoption after that exposure updates command input only; command n first affects exposure n+1. The prior actual adapter/AOS source-order audit remains bound and must match the fresh package.
- Each finite window retains256 raw/calibrated/gradient/VDM records and258 DM records, including zero startup and restoration. Reset requires the old native child gone, a new generation, closed-record retention, fresh evidence counters and reset plant/recorder state.
- The analysis wrapper verifies retained raw ADC, native command/VDM streams, record counts, runtime ACK journal and projection, then uses the unchanged direct-truth/same-backend replay mathematics. Historical timing field names exist only in an owned in-memory view. Serialized evidence retains application whole-exchange labels and does not claim native RTC latency or hardware cadence.
- The public wrapper retains both actual owner reports, requires exact reset ADC/command/truth equality, performs public shutdown before the two analysis replays, and requires both declared residual-variance windows to improve zero correction. Owned-process fallback cleanup cannot set public-shutdown or scientific success gates.

Production cold admission report `native-correction-cold-admission-v2.json`, SHA `6bd6e6a673b499fd9afed2554d0372daf0bc5b3441663cd51420754aee44d5d5`, binds24,153 consumed inputs and reports replay of ten actual scientific captures plus two references. The reviewer inspected its production reader/scorer port and its agreement with the independently verified grid, selection and locked identities; the571.86-second producer replay was not repeated solely for this review. This duration includes full cold validation and is not pure fitting time or a runtime latency measurement.

The initially reported missing analyzer-helper concern was withdrawn: the frozen exporter already includes `heart_correction_analysis.jl`. No corrective source change is inferred from that mistaken earlier comparison.

Audit `native-active-checkpoint-independent-review-v1.json` SHA `2ea3b744fa1aa6da1a055447a35918f183e8794ef6c9ea9093f0cade20e6298a` binds checkpoint sources, independent test logs, cold admission, frame-order proof and prior actual numerical reviews. **This source-stage package requirement was satisfied by the later actual package review below. Actual native CORRECT utility, reset and public cleanup remain experimental gates.** Ordinary streaming CCR-017 remains open; the evolving Classic runtime gate is not covered by this Copper checkpoint.


## CCR-021 — Native correction export generated an oversized deployment name

**Severity:** Medium. **Confidence:** High. **Disposition:** closed by the name-only v3 checkpoint.

The actual first cold native correction export failed at final profile validation because appending `-active-correction` exceeded the existing40-character deployment-name limit. The failed source/log are preserved. Exporter SHA `d11b505364605340d77a417311b4d7630550d17c4e195022ef89964f4b7eb2a1` now selects `copper-heart-cpu-correction` or `copper-heart-cuda-correction` before the expensive cold replay. The limit is unchanged. Diff inspection confirms only naming behavior changes; owner, telemetry, admission, scientific helpers and wrapper remain the reviewed bytes.

The independent focused suite passed29 assertions, including seven checks demonstrating that the public profile rejects the old actual long name and accepts both new names. Checkpoint v3 differs from v1 only in exporter and its test. Audit `native-correction-name-independent-review-v3.json` SHA `7009f1b2da181a0e6e2ff0bcb0a6f352fdc0b30ff54d836b3e175610ef088ab7` binds sources, copy proof and independent log. Full public scientific replay remains required by export; no cached-admission exception was introduced.

## Classic held-capture source and mask policy: cold approval

The four production sources match the worker's checkpoint: shared export `fc303098fb47f86a8f27f90ea8b915e3bb6dff18cc0dd34ea35842c26381c17c`, Classic admission `2d9cf94750b4c9ffb24a3fa1a2dee35bc8851b0b2e75f8726d3c568327bd1a9e`, public verifier `8155e8116337c05e63c79a65e7198b8c9ea14d310467254d8a4ab435c5d29c8a`, retained-evidence verifier `3764b391b8f9df9eaae587ed4aa1171731232305b1cb4fb0ecce93666bbaa53c`.

Independent tests passed **68 assertions**: export/corpus37, actual payload/state/backend/ADC24 and actual accepted-base preflight7. Admission binds accepted inverse and six map payloads, controller settings, operational measured offsets and exact188-coordinate eligibility. It requires ordinary Classic ingress with environment0,352×352 frames and32 datagrams of11 rows/3,872 pixels. Copper deferred ingress is rejected for this profile.

The retained native resource bounds follow the actual padded record formats:

| Stream | Header plus1,561 frame records, or25 commands |
| --- | ---: |
| Raw UInt16 detector | 386,929,216 bytes |
| Calibrated Float32 detector | 773,757,504 bytes |
| Native state/x/y/flux gradients | 4,796,416 bytes |
| Physical DM commands | 31,424 bytes |

The largest per-file bound is below1GiB. This proves configured capacity arithmetic, not sustained file throughput or delivery success. Actual delivery must still satisfy every record, sync, payload hash and public mean gate. The verifier preserves raw376 interleaved native coordinates, requires permanently disabled state−1 at accepted excluded ROIs, matches exact accepted exposure identities and Float64-accumulated/Float32-rounded public means, and checks12-bit ADC diagnostics and no rails. Historical native CM is only used in held RUN configuration; this is not active correction admission.

The scoring policy SHA `160606c8c9c2c21a304b97df1e046b25fd728166a404db766656308b981f14c8` declares fixed interleaved eligibility: both coordinates2i−1/2i use active[i]. Independent actual-byte inspection confirms zero-based excluded coordinates170–173 and202–205, all1,768 accepted inverse coefficients in those columns are literal positive zero, and all2,216 accepted forward coefficients in those rows are positive zero. Concatenating the188-element mask with itself is not equivalent. Eight additional synthetic score assertions passed, exposing raw excluded-coordinate forward residuals while leaving physical inverse predictions unchanged and rejecting wrong sign/nonfinite inputs.

Raw native means and raw forward losses remain reported. The utility criterion uses projected forward loss and unchanged paired physical inverse loss against zero in sparse/mixed groups for both signed-pair repeats. It introduces no data-derived mask, fit, gain or amplitude change. Signed-pair transfer does not establish absolute-baseline rejection or an independent noise corpus.

Audit `classic-capture-checkpoint-independent-review-v1.json` SHA `77d1c97ffa1fc3345214457ff57734e2877cc744dfcc3e9a76492853c61c18f1` binds the sources,76 total assertions, resource arithmetic and actual matrix-mask check. Fresh cold export is approved; actual package closure, full delivery/lifecycle and scientific scoring remain required. The original standalone scorer was blocked by CCR-022 below; its v3 source-order remediation is now independently verified. Complete actual post-capture admission remains required.

## CCR-022 — Classic scorer executes a package helper before validating its seal

**Severity:** High. **Confidence:** High. **Disposition:** source-order defect closed in v3; complete actual positive scientific admission remains required.

The inspected cache scorer `score_classic_native_transfer_v2.jl`, SHA `24c6982fd9af8105256927711c47a88e42ba420ccca156279fd6e3a951a08bcc`, invokes `Base.include` on `PACKAGE/hil/heart_classic_calibration_evidence.jl` before descriptor/profile/artifact validation. Its later `main` does not validate the full retained evidence manifest either. Earlier wrapper preflight does not establish which helper or retained inputs the post-shutdown scoring process actually consumed.

A harmless independent fixture containing only that helper writes a marker. The scorer executes it and only then rejects the missing provenance file. `ccr022-unsealed-helper-before.log` records `UNSEALED_HELPER_EXECUTED=true`. The exact original scorer, fixture and probe are preserved separately; no owner, GPU or production source was changed.

Required remediation: validate the lifecycle-bound actual descriptor and every sealed package artifact before including packaged helpers; validate the completion-bound retained manifest with contained regular paths and exact payload hashes; bind actually included helper dependencies before/after loading and recheck consumed input identities before publishing scores. Preserve the old scorer and create an explicit successor. The same marker fixture must reject before execution after the fix; add descriptor/helper/manifest mutation negatives and an actual accepted-package preflight. Correct interleaved-mask mathematics is unaffected by this source-admission defect.


## Actual active Copper package: scoped launch approval

Independent cold verification approved `heart-native-correction-prepared-v2`, descriptor `26c8b0b12ca8a7edc7b1b7c300f33c2549e0828456435c997c16e4a24bac7730`, for the declared two-window experiment. All512 artifact hashes match. The eight operational checkpoint files match their deployed locations; checkpoint HIL tests were checked in the immutable preparation source, while the SDK test remains packaged. The first reviewer script wrongly assumed HIL tests were operational files; its failed log and source are preserved, and correcting this audit mapping required no production change.

Independent NumPy decoding verifies native FITS controller bytes equal the selected253×3600 negative estimator, with literal positive-zero null rows1–3; native projection FITS equals the deployed277×253 physical map. Normal plant, all four frozen scientific helpers, and all231 files across AOS, its adapter, AOC and Copper simulator match the selected normal CUDA base. The exact adapter/AOS frame-order proof files also match. Native binary, configuration, runtime inputs,13 flags, gain+0.01/pole0.99 and deferred-mode environment/owner arguments are bound. Public installed `Deployment.profile` and native configuration checks pass without GPU imports. The proposed runtime, owner and evidence paths were fresh at this check.

The sealed fresh cold admission `981592a86f10a42d46022428d503097ec6eb36aebde06c1eb35454a044a2132a` binds actual ten-capture/two-reference replay and the independently approved grid/selection/locked tuple. The full producer replay was not redundantly rerun. Contract SHA `fbdcd618334b5ecd2cbfc4c075e75f6d84e1e201cf63a4be2eefea0b084570ec`; wrapper remains `cb99c372c01c5466ccdce7257e0232b874a5c52ef79acc5e8715418e3a6da39d`.

Audit `native-active-package-independent-v2.json` SHA `40b707850a3a1c171d57bbc42173160ba9d4484b5a72cc591c0c91a6f3aa9bbd` and installed-profile log retain the checks. This approves performing the experiment; it does not establish actual active correction success, hardware cadence or ordinary streaming correctness.

## CCR-022 remediation: trusted admission precedes target execution

The preserved v2 scorer remains unchanged. The new trusted SDK wrapper `score_classic_native_transfer_v3.jl` SHA `12cca6ebc9b7233672b567172cc5701d360c0bb674fe229afa25b28378fdd2ca` pins its admission helper before include. That helper validates the actual runner/preparer lineage, full package/dependency identity, public profile and complete artifact inventory, selected Classic CUDA/backend/policies, lifecycle-bound completion, full retained evidence tree/manifest and actual stopped runtime before starting the target HIL worker. The worker rechecks the hash-bound request and inputs before/after including the pinned evidence helper. The trusted wrapper repeats admission before publishing an approved result; the worker's preliminary file is not that approved result.

Independent replay of the original harmless-helper counterexample passes six rejection/no-execution/no-output assertions. The frozen numerical eligibility policy is unchanged. This verifies the concrete source-order repair; a complete actual capture and positive scoring run, including retained-manifest correspondence, remains required before promoting scientific transfer.

## CCR-023 — Classic CUDA calibration exceeded the deployment-name limit

**Severity:** Medium. **Confidence:** High. **Disposition:** closed in shared exporter SHA `4065197958dcee26044ebd9b3829934c57717f615ddfb3fb511bc35008f4ad6e`.

Appending `-calibration` to `revolt-classic-heart-hil-cuda` produces41 characters, exceeding the unchanged40-character public profile limit. The Classic-only naming branch now changes `-heart-hil-` to `-heart-cal-`; the Copper name remains exactly its prior40-character value. Independent execution passes43 export assertions including six name checks: the same public validator rejects the old Classic name and accepts the new bounded name. No calibration mathematics, ingress, source owner or controller behavior changes.

`classic-admission-name-independent-review-v3.json` binds the new admission/worker/preparer/runner sources, original failing scorer/log,49 independent assertions and unchanged scoring policy. Actual Classic package closure and live transfer remain separate gates.


## CCR-024 — Active native startup waits for a transport link it prevents creating

**Severity:** High. **Confidence:** High. **Disposition:** frozen v4 source remediation and actual corrected startup independently verified; actual reset/complete correction remain separate gates. Failed package remains preserved.

The actual first active Copper experiment using descriptor `26c8b0b12ca8a7edc7b1b7c300f33c2549e0828456435c997c16e4a24bac7730` failed at sequence0. The call chain is `run_owner → begin_window! → adopt_figure! → wait_native_receipt!`, ending in the finite deadline error. The owner calls `begin_window!` before publishing its connection reply. `Deployment.run` waits for every owner connection reply before spawning the RTC host, which realizes the transport links. Thus this source blocks the prerequisite for the DM receipt it awaits. Moving initialization merely after the connection reply is insufficient: it must follow the validated source resume issued after successful public `session-start`.

Independent native-file decoding confirms `DM_SHAPE` received public SUCCESS and generated one complete all-zero277-element DM record: bucket0, sync0, committed count1,2240 bytes. Raw, calibrated, gradient and VDM streams each contain only a1024-byte header and committed count0. The owner report records zero frames/commands and no active proof. The failed runtime has only core, HEART and simulator process entries, with no RTC process. This supports the explicit dependency cycle, not a scheduler or UDP-loss explanation. Source phase ordering is a derived cause from the observed failure and both implementations.

The final runtime is failed/unadmitted; public-shutdown success remains false. The fallback reaped the failed launcher, and all four recorded launcher/core/HEART/simulator PIDs are absent. No scientific frame or correction utility was admitted. Audit `ccr024-startup-failure-independent-v1.json` SHA `2a99d8818004fd55fee8b99553aac8c3cfac3764e3afed888b1a3bb18a92ea83` binds the actual log, lifecycle, terminal state, owner report, command acknowledgement and five telemetry files.

Required validation: reproduce the old dependency ordering in a bounded cold fixture and pass the same invariant with first-window initialization deferred until valid source resume; reject exposure before active initialization, avoid reinitialization after ordinary pause/resume, and verify reset creates a fresh native generation before the next admitted exposure. Reset/start ordering must be checked against the public broker as well. Fresh public export must retain the reviewed science/controller bytes and then demonstrate actual native startup, both finite windows, reset and cleanup. No HEART source change, gain change or evidence relaxation is justified.


### CCR-024 cold remediation verification

Owner SHA `f8f16002ea6a16f9b653eb3d025e9a3689b27ce4ca814ddf344b2217d9cbb343` and test SHA `380814e709d3f40dddc74e72b054432efd9ba2f24e05f7814e447f3459e7ba71` are the only differences between immutable preparation sources v3 and v4. The native controller now enters acknowledged RUN hold without DM publication before initial connect reply and during paused reset. `admit_active_window!` begins zero adoption and CORRECT only after valid public source resume sets `state.running`; it runs before the first exposure and does not repeat an already active initialization. Both windows use this ordering.

Independent execution passed50 assertions, including22 checks of both generation orderings using the actual public owner protocol's resume transition. The old early-begin ordering fails the same bounded receipt prerequisite; the revised path stays held while paused, waits session-start and resume, then adopts zero, acknowledges CORRECT and permits exposure. Existing journal rotation, projection and closed-record checks remain passing. Wrapper `run_native_correction_v2.jl` SHA `78f0e63eb187fdc73c8e2732200e0f0d17045fbf1303c8d998cfbf7149c0ccd1` now truthfully requires reset's new generation2 held proof with zero admitted frames, then restarts the session. It does not expect active correction before that restart.

`ccr024-ordering-independent-review-v4.json` binds exact source, copy proof, original actual failure and independent test log. This clears fresh public export with full scientific replay. It is a cold ordering verification, not actual transport success; a new sealed package and real startup/reset/public-shutdown/correction qualification remain required.

## Actual Classic held-transfer package: scoped experiment approval

Package `classic-native-transfer-v1`, descriptor `3e9ed627a36dc89b2a290cf37a2df8146a0ef6df12703d12b2fb6c7c972482f7`, and preparation `f4f38aa8d44a754868ba1bd87bfec79a943546176cc839c68971a4e876c4c6f2` passed independent514-file identity/513-artifact validation and installed public profile checking without GPU imports. Accepted inverse bb9aa683… and all six map payloads match the selected base. Independent FITS decoding verifies operational measured background and reference bytes exactly; the188-element native mask maps the four false entries to signed−1. The first audit used historical measurement filenames rather than current calibration paths; its failure was preserved and the reviewer path selection was corrected by the already-bound hashes, with no production change.

The frozen plan, original acquisition policy and separate fixed scoring policy match their reviewed hashes. All operational helper and SDK source hashes match preparation. Unchanged native binary, ordinary ingress environment0,32×11-row datagrams, seed98/lamp0.5 and1561/1536 exposure/accepted bounds are preserved. The selected padded native CM is retained but explicitly uninstalled; this is a held RUN transfer experiment, not active Classic correction. The actual owner directory was absent when checked.

Reviewed runner `run_classic_native_transfer_v3.jl` SHA `417395f9685f0ea025e0dc80f226edad63ee1f3932f83e699a08af5a4bfbe9c0` binds the fresh package and preparation, uses public capture and shutdown with same-instance terminal verification, and cannot convert fallback cleanup into success. Root must supply short fresh runtime/evidence paths. Audit `classic-transfer-package-independent-v1.json` SHA `67332e399a157a004d58ad3cdbf93972c38272eb0d0359bc156fce618f8f2bf9` binds independent script and source identities. Actual full delivery, shutdown and complete v3 post-capture scoring admission remain required before scientific transfer can pass.


## CCR-025 — Classic association verification confuses frame period with exposure duration

**Severity:** High. **Confidence:** High. **Disposition:** closed: source fix, identical counterexample, complete original-payload diagnostic and fresh successful public capture/manifest independently verified. Scientific transfer scoring remains separate.

The actual Classic transfer completed1,561 exposures,25 DM records, zero invalid frames and zero ADC rails, maximum ADC1,719. Public restoration/release/count checks and shutdown succeeded. Retained-evidence verification then failed at `heart_classic_calibration_evidence.jl:224–228`: the expected start is `(index−1) × duration`, where duration is the detector exposure1,896,000ns. The sealed source owner runs at500Hz and the unchanged public model driver uses a2,000,000ns periodic schedule. Exposure width and frame period are distinct.

Independent inspection of every retained association confirms sequence1…1561, starts0,2,000,000,…ns, constant1,896,000ns duration, and the recorded domain/generation. The old formula rejects1,560 of those valid start times. The association file hash equals the final owner report's retained journal identity. The measured data therefore establish a concrete validator counterexample; no rate, exposure, detector seed or chronology retuning is justified. The fix must derive period from the sealed declared source rate and duration from the sealed exposure plus detector configuration, not infer expected period from observed timestamps.

`HeartCalibrationExport.run_plan` writes the provisional result, invokes retained-payload verification, and only creates the final evidence manifest after verification succeeds. The failed original therefore has **no native evidence manifest**; its lifecycle truthfully retains `capture_confirmed=false` and `shutdown_confirmed=true`. It must not be rewritten or supplied with a fabricated original manifest. Actual final state equals the lifecycle's stopped/unadmitted/error-free record, sequence1561; its instance and all six recorded process PIDs are absent.

The forensic snapshot `ccr025-failure-independent-v1.json` SHA `e553b0783fe7cb40a2913b96c72fcb2927bad5e4e2d25667e33d064433721295` binds210 retained/support files, the exact original helper and lifecycle, and all period/duration checks. This is explicitly a post-failure evidence snapshot, not an original successful acquisition manifest. An initial reviewer script assumed an optional empty cleanup-error field was present; the preserved retry uses the documented absent-or-empty condition and confirms no cleanup errors.

Primary adjudication requires a narrow source fix with the same unequal-period/exposure counterexample and wrong-rate/duration negatives, followed by diagnostic full-payload revalidation of unchanged original data with results written elsewhere and before/after identities. That diagnostic cannot promote the original capture flag. A fresh public export, owner root and1,561-frame acquisition will establish the normal manifest, capture, shutdown and scoring admission without introducing a recovery bypass.


### CCR-024 fresh package closure

Fresh `heart-native-correction-prepared-v3` descriptor `44d33a5d42a473fbc25c2170e8a0c001d46f0cd700929c4c99e33cdb5cfa6d66` passed all512 independent artifact checks and installed public profile validation without GPU imports. Compared with failed package2, exactly five artifact entries change: reviewed owner f8f16002… at operational and SDK resource locations, the fresh full cold admission, and its contract/provenance bindings. Every scientific controller/map/plant/dependency, native binary/configuration and frozen helper is byte-identical. The owner evidence directory changes to fresh `hn-active-v3`.

The new cold admission SHA `5b6f968519d527dfc7f763df951766c3a401dcf42e592bc1b6561cc102d2fc2b` records434.70 seconds of full public replay. Scientific result fields match the prior reviewed admission exactly;24,158 input identities also match after normalizing nine unchanged helper paths from preparation snapshot v3 to v4. This review rechecks those relocated helper bytes and package closure rather than redundantly repeating the full scientific replay. Contract SHA `9009ca30e243774c5464f16b16946d767a6956cde75ccf20436028fdf2d3679a`.

The reviewed wrapper remains v2 SHA `78f0e63eb187fdc73c8e2732200e0f0d17045fbf1303c8d998cfbf7149c0ccd1`. Owner/runtime/evidence paths were absent at review. Audit `native-active-package-independent-v3.json` SHA `4cbe3139a4f3d684be2342615e3890d888df45bdf0e3eb75c7c9dfd021654f25` supports scoped experiment approval. Actual corrected startup, both windows, reset, cleanup and correction utility remain unproven until the new run; the original failed package and Classic CCR-025 evidence are unchanged.


### CCR-025 independently verified remediation

Corrected helper SHA `8df89d2a60901a5176d9a08b94121715c36e278e99db19efeb4bae60dec7b0a9` derives period from the sealed source-owner's unique positive `--rate` through unchanged `HILOwnerProtocol.rounded_period`. It checks declared rate/period provenance and derives exposure duration separately from `--exposure-ns`, declared exposure and actual detector configuration. Startup/final detector configurations must agree. The expected start uses period; duration checks remain exposure-specific. No scientific setting changes.

Independent execution passed36 assertions, including12 unequal-cadence, wrong-rate/duration, duplicate/missing option and nonfinite-detector checks. The original seven-frame native-payload/public-means fixture was rerun with only its helper include changed; it passes corrected verification, whereas the preserved original helper rejects it. A separate independent full replay of the actual original native files also passed: raw/calibrated/gradient counts1,561, DM count25,1,536 accepted public means bit-exact, maximum ADC1,719, invalid0, no stderr. That replay revalidates native payload hashes, association, chronology, command figures, ADC diagnostics and means, not just metadata.

The producer diagnostic binds722 inputs:514 package files,204 evidence files, four included source files and lifecycle/state. Independent post-replay rehash confirms all unchanged. Original capture remains false and its manifest remains absent. No original report, package, evidence or lifecycle was rewritten. This approves the narrow source repair and fresh public acquisition, not retrospective production admission of the failed original.

`ccr025-independent-remediation-review-v1.json` binds corrected sources, independent36-assertion log, identical fixture, original failure, separate full-payload output and diagnostic input snapshot. Actual repeat capture must now generate its own normal public success flags, evidence manifest, shutdown and scoring records.


### Corrected Classic package2 closure

Fresh `classic-native-transfer-v2` descriptor `918c4c05590784e0d6472cfb4054427e56e283ec5d3e3194d2dee04350509277`, preparation `b5eb50dddf418aee5f91e732be293d63a52bf4783234f1e36cbf21fb1efc1c3b`, passed independent514-file identity and installed public profile checks without GPU imports. Relative to package1, exactly three artifact entries change: corrected evidence helper8df89d2… in operational and SDK resource locations, and its provenance. Descriptor changes are the corresponding seals and fresh owner directory `cn2e`. Every scientific input, native binary/configuration, plan and policy is unchanged.

New preparer SHA `c76aa4b1f1f2eeee8ced7a10e14eb2d33f7ac7d224bed04f4fba731370ae8c81` pins the corrected helper; reviewed runner417395f9… is unchanged. Proposed owner/runtime/evidence paths were absent at review. Audit `classic-transfer-package-independent-v2.json` SHA `2985a51fdf36877b99e71a030d8ec2c03728446d4724982896f6dd91186f17e9` clears the fresh public repeat, not its scientific result. Original failed capture remains unchanged.

## CCR-026 — Active telemetry must account for native state-transition files

**Severity:** High. **Confidence:** High. **Disposition:** phase-aware source remediation independently verified; actual full active qualification pending.

The actual corrected-startup Copper package3 reached zero-DM adoption and active CORRECT, resolving the earlier CCR-024 startup cycle. Native processing produced the first frame, but the active owner called the held-calibration single-file reader, which rejects more than one file per tag. The error was `multiple native telemetry files for cbHoPixelsRaw0`. This was correct rejection by a reader whose single-phase contract does not cover active mode transitions, rather than proof that native telemetry duplicated an exposure.

Independent retained-file decoding finds ten valid phase files. All four raw/calibrated/gradient/VDM RUNNING files have zero committed records; their CORRECTING counterparts each have one. DM RUNNING contains bucket0/sync0 and CORRECTING contains bucket1/sync1. **Both DM file headers report one committed record**, not cumulative counts. VDM retains bucket0/sync0; it is not assigned a fabricated exposure header. The owner failed before completing its first scientific exchange; public shutdown success remains false, fallback reaped the launcher, and all six recorded process PIDs are absent.

Unchanged native source explains the observations. `hrtTemplateCmds.c:1592–1610` requests new files when a successful command changes overall mode while telemetry is streaming. `hrtTelemetry.c:4406–4420` explicitly describes this request as asynchronous. `startFile` closes the prior file, resets its header after the CB specification and chooses the next CB start; `bucketsWritten` is per-file, while actual CB bucket IDs remain continuous. The `last_n,0` request used by rotation resolves to the current CB write counter (`hrtCircBuffer.c:2980–3003`). Consequently, publishing another frame before rotation completes can also skip history from the new file; selecting the newest filename or ignoring extra files is insufficient.

Required remediation is active-owner-specific: drain and account for each declared phase before transition; wait for all new-phase headers while no new exposure is admitted; close/reopen readers with per-file offsets while retaining global bucket/sync checks; preserve every initial RUN, CORRECTING and restoration RUN file, including empty files. Verify exact aggregate256 raw/calibrated/gradient/VDM and258 DM records, reject missing/extra/duplicate/truncated records, and retain the closed-generation/reset proof. Native source, scientific coefficients and held single-phase calibration semantics must remain unchanged.

Audit `ccr026-native-phase-independent-v1.json` SHA `15f2b471f6d6e49de88c112e2b30e2f53e163962303ed210153264f58fbe2031` binds the ten actual files, source semantics, failed lifecycle/log/state and owned PID absence. No reviewer live/native/GPU execution occurred. Actual active correction remains unqualified until the new phase handling passes a bounded counterexample and a fresh full run.


## Maintained Classic transfer API: cold review

The maintained SDK `HeartClassicTransfer` SHA `24f596d87692eeb230fe0dc32f3e8ace0a8bee74455914e422800b434d1a9cb6` and HIL worker `heart_classic_transfer_score.jl` SHA `9df76e8c908d2216dac4e0c273517ac2c3074b4ee53ff669684ca807ab146b30` passed independent source review and22 focused assertions:14 SDK admission/publication and8 paired-loss checks. The mathematical `paired_losses` function is byte-identical to the reviewed cache worker. Accepted forward model and preparation are explicit hash-bound data arguments; no cache code or implicit cache data path is required.

The maintained API admits only actual successful corrected-helper captures with the selected preparation/runner lineage, full package/profile/dependency/evidence-manifest identities and actual stopped runtime before starting the target HIL worker. It rechecks input and source identities before publishing. `replay_admission` requires a passed issued report and exact reproduction of its full result and input ledger before optional active-export output; compact and padded selected-controller hashes are fixed. It does not add recovery admission for CCR-025's failed original.

Source identities include absolute paths of all loaded SDK source files. Score issuance and subsequent exact replay must use the same immutable SDK source root and bytes; copying the SDK to another root or editing its sources changes the ledger and correctly rejects. The integration must freeze that common source root before issuance rather than weakening the comparison.

Audit `maintained-classic-transfer-independent-review-v1.json` binds exact sources and independent logs. This clears the cold implementation; full positive admission and descriptor/helper/manifest/report mutation tests on the fresh successful actual Classic capture remain required before active export approval.


## Actual Classic package2 capture and original scorer admission failure

The fresh public run completed successfully with descriptor918c4c05… and unchanged runner417395f9…. Independent verification checks lifecycle `capture_confirmed=true`, `shutdown_confirmed=true`, no failure, final-state hash/equality, stopped/unadmitted/error-free source sequence1,561, absent instance and all six recorded process PIDs. The completion record confirms restoration/release/native counts. The producer's corrected full-payload verifier reports1,561 raw/calibrated/gradient frames,25 DM records,1,536 exact public means, maximum ADC1,719 and invalid0. The final evidence manifest exists and every retained file/hash matches its exact inventory plus completion/manifest records.

Completion SHA `f83775613a937aa99bc8c3d0cb5eef155796ec2ba4fc2db115ca8d8cb2de9d2a`; manifest SHA `c54142caa900c6312f14b9dbab50a162089fe568046692d2a4a3a338a27739a4`. This closes CCR-025's actual public capture requirement and does not relabel the original failed package1 run.

The cache v4 scorer diff preserves numerical mathematics and changes only module/adjacent filenames and approved helper/preparer hash bindings. However, the independent same-source positive admission fails on CCR-028 below. `classic-v4-actual-admission-independent-v1.json` SHA `79b61975c5fdda5551942acc1fc48c2ed16deaaee434b91288a32345dff8bae4` binds verified capture/manifest/lifecycle and the **failing** scorer-test log. Its capture eligibility scope must not be read as a passing executable scorer admission or scientific utility result.

## CCR-027 — Active restoration must expect the retained positive transport sync

**Severity:** High. **Confidence:** High for the source-derived mismatch. **Disposition:** exact-sync source remediation independently verified; this restoration point has not been reached in an actual full active run.

`finish_window!` restores zero figure after256 completed exposures and explicitly expects native DM bucket257/sync256. Yet `adopt_figure!` always arms its standard DM sink for exact sequence0 with the zero-header opt-in, then uses the held-calibration receipt helper, which also asserts header sequence0. A zero-valued command payload does not imply a zero-valued transport header.

Unchanged native source propagates the retained last input sync into the output: `hrtClwcBlock.c:3235` writes `lastSyncCounter` to the DM bucket; `hrtWcOutputBlock.c:908` copies bucket sync to its block and `:1009` sets `idFrame`; `hrtStdDmHandler.c:369` places that value in the wire header. RUN itself does not reset `lastSyncCounter`; its reset at `hrtClwcBlock.c:3441` occurs inside reading the next input, which then adopts that input's positive sync. Thus after the last active frame the zero restoration is expected to carry256, while initial zero startup carries0.

Required validation: an active-specific receipt path arms and verifies the exact expected sync, enabling zero only when expected sync is0, with counterexamples rejecting zero for positive and positive for zero. Preserve the held-calibration helper's separate zero-header semantics. Actual final restoration and finite output counts remain required; no experimental restoration failure is claimed from runs that stopped earlier.

## CCR-028 — Classic admission requires an unused helper at the wrong package location

**Severity:** High. **Confidence:** High. **Disposition:** closed after narrow source review and independent same-capture positive/negative replay; scientific characterization remains separate.

Both cache `classic_native_transfer_admission_v4.jl` and maintained `HeartClassicTransfer` include `heart_calibration_coordinates.jl` in `ORIGINAL_HELPERS`, requiring it at `PACKAGE/hil`. The sealed Classic package intentionally does not place that Copper coordinate helper in its operational HIL directory. It exists only in the complete SDK resource tree. The actual Classic evidence helper includes telemetry, calibration client and owner protocol; its scoring path does not consume the Copper coordinate helper.

The independent v4 positive test on actual successful package2 fails `retained Copper helper source differs`; exact inspection shows the other three required helper hashes match and only the coordinate path is absent. The six no-execution marker tests pass, demonstrating why negative-only admission fixtures were insufficient. Log `classic-v4-admission-independent.log` preserves the concrete failure.

Correct the guard to the actual selected dependency closure, retaining full package/artifact sealing and hashes of every consumed helper. Do not mutate the sealed package or reacquire data to satisfy an unused operational dependency. Preserve v4 and issue an explicit corrected cache successor; update the maintained API narrowly. The same successful actual capture must pass after the fix, with consumed-helper corruption still rejected before execution. Scientific characterization remains blocked until that executable admission succeeds.


### CCR-028 independently verified remediation

Cache admission v5 SHA `ee0c60571d06ab21caf46b1cc3f8f17faf2f1c0751664d32a5fe42d4ca2cea53` removes only the unused operational coordinate-helper requirement. Wrapper v5 SHA `8105c422cd015bb704bf71ce7fd88680f51d497e7a98897083c370efcbf476db` updates its module and pinned admission identity; the numerical worker remains byte-identical v4 SHA `b4ae11a56f7d0c298ad7520f8d0d24b9d1b21f9be389363b4a6419761f3001a2`. The maintained SDK SHA `d894562672db44f2e22d9722c08fe3f0c96a0f400970452def7f53dccd3f139a` makes the same guard correction and extracts the unchanged consumed-helper checks for focused testing. Whole package/profile/dependency, retained manifest and stopped-runtime admission remain intact.

Independent cold replay on the same successful package2 capture passes5 assertions: cached and maintained admission dictionaries agree, the absent operational coordinate helper is accepted, the actual consumed-helper set validates, and altered telemetry or corrected Classic evidence hashes reject. The maintained SDK suite separately passes24 assertions. Both processes exit0, with no native owner or GPU execution. The earlier v4 actual positive failure is retained.

Audit `ccr028-independent-remediation-review-v1.json` SHA `cc333b3dc90aa4092a431b484f291332477928c9e7e2e7efcbefa6613ceef3d8` binds exact sources, narrow diff, original failure, actual capture audit/lifecycle and both independent logs. Cache v5 is approved for post-shutdown numerical characterization. These admission checks do not establish paired-loss utility. Full maintained score issuance/replay and its actual mutation checks remain required before active Classic export; issuance and replay must use the same immutable SDK root. No sealed capture or original failed lifecycle was rewritten.


## CCR-029 — Classic score loader assumes every JSON root is an object

**Severity:** High. **Confidence:** High. **Disposition:** loader defect closed by narrow typed-input repair and independent same-input replay; complete numerical outcome remains separate.

The cache v5 wrapper successfully passed full actual capture admission and launched its unchanged v4 numerical worker. That worker's `document(path)` always asks JSON3 for `Dict{String,Any}`. Its actual sealed `heart/classic-transfer/probe-labels.json` is an array of24 label objects. Loading it at worker line89 raises `ExpectedOpeningObjectChar`, before `paired_losses` executes. The maintained `heart_classic_transfer_score.jl` has the identical object-only loader and call. This is a loader/schema defect, not a scientific loss or failed acquisition.

Required remediation: preserve object contracts for metadata and explicitly load/validate the label array, checking expected label container/element shape with the same actual sealed input. Include object, array, malformed and wrong-shape counterexamples. Keep the reviewed mathematics and admission/source identities intact, publish an immutable cache successor, and preserve failed worker outputs. The prior successful admission tests covered admission only and did not establish worker execution or utility.

Independent source/data/actual-error evidence is bound by `ccr029-loader-failure-independent-v1.json` SHA `086811b6fecfca5cddcc29b2c6274de32637ee6abc4ccd7bc0c13507bca50654`. CCR-028 remains closed; Classic numerical transfer utility is still unestablished.


### CCR-029 independently verified remediation

Immutable cache v6 worker SHA `943b8dfe94fd536220ccc6f89922cc621165fc8742850806c595d51e9233ab91` adds a typed document argument while retaining the object default, and explicitly requests `Vector{Dict{String,Any}}` at the labels call. Wrapper SHA `7efde7ce0ad9f7121159fdb9db0ba5da918b4e8cac453a31b1c0752b6c1ce0a3` and admission SHA `6d992e1445da761451201e0b0ecf07accb6986498f1fc32d6b7ae2599b3823fc` only advance names/source pins. The paired-loss function is byte-identical before and after. Maintained worker SHA `b4d8ef785eab59964510437900cf320ac9284ff08f0b1f63862c391c222d06f3` applies the same repair; SDK SHA `8e2c1e03579bce954edc7e9bb3b0f9e518e893391383ab08c34074a4e03013af` additionally declares its worker resource as an include dependency so a resource edit invalidates precompiled source identity.

Independent replay passes7 assertions on the actual unchanged sealed24-label array: old loader rejection, cache/maintained equality, exact direction/count checks and retained file identity. A separate16-assertion suite passes the original numerical fixtures plus object, array, malformed input, nonobject element and wrong label-count negatives. Both cold processes exit0. No acquisition or GPU execution was performed.

Audit `ccr029-independent-remediation-review-v1.json` SHA `e68c04fb26106065b3612145209b4ddb34b2586bba22264367a4591d662ddca6` binds sources, original failure, narrow diff and independent logs. The v6 scorer may characterize the existing successful capture with fresh outputs. The original failed characterization is preserved; no scientific pass is inferred from these loader tests.


## CCR-026/027 frozen v5 remediation: independent cold verification

The immutable `native-correction-preparation-source-v5/deployment` is a140-file snapshot. Independent rehash verifies every copy-proof entry and exactly nine changed/new files versus approved v4, with no deletion. The four scientific helpers and held-calibration owner/telemetry remain unchanged. Active owner SHA `6d81c37d12cd8dad799b310d3c09dec83dd1ea7e65b7e5ae94ddb64a7d1ab9f5`, new phase helper `0add432fe71d1b5c312ed9d5b566447848f76519624a43b3d744a25f081145b3`, analyzer `f49f9f7fdd5bf69bb67cfac47ceb789ab93db2253484bc8704e29f79bf487b29`, exporter `2e391fd4f2366c8bda43d6ed9217cbfe984648ca2591c9cf60375d00e72fbb64`.

The active specialization now tracks startup RUN, CORRECTING and restoration RUN explicitly. Previous files must be fully consumed before a state command. All five next-phase files must exist, be empty, have correct native state/global starting buckets and per-file zero counters before any new publication. The old readers are checked again after rotation and closed; inode/path changes, undeclared streams, extra files, duplicate phases, premature records, partial files and incorrect counts reject. This matches native asynchronous rotation and per-file committed-count semantics. The retained decoder covers all15 files, including empty WFS RUN files, with256 active records per WFS/VDM stream and258 total DM records; post-native-exit verification runs before reset reuses the directory.

Active standard-DM receipt arming and verification use the exact expected wire sync: zero only for initial adoption, positive exposure number during CORRECT, and the last exposure sync for zero restoration. Zero opt-in is enabled only when expected sync is0. The held reader and held zero-receipt path are untouched. No native VDM sync is relabeled as exposure identity; association remains continuous bucket/count plus independently checked payloads.

Independent frozen-source tests passed27 phase,69 owner,28 analyzer and34 SDK-export assertions. The retained actual failed-v3 probe passed56 further assertions: old single-file rejection remains reproducible, while the exact ten original phase files decode with observed global buckets, per-file headers and unchanged hashes. Synthetic full15-file tests cover restoration and reset contracts; they do not establish actual restoration. Exact0/1/256 arming plus six wrong-sync cases pass. All214 assertions passed without native/GPU execution.

Audit `ccr026-027-independent-remediation-v5.json` SHA `6ab4957716ee69951d5390be9a657b5fe5b8ea10e5224be86b823d3969a8b8d8` binds snapshot proof, changed sources, original failure and independent logs. The source gate is approved for a fresh public export that repeats full scientific admission. Final immutable package closure, actual two-window correction/restoration/reset/shutdown and utility remain required before experimental acceptance. Ordinary streaming CCR-017 remains open.


## Actual Classic held-transfer characterization: independent numerical result

Cached v6 actual report SHA `8af4dc82f8b1e75a9adbc3c905661ddbc5c29936db9e829bc0860ee2bc01ebb9` passes the predeclared four-direction transfer policy on the successful corrected package2 capture. Independent rehash verified all514 package and205 evidence files, the admission request and exact worker/wrapper/admission sources, lifecycle and actual terminal state. A separate NumPy decoder read all1,561 retained native gradient records, checked continuous bucket/sync identities, extracted the raw interleaved376 x/y values and reconstructed every accepted public mean. All24×376 Float64-mean→Float32 results match the public capture bit-for-bit.

Using the exact accepted221×376 inverse,277×221 physical map and376×277 forward model, independent arithmetic reproduces each paired response, physical target, forward prediction and physical prediction. The interleaved eligibility mask is applied only as declared; inactive inverse and forward entries are zero, and raw/projected physical predictions remain bit-identical. All scalar losses agree within `3.55e-15` absolute rounding difference.

| Group | Pair traversal | Physical inverse SSE (µm OPD)² | Zero-command SSE (µm OPD)² | Disposition |
| --- | --- | --- | --- | --- |
| sparse | 1 | 0.0003534869103264 | 0.003760306634531 | Pass |
| mixed | 1 | 0.02739922315504 | 0.5041081448819 | Pass |
| sparse | 2 | 0.0003362142268841 | 0.003760306634531 | Pass |
| mixed | 2 | 0.02770031331122 | 0.5041081448819 | Pass |

Every declared projected forward loss also beats its corresponding positive zero-response loss. Raw forward losses and bracket-null diagnostics remain in the producer report. No fit, gain adjustment, threshold change or recapture was introduced by characterization. This verifies held transfer for four selected directions and two paired traversals only: it is not a full native inverse fit, new independent noise corpus, general221-dimensional claim, absolute-bias rejection test or active correction result. The maintained API must still issue and replay its complete score from the same immutable SDK root before active-export admission.

Independent audit `classic-transfer-score-independent-v6.json` SHA `605b06ebad90edf9573ffbc2e0bf7a2cec7065cfb75ba63c97858900545bf849` binds the full input ledger and reviewer source. Log `classic-transfer-score-independent-v6-v2.log` records success. The initial reviewer script required an optional failure key rather than accepting its documented absent-or-null value; its original script/log are preserved, and only that check changed in the successful replay. No production, captured evidence or original failure output was modified.


## Installed active-export entrypoint registration

The final narrow installer edit, `deploy.jl` SHA `7f3c7628c571bdeecd7adcb1cacd4041cb0c77dc4e6b2c754e9a9731fc1bb162`, adds only `export_heart_correction → HeartCorrectionExport` to the existing installed-entrypoint map. Independent source review confirms it uses the existing generated wrapper's `--` argument separator and `exit(main(ARGS))` convention; this exporter's main returns0 on successful publication. The same registration invariant fails in the preserved before log and passes in a fresh independent after process.

The producer focused log reports174 passing assertions, including generated entrypoint/leading-flag execution, exact SDK/module/resource/wrapper copies, and missing scoring/analyzer-resource rejection before destination creation. Tests SHA `966cccff9471de46b970d8723f76b6a9c07ed27274f7c68658debbaf1d440081`. The log includes a Julia precompile notice about already-loaded dependency versions, followed by passing assertions; the independent registration check ran in a fresh process. No science, native protocol or lifecycle behavior changes. Final maintained score issuance/replay must bind the final common immutable SDK containing this registration.

Audit `installed-heart-correction-independent-review.json` SHA `9964cce9bfc3c45aded95596d3b3e7aa9a1ec79539c937377c01da6f5c4dd689` preserves before files/log and exact current source/test/after evidence.


## Active Copper package5: independent closure before experiment

Fresh public package `heart-native-correction-prepared-v5`, descriptor `855f66ba4d36879596b161e6313d33d0e07411135e726812d86df0d68f98d6c7`, passes all514 independent artifact hashes and exact file inventory, plus installed public profile validation without GPU imports. Exactly11 artifact entries differ from failed package3: approved active owner/analyzer and new phase helper at operational/SDK locations, exporter/test, and contract/admission/provenance. No artifact is removed. Every scientific controller/map/plant/dependency, native configuration, unchanged native executable and canonical RTC binary remains exact. RTC binary SHA `490fe9fa67f9f1266fdf7901c5f275eb8065ca885d197e198e1092a17a22f16f`.

Contract SHA `3a79d0f4e3557c1bc3cdb3e39d0a4fd7d76923581de68f4aa861048408f5bae7` preserves all13 flags, positive0.01 gain/pole0.99, selected negative253-coordinate CM, normal CUDA plant and explicit two32-row deferred ingress. Only the fresh cold admission and three additionally bound unchanged native transport/telemetry source files differ. Public cold admission SHA `16268b0c354f22f9c56809a52a11cbb338810989328572111409dadb65b69714` records364.57s full replay: all scientific result fields match the reviewed previous admission exactly, and24,158 input identities match after normalizing nine unchanged helper paths from source snapshot v4 to v5. Those relocated files were independently rehashed.

Reviewed wrapper v2 SHA `78f0e63eb187fdc73c8e2732200e0f0d17045fbf1303c8d998cfbf7149c0ccd1` is unchanged. The owner directory `hn-active-v5`, proposed short runtime and evidence paths were absent at review. Audit `native-active-package-independent-v5.json` SHA `a92a4b2db6f87b152fbeb063345ba55857310dc1e8c96f79b35d9876331a620d` binds source, installed-profile log and prior review. This approves the selected finite experiment; actual two windows, restoration, reset, shutdown and correction utility remain required. Missing-binary preparation4 and interrupted retry evidence are not relabeled as successful exports. Ordinary streaming CCR-017 remains open.


## Actual package5 first window: restored successfully, ADC gate failed

The public attempt using package5 and runtime/evidence revision6 completed256 active exchanges and then zero restoration. Independent closed-file decoding passes20 assertions over all15 retained files:256 raw/calibrated/gradient/VDM records,256 active DM records, startup DM bucket0/sync0, and restored DM bucket257/sync256 with all277 values literal positive zero. The journal records the three ordered empty-file admissions,256 active command associations and final zero-figure transport receipt. This verifies CCR-027's actual restored positive sync and CCR-026's first-window phase handling. Reset and the second window were not reached.

The owner correctly rejects its then-declared zero-rail rule: science raw bytes equal native raw telemetry bit-for-bit and contain exactly two ADC values16,383, at exposure21 row17/column25 and exposure26 row25/column17 (zero-based pixel coordinates). Original owner/science failure, false lifecycle gates and retained files remain unchanged. Direct OPD ratios0.71532826/0.64901911 are descriptive failed-run diagnostics only, without independent GPU replay or scientific acceptance.

An independent source-based recurrence check uses `vₙ ≈ 0.99f0 vₙ₋₁ + 0.01f0 Rctrl yₙ`, exact selected negative matrix and native gradient/VDM payloads. TFC's no-temporal-filter branch scales by the HO gain; CLWC updates its leaky integrator with scalar1. All coordinate discrepancies fit a conservative Float32 product/sum bound; maximum absolute discrepancy is0.000177063µm in VDM coordinates, with maximum bound fraction0.000393. The physical DM peak is0.154324µm; the large497.917µm VDM peak must not be confused with physical actuator demand. These checks provide no evidence for a sign, gain or recurrence implementation defect. Native and earlier engines have separately measured inverse bytes and may differ after feedback; frame3 is their first raw difference.

## CCR-030 — Calibration and normal-correction ADC acceptance differ across adapters

**Severity:** Medium. **Confidence:** High. **Disposition:** confirmed adapter policy difference; primary explicitly adjudicated normal-policy alignment, independently verified in source-v6. Fresh-run acceptance remains required. No instrument saturation threshold is supplied.

Both reset batches of the earlier FGN CUDA, JFG CUDA and FGN AMD correction captures contain exactly the same two rail pixels at the same exposure/pixel locations. Every compared frame file matches its recorded SHA. Their finite correction reports omit `detector_diagnostics`; the trusted original analyzer explicitly requires encoded ADC values no greater than the selected rail, exact ADC/live-OPD replay and a verified zero-command baseline. It never established absence of saturation. Their finite correction evidence must disclose these rail hits; it is not evidence of unsaturated operation.

Policy evidence distinguishes held calibration from normal dynamic correction. `COPPER_QUALITY_PLAN.md:54–69` defines the serialized hold/adopt/settle/capture protocol and rejects any ADC at or above the rail. The frozen cohort reader `analyze_copper_cohort.jl:41–43` and native calibration capture helper require zero rail frames/pixels. In contrast, the original `run_finite_correction.jl:18–40` requires exact256 counts, chronology and direct truth; frozen `analyze_correction.jl:228–229` permits values equal to the rail and verifies the actual encoded dynamics. The frozen cohort policy preserves failed correction outcomes and forbids gain/settings tuning, but does not establish a zero-rail requirement for all normal correction routes.

The new native active owner and analyzer nevertheless explicitly imposed zero rail hits before this run. Any subsequent change is therefore an **explicit post-observation policy alignment**, not proof that this native run passed its original gate. Independent recommendation: if the primary adopts the original normal-correction policy consistently, preserve strict zero-rail calibration admission, keep all scientific settings/coefficients unchanged, retain exact ADC rail counts/locations and diagnostic limitations, freeze the revised policy/source tuple before a fresh full run, and preserve this failed report. Do not retrospectively pass the old capture or claim unsaturated/hardware qualification. Native finite correction still requires actual reset, cleanup and same-backend replay.

Diagnostic evidence: `native-adc-independent-diagnostic-v5.json` SHA `87ae88969d960ef21168e832ad60214ab7228b2dd8b5c71f5a637808d70f55f3`; expanded six-capture comparison and recurrence bound `native-adc-independent-followup-v5.json` SHA `022874a76b6038f70b569aec06b700b0908c9c75a010d983fd56e3b063c1bd1d`.

Policy/source/phase evidence ledger `native-adc-policy-independent-v1.json` SHA `fce5317f538762092c49417021d1579173aea107d310a74fdbea192a2d973e37` binds the pre-existing files and independent phase-test log. No reviewer native/GPU launch or evidence rewrite occurred.


## Frozen combined source-v6: Classic geometry and normal detector-policy review

Primary adjudication explicitly changes the native normal-correction detector policy after observing the failed run, while preserving calibration's zero-rail admission. The new named policy `normal-correction-adc-bounded-replay-v1` is required in the sealed active contract and launcher preflight. `HeartCorrectionProfiles` recomputes maxima, rail pixel/frame counts and invalid response counts from every retained raw/gradient record and checks exact agreement with reported diagnostics. Values above the declared ADC rail, nonfinite measurements, false counts and undeclared invalid responses after initialization reject. Rail hits remain visible observations; exact replay, finite improvement over baseline and unchanged DM limits remain separate gates. The old failed report is unchanged and cannot pass the new contract automatically.

Independent rehash verified all149 entries in `native-correction-preparation-source-v6/deployment`, copy-proof SHA `1c3c2bc590470efd1b168d8543f01841e6b4e007f4c63c71b48912b32a878acf`. The four scientific helpers, held-calibration owner/evidence/method/telemetry and calibration capture helper are byte-identical to v5. In particular, calibration's strict zero-rail check is retained. Owner/analyzer invoke the shared payload-derived diagnostic check; active source changes do not tune lamp, exposure, gains, inverse, detector or native binary.

Classic active source requires the actual maintained native transfer report to be fully reproduced before package construction. The geometric lift derives the one-hot selector from the exact221×277 full-to-active map, verifies distinct nonprefix indices and native `E[:, indices] == B` bit-for-bit, and embeds the accepted positive221×376 inverse into277 rows with56 positive-zero rows. Independent actual-data reconstruction produces raw SHA `795702802929efb45950bf4bb5f7da88ec919552662efea7847db948c0508d00` and FITS SHA `df3bf5c06416b2600e282b6415386d7804c6147853a242c2cda4ef7bac54e47f`, matching the accepted proof. There is no extrapolation pseudoinverse. Original native gain−0.3, pole0.99, sparse E, default physical copy, measured background/reference and permanent inactive mask remain required. Separate Float32 E and P error propagation witnesses physical demand without collapsing the two operations.

The declared Classic detector is352×352, gradients188 state/x/y/flux records mapped to376 interleaved coordinates, VDM277 and physical DM277. Raw inactive slopes remain retained and their admitted inverse columns are zero. The largest256-frame phase file is126,895,104 bytes, below the explicit128MiB bound; Copper remains16MiB. Strict15-file phase transitions and exact transport sync apply to both profiles. Classic uses ordinary streaming; Copper retains the separately scoped deferred fixture.

Independent focused verification passed306 assertions: synthetic geometry12, actual accepted geometry10, telemetry33, profiles51, owner76, analyzer34, phases34, SDK export43, and actual failed-corpus policy13. All processes exit0 without live or GPU execution. The actual failed corpus test checks the new statistics and rejects diagnostic mutations, out-of-range pixels and nonfinite responses, while explicitly asserting the preserved failure and unretained-success flag.

Wrapper `run_native_correction_v3.jl` SHA `41af506e77b0524e024fc706145e611f390715fddba67e848e1d50800b074d7b` changes only profile/capacity/policy preflight and truthful record fields versus reviewed v2. The public startup, two-window stop/reset/restart, owned cleanup and post-shutdown replay remain intact. The source is approved for fresh Copper public export and maintained Classic score issuance from this exact absolute immutable SDK root. Fresh immutable package closure, complete managed score replay for Classic, and actual lifecycle/correction outcomes remain separate gates.

Audit `native-active-source-independent-v6.json` SHA `c116eb2a2f65006861c7fde1bfff48504b79f7908ffedf180eb20147240e876c` binds the complete source inventory and all independent logs.


## Actual maintained Classic score: source-bound issuance verified

Report `classic-native-transfer-managed-v1.json` SHA `2a5638a26fa31d2ba659c98cd64ec3aa134c9c7ccf9592cebe04b05408bdd4db` was issued from the final absolute source-v6 SDK. Independent rehash verifies all744 inputs, including every SDK source file under that exact root, retained package/evidence/lifecycle, accepted forward model/preparation and selected controller. Worker identity b4d8ef78… and maintained replay source8e2c1e03… match the frozen snapshot.

Every shared scientific/result field is exactly equal to the independently recomputed cache v6 result; only the expected producer identity differs. This includes all four loss groups, raw means, reference diagnostics, native1,561/1,536 verification and source/science identities. Compact bb9aa683… and padded FITS df3bf5c0… match. Audit `classic-managed-score-independent-v1.json` SHA `99b7875475ac548486cc329e73417c9bdce80640879b2891430017e37df77e51` approves this report as input to fresh active preparation. The public exporter must repeat the full maintained replay from the same root before constructing output; final package closure and actual active qualification remain separate.


## Final source-v6 actual Classic and Copper package closure

Classic package `heart-native-classic-correction-prepared-v1`, descriptor `7eef9f2ec2d4d568556513fbb389a509113f55b120741d0982efaef108bcec46`, passes independent verification of all525 artifact hashes and exact inventory. Copied SDK and active helpers match the approved immutable source-v6. Scientific packages, all original calibration files, normal plant and four scientific helpers remain byte-identical to the accepted CUDA base. The inherited, unused top-level calibration-method analysis helper remains its base version; the copied SDK resource is the final version. The generated HIL Project is a prepared environment, not a verbatim SDK resource. Initial reviewer mapping assertions that conflated those roles are preserved in the first logs and corrected in the final audit.

The actual native sparse E columns selected by the221 nonprefix controller indices equal the accepted B bit-for-bit; physical P is identity. Installed positive padded FITS df3bf5c0… equals the accepted proof, with original gain−0.3/pole0.99 and unchanged operational offsets, thresholds and permanent mask. Streaming ingress is explicit. All745 cold-admission input hashes match: the744 managed-score inputs plus that issued report itself. Every other managed-score field is reproduced exactly. Contract SHA `6fa18eda427cac633fc8ef382f1c4e9c5fe0fbf010829c0c918099161726204e` and cold-admission SHA `2e88343b6ffce7b35f52a58afbc26a770f0a3e0fefa4a7133e699793a1c0d401` bind the actual result.

Audit `native-classic-active-package-independent-v1.json` SHA `1f7a997d289498e0ca6eb22f40fc643a2a99595d95ee84c73585f68fa9a94e16` records these checks. The installed package's public `Deployment.profile(path, prefix)` exits0; an earlier reviewer one-argument invocation was a harness MethodError, preserved separately. No production failure was inferred from it.

Copper package `heart-native-correction-prepared-v6`, descriptor `4094c82489c59ce77563eb857ece440d612f4c5e1b5c61fc614242a7e943aa1f`, passes independent verification of all522 artifact hashes and exact inventory. All29 changed artifacts against package5 match approved source-v6 resources or the expected contract/admission/provenance updates. Native executable/configuration, selected inverse, maps, scientific dependencies, normal plant and scientific helpers are unchanged. Contract changes are exactly the explicit normal detector policy, telemetry capacity, truthful reference-mode label and new admission hash. The scientific replay result is identical to package5 after removing elapsed time and normalizing the source-snapshot path; every current retained input hash was rechecked.

Copper contract SHA `1b9336fd26309b982d119ca5e2d8d64293e2eeb80940e2c97d32efab7af2ac5d`, admission SHA `ef773473b7d4875a23ae16f3bf177daed1a541560f275f308bc0767c70d2390f`, and audit `native-active-package-independent-v6.json` SHA `1ed16f64ec47ff3c2e942ef250d26404f236a1bff777e80c24a71a95c7b85550` identify this closure. Its installed public profile also exits0. Both fresh external owner roots were absent at review, and wrapperv3 remains SHA `41af506e77b0524e024fc706145e611f390715fddba67e848e1d50800b074d7b`.

**Disposition:** both immutable packages are approved for parent-owned, serialized finite experiments. This is prelaunch source/package approval. Actual two-window/reset identity, restoration, cleanup, unclipped command witness and post-shutdown same-backend correction utility remain required. Copper's deferred mode does not close ordinary-streaming CCR-017. Previous failed captures and their original acceptance gates remain unchanged.


## CCR-031 — Classic contract rejected by Copper-only flag equality

**Severity:** High. **Confidence:** High. **Class:** observed runtime defect, independently reproduced cold.

The first active Classic attempt using descriptor7eef9f2e… exited before acquisition. Its lifecycle retains batches/replays/shutdown false and owned fallback reaping with launcher exit1. The owner at `heart_correction_owner.jl:160–161` converts sealed contract flags to triples, then requires exact length and equality with a global13-entry `REQUIRED_FLAGS` defined for Copper. The correct Classic contract and native requirements contain24 flags:12 CLWFC plus12 TFC. All13 Copper flags are present; the extra11 valid Classic controls cause rejection. They disable TT disturbance/offset, field rotation, HO/LO optimization, extra HO/LO input vectors, Kalman, LGS defocus and LO aggregation. No required Classic condition is missing.

Independent `ccr031-classic-contract-before.jl` includes the exact immutable package owner and calls its public contract-loading function with the actual sealed Classic paths. Five assertions pass, including observation of the identical `native correction flags omit a required scientific condition` error before any owner or GPU launch. Source, contract, requirements, failed lifecycle and reproducer/log are bound in `ccr031-independent-failure-v1.json`, SHA `46b18208c562b31ea1d91d447edc5f65ce6da852f1001b9fd78f860b74d67c04`.

**Remediation:** validate exact per-profile required sets, preserving all24 Classic controls and unchanged13 Copper controls. Do not accept arbitrary supersets or delete Classic requirements merely to satisfy the old owner. Validate actual sealed Classic and Copper contracts, plus missing, extra, duplicate and wrong-value flags; then construct a fresh sealed package and retain the failed original unchanged.

**Review coverage correction:** the previous closure review verified the correct24 Classic contract/requirements and immutable package inventory, but did not exercise actual owner `load_contract` with that contract. Synthetic owner tests and public deployment profile checks did not establish this cross-profile path. The failure is a confirmed missing integration check, not evidence that package seals or the scientific transfer score were wrong. Classic prelaunch approval is withdrawn until remediation is independently verified. Copper's exact13-entry contract remains unaffected.

**Disposition:** open; worker remediation assigned by primary. No production source edited by reviewer.


## Actual final Copper native correction: two windows and scoped utility accepted

The fresh source-v6 Copper experiment completed with parent-observed driver exit0. Final lifecycle SHA `75b582b9e4a644a2ab12f3df9189917d8a4197efd6429e64b505cb7ab5b884ad` records batches, public shutdown and both post-shutdown replays true. Independent read-only checks confirm the retained actual runtime state equals the lifecycle final state, is stopped/unadmitted/error-free, and has no owned instance directory. All seven recorded supervisor/core/HEART-owner/source/RTC/native-generation PIDs are absent. Native generation1 and generation2 have distinct PIDs; reset evidence records generation2 held with zero admitted frames before restart.

Independent cold verification of both actual retained windows passes28 assertions plus exact direct-truth equality. Each window contains15 strict phase files,256 raw/WFS/VDM records and258 DM records. Public ACKs, chronological journals, source-frame bytes, transported metre commands, native micrometre commands and the independent no-clipping projection witness all verify. Startup zero is bucket0/sync0; restored zero is bucket257/sync256, with literal positive-zero physical payload. Both ADC and adopted-command payloads and the complete live truth records reproduce exactly after reset. This supplies the previously missing actual reset evidence for CCR-026 and confirms CCR-027 through both restorations. The first reviewer archive probe assumed both archives were named `after-native-exit`; the second window uses the valid retained `before-reset` archive selected by the maintained verifier. That harness error is preserved; the corrected probe uses the same explicit archive selection and passes.

Both windows independently contain exactly two upper-rail pixels: completed frame21 at zero-based detector row17/column25 and frame26 at row25/column17. Maximum ADC is16383, and only the declared first response is invalid. No physical command component is at the0.8µm limit; maximum is approximately0.154324µm. These observations satisfy the explicitly revised normal detector policy, not the prior zero-rail gate. All calibration zero-rail rules and previous failed reports remain unchanged. CCR-030 is closed only for this fresh, disclosed normal-policy experiment.

Post-shutdown analysis reports have SHA `b6d7bed1ecd7f22962078c99fb6c737069a1d106623f89f96bf42001bfab099f` and `da48f76f6923e7fcf68e071649054755bfe301674c4407fe5dd5047cf66c2295`. Independent report/source/payload checks verify exact ADC replay, exact live direct-OPD witness agreement, zero-command baseline flags and all256 frame associations. Recomputing the retained live variance averages gives residual/zero ratios0.7153282640621832 over frames17–128 and0.6490191124625735 over129–256 in each window. Both declared windows improve on zero without coefficient or lamp changes. The reviewer did not execute GPU replay; this audit verifies the actual producer replay artifacts and independently reconstructs their scalar utility from the retained direct witness.

Initial lifecycle/payload audit `native-copper-windows-independent-v7.json` SHA `f9692c1848cbbd12480c3ae2435f9ca0e51445b049bc73760ab5c34300846bc8` and final audit `native-copper-windows-independent-v7-final.json` SHA `14c85ba356cd9eeffc2b9b416b34d75d5b025aa8ccbbfa1981d9554d66bddfa0` bind885 evidence inputs in the final record, including both analyses, final lifecycle and independent cold test scripts/logs.

**Disposition:** accepted for the declared finite, completion-driven Copper native simulation experiment using the frozen measured inverse and revised normal detector policy. This does not qualify ordinary progressive ingress, unsaturated sensing, hardware cadence, RTC latency or instrument performance; CCR-017 remains open. Classic active correction remains separately blocked by CCR-031.


### CCR-031 independently verified source-v7 remediation

Immutable `native-correction-preparation-source-v7/deployment` contains151 entries, all independently rehashed against copy-proof SHA `a73a2c063af397b2bac693f3b42a1a056a2c7ac89deca663537bc0b9d074c8bd`. Exactly10 entries differ from v6, including the two new flag-helper/test files;141 entries remain unchanged. Scientific helpers, coefficients, phase/payload algorithms, held-calibration sources and maintained Classic score mathematics remain exact.

`HeartCorrectionFlags` now defines exact13-entry Copper and24-entry Classic contracts. Typed dictionary field dispatch and a property-access fallback support the actual serialized and in-memory forms. It rejects missing, extra, duplicate, altered, Boolean and noninteger flags. Owner contract loading and startup proof, exporter contract publication and retained analyzer all use that same per-profile validation. The SDK exporter declares the helper as an include dependency and copies it into both operational HIL and SDK resource trees; the analyzer binds its actual included bytes in `LoadedSources`. No permissive-superset rule replaces exact admission.

The independent actual-contract test runs against the frozen v7 owner and both original sealed package contracts: Classic24 and Copper13 load successfully, and their sets exactly equal the corresponding native requirements. The same suite tests JSON3 objects, dictionaries and named tuples, plus missing/extra/duplicate/wrong-value/Boolean/nonintegral/cross-profile rejection through both shared validation and actual owner loading. All42 assertions pass; included HIL source hashes remain unchanged before/after. The original exact Classic rejection and old package/lifecycle remain preserved.

One initial reviewer negative incorrectly assumed JSON3's untyped parser would preserve the lexical token1.0 as Float64. It normalizes a mathematically integral value to integer1; that is not a scientific flag change. The corrected serialized negative uses1.5, while direct typedFloat64 input is still rejected by the shared validator. No production parser change or weakened flag rule was requested.

Audit `ccr031-independent-remediation-v7.json` SHA `148b4b786ff013c9ffecc8a589a54a44f2f4061ed2d62894cdaff6a162bfb94b` binds the151 source files, original sealed contracts/requirements and independent test/log. **Disposition:** source remediation verified and approved for fresh maintained-score issuance and public Classic export from this exact absolute SDK root. Actual fresh package closure and complete live qualification remain required; the old failed Classic attempt is not promoted. Accepted Copper source-v6 evidence remains valid and separate.


### Fresh Classic package2 after CCR-031: actual loader and closure pass

Managed score-v2 SHA `643b9d58a0a414c76f8344e65c897666915bc165ae04ab0936a2da203d9a46f9` reproduces every prior scientific/result field exactly. Independent rehash verifies all744 inputs, including every source-v7 SDK module under its exact absolute root; only expected source-root relocation and the two changed correction-export module hashes differ from score-v1. Audit `classic-managed-score-independent-v2.json` SHA `bbce942e2b196a7e494910c7a46f7802c301b358649484b86aa06e228ca0c9da` records this check.

Fresh `heart-native-classic-correction-prepared-v2` descriptor `4db94cfacd93cd568ab18d06f01ae2b56ec851cba4e894ffdd0517f6411577b6` passes all527 artifact hashes and exact inventory. Every changed operational/SDK file equals frozen source-v7. Native configuration/binary, selected positive padded inverse, actual E/P maps, original calibration, normal plant and scientific dependencies remain byte-identical to package1. Contract SHA `3a055e6b495c5b8bc1c6daf0367149b86e414df1896e5b6811c92d2f72d143bd` differs only in managed-score/admission identities; admission SHA `117137e3d8aead5a638945d95cfe371763bf8a3772d92f2245ca8175bf67f42c` exactly reproduces the new score and binds745 verified inputs. Provenance changes only the expected contract and input ledger.

Crucially, the independent cold process loads this actual package's SDK and owner, then calls both `Deployment.profile` and `HeartCorrectionOwner.load_contract` on the packaged paths. Six assertions pass, including the exact24 flags and277×277 zonal projection. All528 package files remain unchanged before/after; `hn-ca2` was absent. This is the same loader boundary that failed for package1, with no native/GPU launch.

Package audit `native-classic-active-package-independent-v2.json` SHA `d1fc228834bc87c4c9e29bde8560b2b653624eabd6a809a9abc324fc60e66258` and final prelaunch ledger `classic-active-v2-prelaunch-independent.json` SHA `5112fcf3f2524a2aa74d867d92f7fdd72e22aaac2c59b7ad112c0f6fd9828061` bind the closure, exact loader script/log and score audit. **Disposition:** approved for the parent-owned serialized finite experiment using unchanged wrapperv3. Actual two-window/reset/restoration/cleanup and same-backend replay remain required; the failed first attempt remains unchanged.


## CCR-032 — Active Classic setup overwrites the correct graph output with Copper's name

**Severity:** High. **Confidence:** High. **Class:** observed runtime failure and direct source contradiction.

Actual Classic package2 descriptor4db94cfa… passed the repaired contract loader, then failed before acquisition because `run_owner` constructs its calibration boundary with `frame_output=:pwfs_frame` unconditionally. The unchanged `simulator.jl:116` already selects `:shwfs_frame` for Classic and `:pwfs_frame` for Copper, prepares that exact HIL boundary and verifies352×352 versus64×64. The active owner successfully prepares this graph, then discards the profile selection while changing only the completion boundary. Its own second lookup therefore fails for the legitimate Classic graph. The first evidence-window directory is empty and lifecycle success gates remain false; no retained exposure or correction utility is claimed.

**Required remediation:** bind the completion boundary to the same profile-correct prepared output, preserving the original normal graph, buffers, controller coordinates, driver reset and truth witness. Exercise the actual normal Classic CPU graph before transport/native/GPU startup, including both failure of the old lookup and successful corrected boundary/recorder/truth preparation. Audit remaining profile-specific setup, acquisition dimensions, calibration decode, native projection, reset and analyzer paths rather than relying only on synthetic fixtures or a profile descriptor check. No scientific coefficient or graph rewrite is indicated.

**Disposition:** open; primary assigned narrow implementation and full preparation audit. Independent CPU investigation is in progress, separate from native live qualification.


### CCR-032 broader independent preparation investigation

The reviewer independently prepared the actual package2 normal Classic graph on the CPU, without owners, transport, native processes or GPU imports. Fourteen assertions pass: the old `pwfs_frame` lookup rejects; `shwfs_frame` binds352×352 host pixels and277 commands; full recorder and direct OPD witness preparation succeeds; the first frame is finite and within12-bit ADC bounds; exact row-major encoding is retained; adopting a subsequent command changes only the command input and does not rerender the current detector frame or pupil OPD; second exposure time is2ms; resetting the graph/driver/recorder and adopting zero reproduces the first detector frame exactly. Thus the1.896ms exposure and2ms model period remain distinct and consistent.

The initial reviewer fixture omitted two timing fields consumed by `record!`; that harness FieldError is preserved separately. The corrected fixture supplies the actual owner's timing tuple and passes. It is not an additional production defect.

Read-only cross-module audit covered profile dispatch in native session buffers,352² calibrated images,188 state/flux records→376 interleaved gradients,277 native coordinates, permanent active mask, separate E/P projection witness,12-bit diagnostics, phase archive capacity, exact-sync restore, graph/native generation reset and the same-backend analyzer. Copper-specific defaults are overridden by actual Classic profile arguments at these call sites. No further confirmed defect was found in that audit; native transport and actual correction remain experimental gates.

Evidence `ccr032-independent-setup-v1.json` SHA `062fdf98eab4c9d3854de3e70506e4057788634aa68b6e332751bb313e5c67ba` binds the failed lifecycle/log, original source tuple and CPU probe. Frozen remediation still requires an actual call through the new production setup entry point, followed by fresh package closure and live qualification.


### CCR-032 source-v8 remediation verified through actual production setup

Frozen source-v8 copy-proof SHA `8d384714e49e48f6910e12fcd91f0c078a81cc23a3531c4ba8b0e91bb225bfb1` binds151 files, independently rehashed. Exactly three entries change from v7: the active owner, profile descriptor and profile tests. All148 other entries, including the four scientific helpers and maintained scoring implementation, are unchanged. The profile descriptor names `:shwfs_frame` for Classic and `:pwfs_frame` for Copper; production `prepare_boundary` uses that field and checks the declared detector extent and277 physical commands.

The independent actual normal Classic CPU probe now invokes this frozen production helper itself. All15 assertions pass, covering the old lookup's failure, corrected boundary, complete recorder/direct-truth preparation, valid first12-bit frame, exact row-major recording, adoption without rerendering the current OPD/frame,2ms exposure-start progression, reset reproduction and included-source stability. No transport, native process or GPU was started. Audit `ccr032-independent-remediation-v8.json` SHA `a583640f2a08d66e21647e41cf22519ebda524e355806daec3cdcaec9f917230` binds the full source tree and reproducible script/log.

**Disposition:** CCR-032 source remediation independently verified. Source-v8 is approved for fresh managed Classic score issuance and public export from that exact absolute SDK root. Fresh package closure must cover the actual owner loader and prepared boundary; full native two-window lifecycle and utility remain required. Both previous failed Classic attempts remain unchanged.


### Final actual Classic package3: complete cold preparation verified

Managed score-v3 SHA `1e88f2963097184229245964329a48d0a4b5b3b7b0be76a3b9ce75b48db1d86e` independently reproduces every scientific/result field of score-v2. All744 input hashes match; after normalizing only the source-v8 absolute-root relocation, the ledger is byte-for-byte equivalent to score-v2's identities, consistent with unchanged SDK scoring source. Audit `classic-managed-score-independent-v3.json` SHA `97041ccc0785e6c14737f80fe8d331b0d3dd921d37d1f2ce07008d77001e4b4c` binds that verification.

Fresh package3 descriptor `170f04fa0de55e7bf6fb76aaba3948ee4bdd97a0ab9000d97b3cef3bc75ac7b5` passes independent527-artifact hashing and exact inventory. Changed resource bytes equal frozen source-v8; native executable/configuration, accepted selected matrix, actual E/P geometry, normal plant and all scientific dependencies remain exact package2 bytes. Contract SHA `b43bafee88f2eae405c7fd3dadffb5f7bf4706c189cb74f4ee20704b09e441ee` changes only current score/admission identities. Admission SHA `210f66c5c78e439d6ac64a0fdf69d4210fdc1d6eaffaaf0505bdaf7c74c089a8` reproduces score-v3 and binds745 rehashed inputs. Parent's first preparation invocation supplied a lifecycle file where an evidence directory was required; it rejected before publication, and the corrected successful retry remains a separate log. No failed evidence or source was rewritten.

The independent test loads this actual package's SDK and active owner. Public profile and contract-loading checks pass5 assertions. Using its captured dependency environment and unchanged normal plant on the CPU, the production boundary/recorder/direct-truth/reset test passes15 more assertions. It verifies352² pixels,277 commands, correct graph output, row-major ADC encoding, command adoption without rerendering the current frame/OPD,2ms chronology and exact reset reproduction. All actual package files remain unchanged. The external `hn-ca3` root was absent at review. No transport, native process or GPU was started by the reviewer.

Audit `native-classic-active-package-independent-v3.json` SHA `cc23716b043f2660f919b62dd4e5d558ed184dd1272e8b44a2b8669975c22f72` and prelaunch ledger `classic-active-v3-prelaunch-independent.json` SHA `028d97613c32e7671340198e2c7ee630f297fe45dc3ba6cc3c186b3e515d4bb2` bind the actual closure and20-assertion script/log. **Disposition:** package3 approved for the parent's serialized finite experiment. Both CCR-031 and CCR-032 preparation failure boundaries are now exercised on the actual package. Native two-window/reset/restoration/cleanup and post-shutdown correction utility remain required.


## CCR-033 — Classic startup decodes a legitimate runtime map link as a forbidden input

**Severity:** High. **Confidence:** High. **Class:** actual runtime failure, independently reproduced through the full startup proof.

Actual package3 successfully prepared the graph and endpoints, then failed before readiness while checking native extrapolation E. Public `HeartOwner.arguments` deliberately renders a private runtime configuration whose calibration entries are symlinks to regular sealed package files. `startup_proof` first hashes every runtime input successfully. Its Copper branch resolves the map's real path before strict FITS decoding, but the new Classic branch passes the unresolved runtime link to `sparse_extrapolation`, which deliberately rejects symlink inputs. The error therefore reports a map-bound failure despite exact source bytes and shape. This is an integration mismatch between legitimate runtime layout and the strict low-level decoder, not malformed scientific E.

Independent seven-assertion fail-before fixture invokes the actual package's public runtime preparer, verifies its E link and every sealed runtime input, decodes the resolved E bit-exactly against the wire matrix, then calls the full original `startup_proof` and observes the same ArgumentError. It uses actual retained native status/configuration/ACK files; only process liveness and no-outstanding-exposure cursor are explicit test doubles. It launches no owner, transport or GPU. This covers the deployed link layout and subsequent proof control flow beyond the prior graph-only preparation checks.

The failed lifecycle keeps batches/shutdown/replays false and launcher exit1. Actual state is failed/unadmitted. All five recorded processes—2173481,2173524,2173526,2173722 and native2173569—are absent, and owned instance `run-yQ0iDb` was removed. No correction exposure/utility is accepted.

**Remediation:** after the existing exact runtime-input identity checks, resolve Classic E's runtime link before strict regular-file decoding, as the analogous Copper branch already does. Preserve content hashes, extent checks and bit-exact equality against the sealed wire map. Require the same full startup-proof fixture to pass, while changed linked target bytes and changed wire E still reject. Do not relax the low-level decoder globally.

Evidence `ccr033-independent-before-v1.json` SHA `2d0d57aa59b0bae0543ecab5ad53af4d0013502012d79e765e45fa2a696b19b8` binds the failed lifecycle/log, runtime status, decoder/owner/preparer sources, independent fixture/log and cleanup observation. **Disposition:** open; primary assigned narrow remediation. Further Classic-only path review found no additional confirmed defect, but actual native phase/command/reset/replay qualification remains mandatory.


### CCR-033 source-v9 remediation verified through complete file-backed startup proof

Frozen source-v9 copy-proof SHA `1c4fa243b2abaea4d06a06fa8690a9cbab88d3a9feb4eaa04159cf83be620627` independently verifies151 files. Only the active owner and its focused test change;149 entries remain exact source-v8 bytes. `read_native_extrapolation` resolves the legitimate runtime calibration link, rechecks the resolved file against its sealed runtime-input SHA, and invokes the unchanged strict sparse decoder. The existing full runtime-input hash loop and final bit-exact wire-E comparison remain in place.

The same independent public-rendered runtime fixture now traverses the complete production startup proof successfully: nine assertions pass, compared with seven before-fix assertions reproducing the original rejection. It checks all27 retained actual Classic INIT/RUN/CORRECT/flag acknowledgements, exact rendered/source configuration and streaming environment record. Both a changed wire extrapolation and a redirected link with altered bytes reject. Original package and retained failed inputs are unchanged. Only process-liveness and zero-outstanding-exposure cursor are explicit fixture doubles; this is not a substitute for actual native generation or timing qualification.

This extends the audit beyond graph setup and individual decoder calls to the deployed calibration-link layout and remaining startup file/ACK checks. Acquisition and restore/reset paths retain profile-specific352²/188/376/277 geometry, permanent-mask validation, separate E/P no-clipping witness, exact sync and bounded15-file archives. No further confirmed Classic-only defect was found in that source audit. Runtime delivery and scientific utility remain unobserved for Classic active correction.

Audit `ccr033-independent-remediation-v9.json` SHA `eab021bf84cd84e5f59261f6b630a50931bdeb61a88968e6b0ad4286a927785d` binds151 source hashes, same-test before/after evidence and the failure/cleanup ledger. **Disposition:** source-v9 approved for fresh same-root score/export. The resulting actual package must pass its public-rendered layout and full startup-proof fixture before launch; a fresh complete native run is still required. The failed package3 attempt is not promoted.


### Fresh actual Classic package4: deployed file-layout proof passes

Managed score-v4 SHA `91d952398fa7906a2d91fbd2bfce2e823db426a678c59d3ec997d5e689c19c53` independently matches every scientific/result field of score-v3, and all744 inputs rehash correctly. Its ledger differs only by exact absolute source-v9 root relocation. Audit `classic-managed-score-independent-v4.json` SHA `6ea80d75bc4a29d6893c8342b70160c6d68d6a4e04301ec0608ed53429800a72` binds the result.

Fresh package4 descriptor `a0558e98b809ba1e4764e92b8730e5887b61ef3ad7d9935c273933eab97fdfea` passes all527 artifact hashes and exact inventory. Exactly five artifacts change versus package3: two copies of the narrow owner fix, provenance, contract and admission. All scientific files, native binary/configuration, maps/controller, plant, dependencies and SDK source remain identical. Contract SHA `9530db2f8427c55712a87872fd079e1e37086c71708fc4fe9aabe3cbf06c25a4` and admission SHA `dbd91012c9a339a71293fbbb9309fb8a9fab811b9d5666a93936ffa8801017f8` bind score-v4 and745 independently rehashed replay inputs.

The actual package's public profile, contract loader, public native-runtime renderer and full startup proof pass ten assertions. The renderer creates the legitimate calibration links; all27 retained actual acknowledgements, configuration bytes, streaming environment and native E equality verify. Altered wire E or linked-target bytes reject. The fixture explicitly substitutes only process liveness/no-outstanding-exposure state and rebases retained package paths; it starts no owner, native process, transport or GPU. Every original package/evidence input remains unchanged.

The complete `prepare_boundary`/`run_owner` tail and all graph/recorder/truth dependencies are byte-identical to actual package3, whose20 CPU preparation assertions passed. Those checks therefore compose with the new targeted runtime-layout test; identical CPU graph compilation was not repeated. `hn-ca4` was absent at approval.

Package audit `native-classic-active-package-independent-v4.json` SHA `79e2e2d719cb37d963efa71a6c44ad3fa48100881f6e3308ad875810cbd5f7cb` and prelaunch ledger `classic-active-v4-prelaunch-independent.json` SHA `370eca9e54f33d9ef5d19c3cfb0f27e6df103cd68a385d0a75e5d5596085c104` bind the source/evidence checks. **Disposition:** actual package4 approved for a fresh serialized finite experiment. Actual two-window delivery, native reset/restoration, public cleanup and same-backend utility remain required. Previous failed attempts remain preserved.


## CCR-034 — Normal Classic subaperture dropout was treated as a whole-frame initialization fault

**Severity:** High. **Confidence:** High. **Class:** observed payload and source behavior, with a derived mathematical equivalence. **Disposition:** confirmed adapter policy mismatch; primary adjudication and remediation pending independent verification. The original failed acquisition remains failed.

Actual package4 `a0558e98b809ba1e4764e92b8730e5887b61ef3ad7d9935c273933eab97fdfea` reached normal CORRECT and its first exposure. The owner then raised `undeclared invalid active native response` before admitting the command to the simulated plant. Its first-frame exception required an entirely zero vector whenever `result.valid` was false. Classic's raw native slopes have different semantics from Copper's all-zero initialization response.

Independent Python decoding of the original datatype13 payload confirms bucket0/sync1 with182 active-valid subapertures, two eligible state0 subapertures, and four permanently disabled state−1 records. Zero-based subapertures70 and87 have flux947.1875 and989 respectively, below their unchanged threshold1000; their retained slopes are respectively (−0.1270394325,−0.3261882067) and (−0.3588414192,−0.5239369869). All four disabled records have zero slopes/flux. Both the actual native FITS threshold file and captured FGN threshold vector contain1000 for all188 subapertures. The initial disabled-sentinel explanation is therefore refuted.

Unchanged native `source/wfsProc/src/hrtWfsProc.c:383` marks a positive-flux subaperture inactive below its configured threshold after normalization and NCPA subtraction; it deliberately retains the raw slopes. `source/blocks/src/hrtHoReconBlock.c:2504` excludes non-active subapertures from matrix multiplication. Captured FGA `center_of_gravity.jl:118` uses flux>0 and flux≥threshold; `shack_hartmann_image.jl:344` emits positive-zero measurement components for invalid or permanently inactive subapertures, and `shack_hartmann_readout_measurement_block.jl:281` forwards those components to reconstruction. Thus the equivalent normal reconstruction input is:

```text
mᵢ = 1 if the subaperture is permanently eligible and its current state is active;
     0 otherwise.
e = R · diag(repeat(m; inner=2)) · s_raw
u₁ = gain · S · e, with gain = −0.3 and initial controller state zero.
```

The actual first native unclipped VDM matches that independently computed masked prediction to maximum absolute difference6.15046×10⁻⁸µm. Omitting the dynamic mask produces a maximum error0.02585635µm. These are observed reconstruction errors, not new acceptance tolerances. The reviewer initially interpreted the contract's controlled indices as zero-based; inspection established their Julia one-based convention and the independent NumPy calculation now converts them explicitly.

**Remediation basis:** distinguish a classified per-subaperture normal status from a corrupt/incomplete response or a failed calibration exposure. Preserve every raw slope, state and flux. For Classic normal correction, validate the actual sealed threshold and permanent mask, reject any permanent-mask change, invalid state, nonfinite payload or inconsistent state/flux classification, and report dropout counts and locations. Do not substitute zeros in retained native evidence, alter HEART, modify thresholds/brightness/gains, or relax all-active calibration admission. Copper's existing first-only initialization rule is separate. An explicit revised normal policy must be sealed and used consistently by exporter, owner and offline verifier; a fresh run must still pass both complete windows, exact reset, physical projection, public shutdown, detector/direct-truth replay and finite utility versus zero. No instrument dropout tolerance has been supplied, so observed dropout statistics cannot establish such a tolerance.

Independent evidence: `ccr034-independent-decode.py` and `ccr034-independent-decode.json`, report SHA256 `42367bcf457b1037d094604fbf85db353aa098e9c3014a545742d9cff526abd8`. The report binds payloads, thresholds, selected inverse, native/FGA sources and lifecycle. All six distinct recorded supervisor/core/owner/simulator/RTC/native PIDs are absent, and the owned runtime instance is gone. Public shutdown remains false; owned fallback reaped the launcher with exit1. No failed gate was rewritten, no GPU replay was performed, and active Classic scientific utility remains unestablished.


### CCR-034 remediation — frozen source10 independently verified

The primary adopted the explicit post-observation Classic normal-status policy in `CALIBRATION_COMPLETION_PLAN.md`. Frozen source root `native-correction-preparation-source-v10/deployment` has151 entries and exactly9 changed files versus source9; independent rehash matches copy-proof SHA256 `a10eaf47cf8dba114b3ed2941d94fe882c91accbc5767653ad2b221cd8231551`. The four scientific helpers, held-calibration helper, native source and underlying algorithms remain unchanged.

The selected Classic exporter derives a188-element Float32 threshold artifact from the actual native FITS through the existing decoder. Contract fields bind its bytes, the native FITS and the existing runtime input identity. Both package loading and startup validate the relevant identities, including the public runtime symlink's actual target. `Profiles.normal_response` requires eligible state1 exactly when finite flux is positive and at least the sealed1000 threshold; eligible state0 otherwise, and permanent exclusions remain state−1. Nonfinite coordinates/flux and contradictory states fail. The classifier leaves raw slopes unchanged and returns `valid=false` when a dropout occurs. Calibration's all-active validity and Copper's first-only all-zero initialization rule remain separate.

The active Classic caller disables only the shared acquisition helper's whole-frame all-active rejection and immediately applies this stricter classification to the exact associated native bucket/sync before adopting the received command. The journal retains per-frame validity/dropout counts; independent archive reduction recomputes both per-frame and aggregate exposure/subaperture counts, verifies the report and completed-window record, and applies the same policy. Reset clears all new counters and the retained response reference.

Independent old-package reproducer passes6 assertions documenting the same rejection and a fully valid held response. Frozen source10 passes64 independent assertions covering the actual two-dropout payload, held positive control, exact threshold equality and adjacent Float32, zero/negative flux, eligible state−1, disabled reactivation, invalid state codes, nonfinite fields, mask/threshold mutations, threshold native/wire/digest/link checks, and forged aggregate statistics. No first-frame exemption or maximum dropout allowance was introduced. These fixtures retain the actual raw payload and all original input hashes.

The reviewer also decoded both accepted source6 Copper windows through their original and source10 phase/classifier/ADC functions:1554 assertions pass, all30 phase-file identities match, all512 native gradient payloads and classifications agree, and both windows retain exactly one initialization-invalid response plus two rail pixels in two frames. Source10's new diagnostics report256 frames and zero Classic-style dropout counts for each Copper window. This is a cold compatibility check, not a reissued source10 scientific report or GPU replay; the original source6 reports remain unchanged. Therefore the earlier accepted Copper experiment remains qualified at its original source identity, while the source10 policy change requires a fresh Classic package and complete live qualification. It does not require relabeling the historical Copper experiment as a full source10 deployment matrix.

Audit: `ccr034-independent-source-v10.json`, SHA256 `78362914982d11c90fbc8a07b896df1a4ab70c4dd054aab4cfda0091373826ab`, binds exact source and independent logs/scripts. Source is approved for fresh same-root managed score and public export. Actual package closure and complete Classic correction remain open; all failed package4 flags remain false.

### CCR-006 matched private-core discriminator follow-up

The primary subsequently ran a deliberately matched baseline/candidate pair. Independent cold rehash verifies all309 inputs in `ccr006-privatecore-paired-audit-v1.json` (SHA256 `b113dc298d71600e8c7f96f5d09a81f6a99df71aff310d1ff2463a4e3ece053f`). Baseline `3c846025113eacb851b437c585c63f15bc057136` and opt-in candidate `aa50935` use byte-identical shared test, Project/Manifest, Julia1.12.7/thread1, CPU11 and environment. Recorded preparation/dependency/prefix inputs remain unchanged, and41 common post-run Julia-loaded libraries match; only the selected PipeWireAO compiled module differs. Child-daemon loaded mappings were not captured, so its prefix is described as selected input rather than a measured mapping.

Both runs report7 passes, zero assertion failures and one source-completion deadline error at unchanged test line142; the loan-count≥2 assertion passes in both. This demonstrates the timeout on the exact API parent as well as the candidate under the controlled setup. It does not identify the timeout cause, clear the generic private-core test, or prove absence of every possible regression. Selected native held/active association retains its separate actual qualification. No additional live/private-core processes were launched by the reviewer.


### Fresh Classic package5 prelaunch verification

Actual package `heart-native-classic-correction-prepared-v5` descriptor SHA256 `dbc593bd690bdf3d4da8c1f19ddf160b40a911a3fcb07eb2ab7373c1cfe5fc71` passes independent528-artifact identity/exact-inventory verification. Its745 cold-admission inputs rehash correctly. Managed score5 `1f51e4914936491a61f950815037d5911b9ca1e31b2e94de4179a2167d29363a` has exactly the prior scientific fields; its744 input differences are source-root relocation and the approved Classic exporter threshold-binding source identity. Matrix, controller coefficients, native configuration/binary, plant, existing calibration files and dependencies remain exact package4 bytes. The only new scientific-data representation is the188-element Float32 copy of the already configured native threshold1000, bound to both the native FITS and runtime input digest.

The actual package's public HeartOwner runtime preparation creates its real config symlinks without launching a child. Full packaged owner loading and startup proof pass14 independent assertions, including threshold-link correctness, changed native threshold target rejection, restored target acceptance, exact E and altered E rejection. The exact actual payload/threshold/aggregate mutation suite passes64 assertions using the packaged helper itself. Earlier CPU boundary/recorder/truth/reset verification composes because those source and scientific inputs remain unchanged; these cold checks do not simulate a successful native window.

Package audit SHA256 is `fbbdf923e3ec14d5898af3eb08da518e95d38d828b2b158e2c894e41e1c1a2bf`; final prelaunch ledger is `classic-active-v5-prelaunch-independent.json` with SHA256 `7d8bbfece8ad5492916c864406f486754c9e55346efcdbd8f8ce0e22ec1dffa6`. A reviewer-only reporting typo initially referenced the not-yet-created v5 audit as its previous audit; the preserved failure occurred after all package invariant checks. The retry references the existing v4 audit and passes. No production source or original evidence changed. Package5 is approved for the primary's fresh scoped run; actual two-window correction, reset, public shutdown and replay utility remain required.


## Final independent acceptance — native Classic source10, 2026-10-04

Actual `native-classic-correction-active-v5-evidence.lifecycle.json` SHA256 `334d893155e4442b4e638ea13efb1735c59b1b8812e95f4b840c88367a32fe39` records the primary's successful package5 run. Independent inspection confirms both batches, stop/reset/start, public shutdown and both replays. Final actual state is stopped, unadmitted and error-free; the owned instance is absent. All seven distinct recorded supervisor/core/owner/simulator/RTC/native-generation PIDs are absent. The second native PID differs from the first, generation advances 1→2, and the reset-held state has zero admitted frames before restart.

Both windows retain all 15 phase files and exactly 256 raw detector, 256 calibrated detector, 256 gradient, 256 VDM and 258 DM records. Startup is physical zero at bucket 0/sync 0; restoration is physical zero at bucket 257/sync 256. The original packet/counter/phase/ACK/projection guards pass the actual packaged cold verifier (36 grouped assertions plus one exact-truth assertion). No record is omitted or replaced. Raw ADC, relayed metre commands and direct-truth records reproduce exactly between reset windows.

Independent decoding of all 512 datatype13 records verifies every permanently disabled state−1, eligible state0/1 classification against the sealed 1000 threshold, finite raw values and unchanged 188-element mask. Each window has 236 frames with at least one dropout and 544 total subaperture events. Affected zero-based indices and counts are 69:77,70:62,84:70,87:48,100:74,103:66,117:70 and118:77. Raw slopes remain retained, including finite nonzero slopes excluded by native reconstruction. Both reports retain 236 invalid-whole-frame diagnostics rather than relabeling those frames fully valid. Raw ADC maximum 449 is below the 12-bit rail 4095, with no rail pixels.

Independent Float64 evaluation of the preserved gain −0.3/pole 0.99 recurrence on the actual dynamically masked measurements agrees with native VDM to maximum absolute difference 6.15046×10⁻⁸µm; actual native E projection differs by at most 2.46248×10⁻⁷µm. These quantify observed arithmetic differences and are not newly selected acceptance thresholds. Relayed Float32 metre commands equal the native physical micrometre records converted through the declared units. There are no limited DM components; maximum absolute command is 0.3789594µm OPD.

Both producer GPU analyses bind the actual package, unchanged scientific helpers, original report and exact replayed ADC bytes. Independent cold inspection verifies all per-frame ADC hashes, direct atmosphere/pupil/surface hashes and variances, zero-command atmospheric identities, sequence/model timestamps and zero-surface checks. Recomputing the declared variance ratios from retained direct truth gives:

| Reset batch | Frames 17–128 | Frames 129–256 |
| --- | ---: | ---: |
| 1 | 0.04428151441912413 | 0.0344010801505375 |
| 2 | 0.04428151441912413 | 0.0344010801505375 |

Each is finite and below the predeclared zero-command baseline. Analysis SHA256 values are `565e6680f691f0db805f1d33aa80dc1ae77468ea85768149d70a37e75f49ea60` and `eab83f9ff7e17c61de102425b559ecb8f7f94f4d29d4d7476bbb7e430a96da77`. Final independent audit `native-classic-windows-independent-v5.json` has SHA256 `2550220c39a78c08b5f9953eef459068f523fe80ddce367d519997530c56a094`; it rehashes 1,573 exact package/source/payload/lifecycle/replay inputs. Its script `review_native_classic_windows_v5.py` performs no GPU or native execution. The Julia verifier likewise reads retained evidence only.

**Acceptance:** the fresh source10 Classic experiment closes CCR-034's selected operational gate and completes the fifth selected finite simulation study step together with the earlier independently reviewed cohorts. The normal per-subaperture policy was explicitly adjudicated after the failed package4 result; no retrospective pass or unchanged-policy claim is made. Counts from this corpus establish no instrument dropout tolerance. Original failures, generic CCR-006 timeout and ordinary Copper streaming CCR-017 remain visible in their separate scopes.

## Final scope reconciliation

| Study step | Accepted evidence scope | Limit preserved |
| --- | --- | --- |
| Illumination and probes | Retained Classic characterization and Copper matching-reference10×/100× screens; actual ADC and response checks | Provisional simulator detector model; no physical detector threshold |
| Repeated matrices | Selected Classic evidence; paired FGN/JFG Copper matrices and separate native Copper full training cohorts | Exact copied source/recipe identities; no population estimate |
| Method comparison | Zonal/Hadamard fitted inverses and held-out validation/locked selection; spatial forward comparison | Spatial results only in measured span; energy/exposure costs retained |
| Physical/controller composition and correction | Actual maps, null coordinates and signs; selected finite FGN/JFG and native correction/reset/replay | No new gains or full configuration Cartesian coverage |
| Unchanged HEART and available accelerators | Selected native Copper deferred fixture and Classic streaming fixture; retained CUDA/AMDGPU simulator cohorts | No ordinary Copper streaming clearance, hardware cadence, GPU RTC graph or instrument acceptance |

The final source10 software suite and installed package closure are complementary verification, not substitutes for these experiments. Historical native Copper remains bound to its accepted source6 package; final native Classic is source10. The broader physical and real-time scope of RTC-DEV-029 is not declared complete by this selected study.
