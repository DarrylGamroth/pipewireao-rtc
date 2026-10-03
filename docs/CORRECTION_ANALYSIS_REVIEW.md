# Cold correction replay review

Independent scientific and software review, 2026-10-03. This is diagnostic
evidence under [RTC-DEV-029](operations.md#rtc-dev-029--operational-interaction-calibration),
not a calibration method, matrix acceptance or new operating requirement.

Reviewed files: `deployment/hil/analyze_correction.jl` and
`deployment/hil/test_analyze_correction.jl`, in worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-calibration-quality`,
branch `work/classic-calibration-quality-20261003`, HEAD
`3624d258505003ab2776deac9c3232c759af9b64`. Existing changes in other files
were preserved. The reviewer changed this document only.

Initial frozen source identities (before CORR-R1 remediation):

- Analyzer SHA-256: `15aed90ba97494b794835796d0c76c0b5fe1ef60617a7f38670d72d44639edf7`.
- Tests SHA-256: `29771909d9cd5ab11f54961b9ff827a3c77f2b04cc852ac763584aca63bfe352`.

## CORR-R1 — Symlinked output parent bypasses package ownership guard

- Severity: low. Confidence: confirmed by isolated execution.
- Location: `analyze_correction.jl:331`–`334`, followed by failure-report
  publication at lines 344–349.
- Disposition: corrected and independently verified. Original evidence below
  is retained; the verification update records the final implementation.

The package path is canonicalized with `realpath`, but the output is checked
only with lexical `abspath` and a string prefix. A sibling symlink whose target
is the package bypasses the stated requirement that diagnostic output remain
outside the installed package. Even package-validation failure then writes a
new diagnostic JSON inside that package through the alias. This is an observed
unexpected new-file mutation; no overwrite of existing source was demonstrated.

Reproduction uses only a temporary empty package directory and a sibling
symlink, with no plant preparation or RTC launch:

```julia
mktempdir() do root
    package = joinpath(root, "package")
    mkdir(package)
    alias = joinpath(root, "package-alias")
    symlink(package, alias)
    output = joinpath(alias, "diagnostic.json")
    status = CorrectionAnalysis.main([
        "--package", package, "--report", joinpath(root, "missing.json"),
        "--output", output])
    # Observed: status == 1, but isfile(joinpath(package,"diagnostic.json")) == true.
end
```

Minimal remedy: resolve existing parent-directory symlinks before any output
directory, raw replay or JSON write, and reject a destination canonically
inside the package. Preserve support for new output directories outside the
package. Add tests for a direct alias and a new subdirectory beneath an alias;
also retain the ordinary external-output success/failure evidence tests.

Saved assertion-based reproduction:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/corr-r1.jl`.
Fail-before log: `corr-r1-before.log` in that directory, exit 1: expected an
`ArgumentError`, but no exception was thrown. A separate isolated run directly
observed the file created inside the temporary package.

## Scientific and interface assessment

The command chronology matches the maintained simulator and public HIL
boundary: frame 1 uses the zero initial command; command n is copied into the
public command buffer after frame n and adopted for frame n+1. Recorded
commands are already metre OPD. The analyzer does not rescale them before
adoption, and the final command's optical effect is explicitly not recorded.
Conversion back to micrometres is limited to a rail-proximity diagnostic.
That count is explicitly distinguished from requested-minus-demanded clipping
feedback.

Source inspection verified the public `prepare_science`,
`step_hil_frame_at!`, `adopt_hil_command!`, `reset_hil_boundary!`,
`graph_output`, `TelescopeDefinition`, `prepare_telescope` and `pupil_mask`
interfaces. Preparation warms and resets the model just as the installed
source owner does. Reset restores the snapshotted zero command and resets the
model-time driver. The actual reset reproducibility remains an integration
obligation below.

The metric is the population spatial variance of metre OPD after removing
piston over the public annular pupil support. Fixed-origin Float64 arithmetic
preserves represented differences at a large common offset. It divides by
the pupil sample count, not the whole square image or N−1. There is no extra
mirror-reflection factor or wavelength conversion. The public residual output
already carries the plant composition. Mean window variances are reported as
a ratio of means, with an explicit frame-17 warmup exclusion for longer runs.
Short/incomplete windows retain their declared ranges and completion labels.

Every ADC payload must match the retained source bytes exactly. The second,
zero-command replay checks elementwise atmosphere agreement, pupil equality to
atmosphere and a zero PDM surface. Ratios are withheld unless all ADC and
baseline checks pass. A zero atmosphere denominator produces no ratio. The
zero-comparison tolerance is retained explicitly; exact atmosphere hashes are
reported separately from tolerance-based agreement.

Current installed artifact hashes and active-project identity are checked.
The report clearly limits this claim: the original simulator format binds
graph and payload hashes, not historical helper-source identities. Matching
current files does not retroactively establish acquisition-time source hashes.
Exact replay checks source payloads; it does not independently prove sink
receipt. Ideal optical arrays remain diagnostic outputs and are not supplied
to calibration or reconstruction.

## Verification and remaining integration evidence

The final frozen pure test suite was independently run with Julia 1.12.7,
`--startup-file=no --check-bounds=yes`, CPU affinity `6,14`, and one OpenBLAS
thread, using the existing analysis environment. **93/93 assertions passed
across five test sets**, exit 0. Log:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/independent-frozen-tests.log`.
Earlier runs overlapped implementer edits; their intermediate test failure is
not used as evidence against the frozen source.

The pure tests cover variance/units, ADC encoding and row order, window
selection and ratio withholding, recording/artifact rejection, and failure
report behavior. They do not invoke the actual `replay` path. Before promoting
a correction ratio, run the analyzer against the exact installed Classic CPU
package and an authorized retained source recording and record:

1. Exact ADC equality for every replayed frame and correct model chronology.
2. Successful reset, same-atmosphere comparison, pupil-equals-atmosphere and
   zero-surface checks over every baseline frame.
3. Final analyzer/package/report identities, selected windows and limitations.

Additional focused coverage would be useful for mismatch propagation through
the complete replay result: an altered ADC sample with a matching descriptor
hash must suppress every ratio. A small deterministic replay stub can exercise
this without repeating a full plant run. Current source implements this guard;
the existing pure tests exercise its constituent comparison and window logic.

No plant or RTC was launched during this review. Actual plant integration is
pending; pure tests cannot establish it. No other confirmed numerical or
public-interface defect was found. This review does not qualify a controller,
matrix, physical instrument, wall cadence or license.

## CORR-R1 verification update

**Corrected and independently verified, 2026-10-03.**
`diagnostic_output` now resolves the nearest existing output parent with
`realpath`, retains any new directory components, and checks the resulting
destination against the canonical package directory before creating anything.
Both `main` and the callable `analyze` entry point assign and use that resolved
destination. The raw replay file, failure report and temporary/final JSON
publication therefore use the checked path. Existing and dangling report/raw
links are rejected as occupied; a dangling parent link also rejects. An alias
to an ordinary external output directory remains supported.

The exact saved reviewer reproduction `corr-r1.jl` was rerun independently
with bounds checking on CPUs 6 and 14: **exit 0**, both assertions passed.
It now throws before writing a diagnostic inside the temporary package.
Pass-after log:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/corr-r1-independent-after.log`.
The original `corr-r1-before.log` remains fail-before evidence.

The worker's full pure-test log was independently inspected:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/focused-corr-r1-after.log`,
SHA-256 `275cb23bdaf593deb1b4f3edccc77ce5ec63b2db44e2540b56924965ddfacc1e`.
It records **109/109 assertions in six test sets**, including 16 new ownership
assertions for direct/nested package aliases, an allowed outside alias, and
dangling report/raw/parent links. This full result is log-inspected; the exact
saved regression was independently executed as stated above.

Final independently inspected source identities:

- Analyzer SHA-256: `fca5a9f9c2a26dad6c3c2bf610d3ae69ff1538816db751405eb594da8fd4a990`.
- Tests SHA-256: `bd14134516b1996181b55da3e09555ccdfcb11e6d752316490d43d50daa3bffd`.

CORR-R1 is closed. No remaining confirmed software blocker was found in this
remediation. Actual installed-plant ADC replay and reset/baseline verification
remain pending and must precede any promoted correction ratio.

## Cold loader integration findings

The first actual FGN replay attempts exposed two integration defects after the
pure numerical checks had passed. The primary agent reported the actual-run
failures; the reviewer inspected the corresponding isolated fail-before logs,
the fixes, and independently ran the expanded pure suite. These findings
supersede the earlier statement that no other confirmed software defect was
known at that stage of the review.

### CORR-R2 — Isolated installed module lacked an include binding

- Severity: medium. Confidence: confirmed by source and inspected reproduction.
- Affected boundary: loading `hil/simulator.jl` into
  `Module(:InstalledCorrectionSimulator)`.
- Observed failure: `UndefVarError: include not defined` when the installed
  script includes `owner_protocol.jl`. A dynamically constructed module lacks
  the ordinary module-local forwarding binding.
- Remedy reviewed: `load_installed_simulator` defines local
  `include(path) = Base.include(@__MODULE__, path)`, then includes the exact
  installed script. The script's existing PROGRAM_FILE guard remains intact.
- Verification: the regression follows two nested relative includes while
  running from another working directory, verifies module isolation, and
  confirms the source owner's `main` is not invoked. It passed in the
  independently executed final pure suite and the actual FGN replay below.
- Disposition: corrected; closed.

Fail-before log:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/include-fail-before.log`,
SHA-256 `17b29db9008f92a8de439c5d541ccb26fba85838bdf61ea815f6de6272f1211f`.

### CORR-R3 — Cold lazy plant import was newer than preparation's world

- Severity: medium. Confidence: confirmed by source and inspected reproduction.
- Affected boundary: the call from `replay` to installed `prepare_science`.
- Observed failure: after the installed `load_plant` lazily imports the plant,
  its `graph_path(::Symbol)` method exists but is too new for the direct
  preparation call. The enclosing invocation entered its world before that
  lazy import.
- Remedy reviewed: evaluate the installed plant/target loaders, then invoke
  installed `prepare_science` through `Base.invokelatest`. The numerical
  implementation, graph definition and command adoption remain unchanged.
- Verification: an isolated cold loader creates a new module/method during
  import and successfully prepares in the latest world. The final pure suite
  passed with `--depwarn=error`; actual FGN preparation and replay completed.
- Disposition: corrected; closed.

Fail-before log:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/lazy-import-fail-before.log`,
SHA-256 `8f3087a1796b0634fc67336cce0e1218e4d5e3b99525da1b9fcf52d1c8d009da`.

Latest frozen identities, independently checked:

- Analyzer: `86bd96852483dae95f24a10a1e39d12ebb0142eb022161c39738a4ec33eaa5f0`.
- Tests: `4721e2c17a7737d8fb8e7479a00f48b1e0dc9bbbe6d85f92d930f5a4caff50d1`.

The reviewer independently executed **114/114 assertions in eight test sets**,
exit 0, on CPUs 6 and 14 with bounds checking and `--depwarn=error`. Log:
`~/.cache/rtc-calibration-quality-20261003/correction-analysis/independent-loader-tests.log`.
No warnings were present. The worker's matching result was also inspected in
`focused-lazy-import-pass.log`, SHA-256
`a718037805461bea43385b9fa830606a2f33a0d8e9970cec32a514a6d8ee9f1d`.

## Actual FGN replay evidence

The primary agent ran the actual cold Classic CPU FGN replay; the reviewer
did not execute a concurrent graph. The resulting artifact was independently
inspected at
`~/.cache/rtc-calibration-quality-20261003/correction/fgn-correction-analysis-v3.json`,
SHA-256 `f571a3185b46c652fbd38c62b789ead52caab2d134bbdd9e9103dd164cf576cf`.
The primary agent reported exit 0. Observed artifact checks:

- `verified=true`, no failure, all 256 ADC frames exact, zero differing frames
  and pixels. The aggregate replay ADC SHA-256 equals the retained source
  payload hash: `ab8220cf65a33b1e8479dce7d7f36f79ba5d9e834c679aa0c678b00f22b1154a`.
- All 256 zero-command baseline entries pass atmosphere/pupil/zero-surface
  checks. Atmosphere hashes are also exactly equal for every frame, exceeding
  the stated tolerance-based comparison.
- All 385 declared installed artifacts match their manifest hashes. The
  recorded deployment, simulator, Project, Manifest, model, source report,
  retained ADC and retained command hashes independently match current files.
- The source report SHA-256 is
  `75ffeb62c88747e8c0d9ca28651a3e2ac6c16fc919e37ddd8dc23fbea8fc8c88`.
- Independently recomputed ratios from per-frame variances match the recorded
  window summaries below. Every per-frame ratio is finite.

| Fixed window | Frames | Residual/atmosphere variance ratio |
| --- | --- | --- |
| 17–128 | 112 | 0.04026607946545251 |
| 129–256 | 128 | 0.06010991499121354 |

The artifact records 70,912 nonzero command components, zero components at the
reported rail threshold, and peak absolute command 0.40172863 micrometre OPD.
These are command-content/rail-proximity diagnostics, not clipping-feedback
measurements. The final command's optical effect lies beyond the recording.

This satisfies the ADC replay and reset/baseline integration gates for this
finite FGN corpus and supports residual-variance reduction on its fixed
windows. It does not establish general controller acceptance, independent
experimental repeats, wall rate, physical performance or historical helper
source identity. JFG actual replay remains pending at this update. No remaining
confirmed defect was found in the latest loader remediation; CORR-R1, CORR-R2
and CORR-R3 are closed.

## CORR-V1 — JFG cold replay does not reproduce the recorded ADC corpus

**Class:** required experimental validation, unresolved cause; not a confirmed
analyzer defect. **Confidence:** high in the mismatch and gate behavior; no
confirmed root cause. **Disposition:** open for JFG correction demonstration.

The two retained attempts under the correction cache are:

| Artifact | SHA-256 | ADC mismatch |
| --- | --- | --- |
| `jfg-correction-analysis.json` | `ab251aff9034336f07189b5454ee211f3c051176fb2bdf9ef33e267831ae59dc` | 12 frames, 33 pixels; maximum 5 ADC codes |
| `jfg-correction-analysis-cpu6.json` | `23cdba023bc94bd0755633460668e90b8c43e27f9697ecd484c6a4fa54b5917d` | 7 frames, 66 pixels; maximum 8 ADC codes |

Observed by independent artifact inspection: both report `verified=false`,
`baseline_verified=true`, and null ratios for every frame and both fixed
windows. Their mismatch sets differ. The first attempt differs at frames
20, 51, 73, 75, 97, 104, 106, 159, 170, 175, 204 and 248; the CPU 6 attempt
differs at 104, 127, 159, 186, 215, 216 and 253. The strict ADC gate therefore
works as designed and must remain unchanged.

For all 256 frames, the atmosphere, pupil and PDM surface SHA-256 values are
identical between these two cold replays. This localizes the difference
*between those replay processes* downstream of their public OPD outputs. It
does not establish equality with the live acquisition's unrecorded OPD truth.
All 515 installed manifest artifact hashes independently match. The simulator
owner configuration requests `--startup-file=no --threads=1,0`, the installed
`hil` project, `OPENBLAS_NUM_THREADS=1`, and `JULIA_NUM_THREADS=1,0`; its placement
allows CPUs 6 and 14 with leader CPU 6. The parent reports the second cold run
used CPU 6 with the same thread settings. Matching a leader CPU is not evidence
that every native helper thread had identical runtime placement.

Source inspection confirms that live recording copies the adopted command
buffer in metre OPD after each completed exchange, and cold replay copies those
Float32 values without a second conversion after frame n. The same public
preparation helper warms then resets the model. No chronology or command-unit
defect is established by the observed sparse ADC differences.

Installed AdaptiveOpticsSim CPU FFT preparation delegates to public
`plan_fft!`/`plan_bfft!` without explicitly retained plan identity. Process
alignment, FFT implementation choice, other WFS arithmetic, and detector random
sampling remain hypotheses. The current evidence does not identify which
mechanism applies; changing numerical tolerances or repeatedly retrying until
one run matches would not establish the cause.

The cheapest additional localization experiment is to retain the existing
public `shwfs_photon_rate` output hashes/arrays in two otherwise identical cold
replays alongside the already matching OPD hashes. Different photon rates
would localize the discrepancy to WFS formation; equal rates with different
ADC outputs would localize it to detector acquisition/state. Preserve both
outcomes and process settings.

A direct correction witness can instead be acquired in a fresh live run by
retaining the public atmosphere, pupil and PDM outputs with each recorded ADC
frame, timestamp and adopted command, followed by a same-process reset with
zero commands at the same model timestamps. That witness must bind its source,
payloads and public pupil mask, retain the fixed windows, and establish the
zero-PDM/atmosphere baseline before reporting ratios. It remains diagnostic
simulation evidence and must never feed calibration inputs. It does not
retroactively turn either failed cold replay into a verified result.

## Shared recorded-input command comparison

The independent review inspected the cache-only
`verify-correction-array.jl` script (SHA-256
`cb6f586eb9b15ed13254bf898b9b141dccdf4d93caf750f0f75122547794513c`)
and `correction/shared-input-array-v2/array-comparison.json` (SHA-256
`625f35664acb6b3f1c9f1c515076df53cc840d6945947108a0f8ec1d169f0ff7`).
The script admits the installed manifests, original FGN recorded ADC/command
payloads, exact shared startup parameters and graph coefficients. Its diagnostic
graph adds ordinary requested-command and physical-feedback outputs. It uses
public JFG graph preparation, parameter replacement, reset and complete-frame
processing. Row-major ADC decoding is explicit. Controller feedback is zero
initially and advances only after each successful complete frame. Demanded
Float32 micrometre OPD is multiplied by the same Float32 `1.0f-6` conversion as
the adopted source command representation.

The preserved construction-normalization records describe absent/null defaults
and startup replacements; they are not numerical tolerances. In particular,
the inspected public Shack-Hartmann threshold replacement replaces both full
per-ROI pixel and flux threshold vectors before processing, supporting the
recorded scalar-construction threshold difference. The script retains exact
parameter bytes and bindings, ROI/active geometry checks, other construction
fields and graph links.

Independent Python computation from the two retained Float32 command binaries
confirms all 70,912 comparisons are finite, with maximum absolute difference
1.4210854715202004 × 10⁻¹³ metre OPD, RMS difference
2.741418013584737 × 10⁻¹⁴ metre OPD, and 62,197 nonidentical components. The script,
prediction and source-command hashes and all parameter-payload hashes match
the result metadata. All 256 reported requested-minus-demanded norms,
physical-feedback norms, controller-feedback norms, nonzero controller-feedback
counts, demanded-rail counts and requested-outside-rail counts are zero.
These feedback figures are observed result fields supported by the reviewed
calculation; feedback arrays are not separately retained for independent
recomputation.

This is finite-corpus numerical characterization with shared recorded inputs.
It establishes neither bitwise controller equality nor a new acceptance
tolerance, and does not independently qualify transport, cadence or correction
on a new live trajectory.

## Direct live OPD witness design review

The optional `correction_truth.jl` design records three public Float32 OPD
hashes, two piston-removed Float64 variances, sequence and model timestamp for
each completed source frame. It uses the shared public annular-pupil geometry,
row-major little-endian OPD hashing and fixed-origin variance kernels. The
recording follows matching-command adoption and precedes the next model step;
the public outputs still describe the completed frame. The helper bounds its
capacity to 1–256 frames, commits its sample count after successful validation,
and clears its retained prefix on reset. It is opt-in Classic CPU scientific
transport diagnostics. Its allocation and hashing cost preclude interpreting
this run as cadence qualification.

The analyzer validates witness graph, raw-frame, adopted-command, simulator
and helper hashes; declared outputs/units/layout; pupil configuration;
counts/sequences/timestamps; finite nonnegative variances; and hash syntax.
Promotion then requires exact agreement with the live mask hash/support,
all three live OPD hashes and both variances for every frame, as well as the
unchanged zero-command baseline. A present but mismatching witness cannot
fall back to ADC equality. Legacy reports retain their exact ADC gate. ADC
comparison remains independently visible for new witnesses; its unresolved
process reproducibility is not silently reclassified as success.

No critical binding or score-gate defect was found in this source review.
Final guard-test and live-run verification are pending. One low documentation
inconsistency was reported to the primary: the analyzer's older header and
unconditional historical-source sentence still describe only legacy ADC
promotion. They must distinguish the two evidence paths. Simulator/helper
hashes are read when the report is written; source identity assumes the
installed files remain unchanged throughout loading/acquisition, and is not
a general proof against concurrent source replacement.

### Independent witness guard verification

The reviewer reran the focused analyzer suite with `--check-bounds=yes` and
`--depwarn=error` in the existing analysis environment on CPUs 6 and 14. It
completed with exit 0, 159 assertions in nine test sets, and no warnings.
The log is `correction-analysis/independent-witness-tests.log`, SHA-256
`765777a7d8704de0799dd56edde24b0723d6b4bba67d3733b4c31f96c0902dd5`.
The source hashes before and after this run were unchanged:

| Source | SHA-256 |
| --- | --- |
| `analyze_correction.jl` | `0feb752cf074040c294f9ab37232bad8b09e81546704d1968df03944bb5804f8` |
| `test_analyze_correction.jl` | `417fc9b57aad9b87daaba91af7d3e5ea8f76927cd3ab4cccdfa2f1c4ef3454cd` |
| `correction_truth.jl` | `598484d85d05d38cf517ac46a8705aaea79452555aff852b3f6c396140fe9835` |

The 45 new assertions exercise witness admission, malformed source/payload
hashes, chronology, units, shape, pupil declaration, invalid variance and hash
values, exact mask/sample matching, and the complete Boolean gate truth table.
In particular, ADC equality with witness disagreement fails, and a failed
baseline blocks either evidence path. The legacy no-witness path remains
ADC-dependent. No simulator graph, plant or RTC was run by the reviewer.

The score-gate header and returned identity wording now distinguish legacy
reports and witness reports. The final general provenance paragraph in the
header still needs its statement qualified as legacy; this is a documentation
correction only. Actual fresh JFG live-witness verification remains pending.

## Final fresh JFG witness verification

Independent read-only inspection completed for
`correction/jfg-truth-evidence/result.json` (SHA-256
`254223625084090b6fb660eb60ac0d9360c7200e23b373079e7e2f3fade8d8ed`)
and `correction/jfg-live-truth-analysis.json` (SHA-256
`f0ad40a9ac380c33ed1c42299fc22e041ac2f3aa4c281958a03dfad28d984661`).
The acquisition evidence reports success, two completed 256-frame/command
batches separated by reset, and zero exit codes for the core, RTC, Julia graph
owner and simulator. The two batches' retained ADC and adopted-command files
are byte-identical, and their complete direct-witness records are equal.
This is reset repeatability within this run, not independent random realizations.

All 516 artifact hashes in `correction/jfg-truth-hil/deployment.conf` independently
match their installed files. The descriptor hash is
`552634449918f92c5aa9fa773cd1ddf03b5872f01ecf20807288e328b4a2394f`.
Batch 1 report SHA-256 is
`04cef8de7a192d56355d6f0387c0113ac3491d3e6c2e52452ef4a1ba7c7a470b`;
batch 2 report SHA-256 is
`894f84fc48233658fd3a830caf50b2e89fcb639bb88d737be98cc716480d569e`.
The live witness's graph, raw-ADC, adopted-command, simulator and helper hashes
match the report and retained files. The simulator SHA-256 is
`0be5fcef8d4040d0836eb884d90144ac661b9c02cca3d8fb1842a7196da7c2cb`;
the helper remains the independently reviewed
`598484d85d05d38cf517ac46a8705aaea79452555aff852b3f6c396140fe9835`.

The analyzer that produced this result is separately identified as
`0107322ba291c9853d9784a08f11d24d3ad11fe09446ebfb9bf706107760db5e`.
An independent text diff against the installed analyzer
`0feb752cf074040c294f9ab37232bad8b09e81546704d1968df03944bb5804f8`
shows only the qualified legacy-provenance header and added analyzer/helper
hash fields in the result; the mathematics and gates are unchanged from the
159-assertion verification snapshot. This closes the remaining header wording
issue and makes the exported snapshot versus executing analyzer distinction
explicit.

For all 256 samples, the live and cold records agree exactly in sequence,
model timestamp, atmosphere/pupil/PDM-surface hashes and both variances. Their
public mask hash and 43,344-pixel support count agree. All 256 zero-command
baseline entries report exact atmosphere equality, matching pupil/atmosphere
and zero PDM surface. The replayed ADC file also matches the retained source
ADC hash, with zero differing frames/pixels. Thus the result independently
passes both the direct-witness evidence path and, for this fresh corpus, the
exact ADC comparison.

Recomputation from the retained per-frame variances gives:

| Fixed window | Frames | Residual/atmosphere variance ratio |
| --- | --- | --- |
| 17–128 | 112 | 0.04052050968717701 |
| 129–256 | 128 | 0.05995186684865073 |

The second independent sum differs only in its final floating-point digits
(`0.05995186684865071`), consistent with summation order. No new acceptance
tolerance is inferred. The individual variances are supported by exact live
versus replay agreement and the reviewed/tested shared arithmetic; raw OPD
arrays are not retained for a separate variance recomputation from wavefronts.
The report records 70,912 nonzero command components, no components at the
reported rail threshold, and peak command 0.40172854 micrometre OPD. These
remain rail-proximity diagnostics; this live report does not record clipping
feedback. The earlier separate shared-input comparison retains its own direct
feedback measurements and scope.

**Final disposition:** the required fresh JFG finite-corpus correction
demonstration is complete, with live public truth binding and zero-command
baseline verification. CORR-R1, CORR-R2 and CORR-R3 remain closed, and no remaining
confirmed production defect was found in this review. CORR-V1 remains open
only for the cause of the earlier process-dependent ADC discrepancies. The
earlier failed artifacts remain failed; this fresh run does not repair or
promote them. Neither these results nor the FGN/shared-input evidence establish
general matrix/controller acceptance, physical performance, independent
statistical coverage or wall-rate qualification. No plant or RTC was launched
by the independent reviewer.
