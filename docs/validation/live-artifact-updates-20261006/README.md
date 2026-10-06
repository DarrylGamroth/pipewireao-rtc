# Live artifact update checks

Date: 2026-10-06. RTC starting revision `8a5e3bf`; worktree
`/tmp/rtc-live-artifact-updates-20261006`, branch
`work/live-artifact-updates-20261006`. The starting worktree was clean.
The selected work is artifact loading, native controls and frame-boundary
adoption; completed calibration campaigns are reused within their own scope.

## Observed CPU allocation and numerical results

Both probes use Julia 1.12.7, CPU15, one Julia/BLAS thread, GC enabled,
offline dependencies and existing compiled modules. Their package environment
is `/tmp/copper-jfg-main-noobs-v2-installed/jfg/deployment`.
The installed scientific/executor source hashes agree with JFG main
`b60911697c9439f83897d79492e93a5324edb05a` for the measured paths.
Exact package versions and source hashes are in the logs.

After 32 warming sequences, each allocation measurement has 64 samples through
a concrete function barrier. Numerical assertions are outside the allocation
measurement. No production source was changed.

| Probe | Warmed adoption | Adoption plus graph processing | Control preparation |
| --- | ---: | ---: | ---: |
| ClosedLoopCorrectionF32 scalar gain | 0 B | 0 B | 2,144 B/update |
| ClosedLoopCorrectionF32 projection parameter | 0 B | 0 B | 1,712 B/update |
| Heterogeneous graph scalar gain | 0 B | 0 B | Measured separately in the log |
| Copper PyramidPupilReconstructorF32 matrix | 0 B | 0 B | 3,644,376 B/update |

Both admitted and checked public graph processing also measure 0 B after
warmup. The small controller probe checks 385 recurrence/output cases, and
the heterogeneous graph checks 128 output cases.

The Copper probe uses the actual row-major F32 calibration matrix, shape
253 × 3,600, SHA256
`8cfeba562c55ff99de362e77d5046cbb1d4011c21bce334b93ab50912596c043`.
Its one-node graph uses four pupils with 900 selected pixels per pupil and
253 controller residual coordinates. Same-shape matrices alternate between
scales 1 and 0.99. All 290 output comparisons with an independent Float64
scalar calculation pass; maximum absolute error is approximately 6.15e-5
within the probe's declared relative bound. Output norms change from 506.77902
to 501.71118, so this is not a comparison of identical or clipped outputs.

Reproduce against the retained installed package:

```sh
taskset -c 15 env JULIA_PKG_OFFLINE=true JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  julia --compiled-modules=existing \
  --project=/tmp/copper-jfg-main-noobs-v2-installed/jfg/deployment \
  docs/validation/live-artifact-updates-20261006/copper-reconstructor-probe.jl
```

The [controller probe](control-adoption-probe.jl) and
[log](control-adoption-probe.log), and the
[Copper matrix probe](copper-reconstructor-probe.jl) and
[log](copper-reconstructor-probe.log), retain the exact calls and checks.
The controller probe additionally needs the JFG test fixtures at its recorded
canonical repository path. These are investigative probes, not deployed tools.

## Limits and remaining live check

An existing GUI native client was also tried against the recorded installed
Copper FGN fixture `/tmp/gui-recorded-duplicate-peer-v1-installed`, using its
actual `control:gain` property. Initial live properties and requested/active
generation queries pass. The rejected-command loop then fails because the
client expects a session identity that is absent from a reply; it stops before
the accepted gain and reconstructor updates. This is a preserved failed smoke
check, not an adoption pass or a confirmed executor defect. Frozen client and
fixture compatibility must be checked before changing production source.
The [receipt](native-control-smoke.json) and
[client trace](native-control-smoke-failed.log) retain the observation.

These results cover the real CPU algorithms and executor adoption calls in
minimal graphs. They do not cover the full Copper pipeline, native callback
ingress, concurrent publishers, first-use compilation or live timing/loss.
Preparation allocates outside adoption. Because preparation and processing
can share a Julia process, a zero-allocation processing call alone does not
exclude a GC pause caused by control preparation.

Interaction-matrix acquisition and reconstructor construction remain cold
calibration work. This runtime matrix check changes the resulting reconstructor
parameter; it does not imply that the graph consumes an interaction matrix.
The next discriminating check is a live same-shape reconstructor and gain
update with sequence, generation, output, timing and GC observations, compared
with its unchanged baseline. No loss-free rate or deadline claim follows from
these probes.
