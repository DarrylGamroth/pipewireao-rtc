# Copper operational precision and amplitude pilot

## Baseline and scope

This increment starts from clean RTC `5565d6e` in the dedicated
`work/copper-calibration-quality-20261003` worktree. It extends the completed
Copper dark/reference candidate workflow under RTC-ARCH-023 / RTC-DEV-029.
FGN and JFG execute their ordinary complete-frame CPU WFS and physical-command
paths. HEART, accelerator backends, physical devices and cadence qualification
remain subsequent validation targets.

The previous independently seeded eight-exposure lamp mean differed from its
frozen reference by a relative norm of 0.0888074. That is a descriptive residual,
not a scientific acceptance failure against an instrument tolerance. This pilot
will measure response size and repeated-batch disagreement before investing in
an entire 277-direction interaction matrix.

## Predeclared acquisition

Use the existing measured background and frozen normalized reference candidates,
with their successful producer reports and hashes. Keep all other science-base
maps, detector settings, registration and provisional influence model. The reference
is diagnostic only; do not introduce reference subtraction into either graph.

| Setting | Declared value |
| --- | --- |
| Physical direction | One-based HSDM277 command 139; provisional geometric center (x = 0, y = 0) |
| Reference | All 277 absolute commands zero, in µm OPD |
| Signed poke amplitudes | Float32 representations of 0.02, 0.04 and 0.08 µm OPD |
| Samples per held figure | 8 completed exposures |
| Repetitions | 2 balanced traversals |
| Null batches | Start and end of each traversal: 4 batches |
| Detector seed | 444 in both engines |
| Lamp magnitude | 5.752574989159953, unchanged from reference acquisition |
| Settling | Discard one completed exposure after every adoption |
| Detector | Existing 64×64 noisy, 14-bit provisional fixture; rail 16383 |
| Operation deadline | 30 seconds |
| Whole-stage deadline | 900 seconds |

Traversal 1: null, +0.02, −0.02, +0.04, −0.04, +0.08, −0.08, null.
Traversal 2: null, −0.08, +0.08, −0.04, +0.04, −0.02, +0.02, null.
This is 16 batches and 128 retained exposures, plus 16 discarded normalization
exposures and one restoration exposure. Startup exposures are separate.
No new flux or gain is selected from the resulting pilot.

One discarded completed frame primes the deployed previous-frame normalizer after
a command change when its numerical processing succeeds. The existing settling
receipt does not expose discarded-frame validity or intensity; retain first-versus-later
sample and intensity diagnostics. This is not a measurement of physical DM or
detector settling. Reversing
amplitude traversal and sign order together does not identify time, amplitude,
normalization-history and order effects independently.

## Operational association and failure policy

Use one serialized public calibration connection per engine, with monotonically
increasing probe IDs and request serials. Hold, adopt each absolute physical
figure through the normal constrained output path, reject any clipping or changed
figure, settle using completion events, then capture the declared finite batch.
Preserve the original reference separately and restore it before release and
public shutdown. Unknown-effect failures keep the existing fault/hold policy;
never retry an uncorrelated effect.

Verify every manifest against its declared probe, request serial, startup settings,
full acquisition-domain mapping, generation, chronological exposure interval,
shape, layout, length and SHA256. Reject invalid lamp responses, nonpositive
current intensity, nonfinite data or any ADC value at or above the rail.
Freeze recipe, deterministic schedule, source/base/package identities, binaries,
AOC numerical sources, producing reference reports and candidate bytes before
acquisition. Check frozen identities after capture and after analysis. Use fresh
output/runtime directories; preserve failed runs.

Live deployments use the configured core placement with inherited affinity
admitting CPUs 2–15. CPU 0 and CPU 1 are excluded. Serialize FGN and JFG windows;
do not modify kernel policy or existing operator services.

## Reduction and interpretation

The measurement is the 3,600 normalized absolute four-pupil pixels in pupil-block
wire order. Mean intensity is a separate diagnostic. Use public AOC
`Diagnostics.RepeatedResponseMoments` to reduce each held batch. Use the public
zonal push/pull estimator to form the one-column derivative from paired means,
with the actually represented command interval in µm OPD.

Publish batch means and descriptive N−1 variances, null-batch mean differences
and frozen-reference residuals, per-amplitude derivative norm, repeated derivative
cosine and relative discrepancy, and derivative changes relative to the smallest
amplitude. Compare signed-pair midpoints with their bracketing null means without
applying a drift correction. Preserve numerical artifacts so an independent reduction can check
all metrics and array ordering. Compare actual FGN/JFG ADC and response bytes
before attributing algorithm differences.

Adjacent frames can correlate through previous-frame normalization. Two sign-balanced
traversals are only two repeated estimates. Report repeat/order discrepancies;
do not infer confidence intervals, independent-sample standard errors, pure-noise
bounds or causal linearity from this pilot. No instrument acceptance tolerance is
invented. This pilot cannot qualify all physical or controller directions.

Record total cold workflow, startup, aggregate held-probe acquisition and storage,
cold analysis and shutdown time separately from model exposure duration. Per-operation
wall costs are not isolated by the existing receipt interface. These are calibration costs, not a
maximum simulation or RTC frame-rate benchmark.

## Next decision

Use these results to choose the cheapest additional discriminator: longer batches,
more separately seeded repetitions, a predeclared flux screen, separated order
comparisons or more physical directions. A full physical matrix, composition into
253 Copper controller coordinates, held-out inverse selection and deployed
correction each require their own measured evidence. Keep those gates open.
