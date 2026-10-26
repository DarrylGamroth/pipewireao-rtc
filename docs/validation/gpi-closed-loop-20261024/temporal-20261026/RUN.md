# GPI stage response and temporal allocation — 2026-10-26

Scope: optional, generic stage dynamics and stage/woofer temporal allocation,
with matched private-array validation. The live RTC and GUI remain unchanged.
The accepted woofer command boundary is ±3.4 µm OPD; stage and tweeter boundaries
remain ±1 µm OPD. Hidden removal remains disabled and all original integrator
gains, calibration matrices, optical registration, atmosphere and detector
settings remain fixed. No physical-device or real-time qualification is claimed.

## Predeclared experiment

A common 2,000 Hz model command cadence is retained. The controller uses the
existing first-order per-axis low-pass stage filter, with 25 Hz cutoff from the
original GPI commissioning reference. The existing projection subtracts the
actually demanded, offset-free stage correction from woofer demand, preserving
stage-clipping spillover. This is complementary at the command boundary; a
finite stage transfer response means the *applied optical* sum need not equal
that instantaneous ideal command sum.

The generic plant response obeys y″ + 2ζωₙ y′ + ωₙ²y = ωₙ²u, with exact
zero-order-hold discretization at the declared simulation frame period. Samples
represent the end of each hold interval. No additional pure delay is inserted.
A 250 Hz natural frequency and damping ratio 0.7 are explicitly provisional
engineering assumptions, not measured GPI2 stage calibration. Published stage
resonance >200 Hz does not establish either value or the closed-loop response.

Compare four 4,096-frame cases from reset: ideal stage/pass-through controller,
ideal stage/25 Hz split, dynamic stage/pass-through, dynamic stage/25 Hz split.
Use the same full spatial atmosphere sequence, detector configuration/seed/reset
policy and original calibration matrices. Require the ideal/pass-through case
to reproduce the preceding accepted-woofer replay. Require reset reproduction,
finite state, command clamp/feedback identities and actual stage/DM command
adoption. Record actual applied stage response separately from demand.

WFE is piston-removed pupil OPD RMS, sampled first32frames then every64frames.
Clipping and command/response checks cover every frame. Compare late window
2049–4096; if structural checks pass, extend both dynamic-stage cases from reset
to16,384frames, regardless of which gives better WFE. Report both correction
and clipping. Do not enable a crossover merely because it reduces clipping.
No gain search, model fitting or automatic deployment follows this experiment.

Each warm case is bounded at300s; cold graph/controller preparation is separately
bounded at600s. Shared-host elapsed time is not a performance benchmark.

## Setup correction and package loading

The first setup attempted two identical controller topologies and exceeded its
combined 600 s controller-preparation budget before any optical preparation or
scientific frame. It was interrupted and retained as a failed setup, not a
numerical result. The corrective runner prepares one controller, adopts only
the tip/tilt coefficient bank off-frame, verifies all other parameter hashes,
and fully resets before each case. Julia optimization and all scientific
criteria remain unchanged.

The corrected process also encountered active precompilation of CUDA and
LoopVectorization dependencies before entering the runner. This package-loading
stage is recorded separately with an explicit 1,200 s limit, established while
precompilation was progressing. The 600 s numerical preparation and 300 s warm
case bounds are unchanged. Package-loading time is not presented as simulator
or controller execution time.

The next setup passed controller preparation (264.4 s) and ideal optical
preparation, then correctly rejected the assembled dynamic graph: the cold RTC
compiler had appended the response after its consumer, violating AOS's explicit
topological node order. This was an implementation defect, not a numerical
instability. The source now inserts the response immediately before the
original destination node. The new cheap native 2-mode/2×2-pupil selector
prepares, steps and resets the assembled response→optics graph before any full
controller preparation; the actual GPI graph also gets a static direct-link
ordering check. The rejected setup and exact source driver are retained.

A subsequent cheap admission-report construction failed because an inferred
string-valued dictionary could not hold a Boolean. Its driver, log and receipt
are retained. The report dictionary was corrected before numerical preparation;
no scientific frames or parameters changed.

## Observed results

All six cases completed, including exact historical agreement for every retained
ideal/identity observation. Both dynamic reset prefixes reproduce every saved
per-frame statistic, full demanded-command vector hash, sampled optical value
and sampled camera hash. All paired atmosphere hashes and detector RNG/reset
traces agree. The original graph, calibration receipt and environment manifest
remain unchanged. Command adoption, feedback, finite-state and independent
second-order recurrence checks pass throughout.

| Stage model / controller | Frames | Elapsed (s) | Late sampled WFE mean / maximum (nm) |
| --- | ---: | ---: | ---: |
| Ideal / identity | 4096 | 71.944 | 54.181 / 56.496 |
| Ideal / 25 Hz | 4096 | 59.927 | 54.193 / 56.500 |
| Dynamic / identity | 4096 | 47.954 | 54.232 / 56.567 |
| Dynamic / 25 Hz | 4096 | 46.737 | 54.191 / 56.435 |
| Dynamic / identity | 16384 | 210.320 | 54.094 / 70.061 |
| Dynamic / 25 Hz | 16384 | 234.186 | 54.096 / 70.103 |

Late windows are frames 2049–4096 or 2049–16384 respectively. These contain
32 or 224 optical observations; command and clipping statistics cover every
frame. Timing includes instrumentation and shared-host interference, and is
not execution-rate qualification.

In the long dynamic comparison, the 25 Hz filter reduces two-axis stage tracking
error norm RMS from 2.003 to 1.075 nm and peak axis tracking error from 5.932 to
2.962 nm. These are command-coefficient errors, not optical pupil WFE. Mean
sampled WFE changes by +0.00334%; this single-seed experiment establishes no
correction advantage. Woofer and stage clipping are absent in both late windows.
Mean tweeter clipped coordinates remain 27.445 and 27.479 per frame, respectively;
the filter does not resolve the remaining tweeter clipping. Neither stage
response exceeds its command boundary in these windows; the physical response
implementation intentionally does not clamp overshoot.

## Verification and disposition

`verify-results.jl` independently reads the raw cases and passes 99 assertions,
including complete frame counts and every saved scientific-case duration ≤300 s.
This final gate covers the runner's omitted final-checkpoint duration rejection
(TREV-01). The independent source and final numerical assessment is retained in
`REVIEW.md`; there are no unresolved blocking findings.

Focused software evidence includes 755 AOS CPU assertions, 822 CUDA capture/reset
assertions, existing graph and quality checks, and 45 reviewed API assertions.
The combined AOS selector initially failed its new-API allowlist; the corrected
allowlist passes separately. `aos-validation.log` retains both outcomes. RTC
configuration/schema, declaration, export, cadence and older-AOS extension
admission logs are also retained. The tiny native response→optics test passes
8 assertions and catches the ordering defect before full preparation.

The generic physical-response declaration and temporal coefficient generation
are available in source. GPI's authored 250 Hz / 0.7 model and 25 Hz split remain
explicit provisional settings, not an optimized controller or measured plant.
Historical calibration FITS and receipts are preserved; regenerate calibration
and build a fresh application before using the revised source prescription.
The live RTC and GUI retain their original invocation IDs and PIDs, both active.
No deployment or lifecycle action was performed.

Opening/closing correction independently of application execution remains a
separate missing capability, researched in `docs/HEADLESS_RTC_DESIGN.md`.
Automatic dependency ordering is also a follow-up: AOS currently validates
declaration order. This work fixes the cold response insertion under that
contract; it does not introduce topological sorting or alter delayed-link
semantics.

## Reproduction and retained records

Implementation revisions: AOS `dc2b867bd8a2f8158c318506b3dd2ce008d61da5`,
RTC `225c60535d0a43377ef0dd72302922f5c7710623`, with
instrument authoring commit `239d7594d0a6386a402e2f4cef5b2e89bd8847cb`.
The private environment uses
Julia 1.13.2, CUDA 6.4.2 and KernelAbstractions 0.9.45 on an RTX 3080. Exact
dependency/source/configuration hashes and parameter-bank identities are in
`replay-result.json` and `summary.json`.

`runners.tar.gz` retains drivers, resolved graphs, controller variants, the
private environment and authored YAML inputs. The calibrated FITS artifacts
remain external hash-bound inputs; this archive does not replace them or the
recorded scientific dependencies. Raw `case-*.json.gz`, setup failures,
summaries, logs and `SHA256SUMS` preserve both successful and rejected attempts.
Decompress raw cases before independent verification, with JSON.jl available:

```sh
julia --startup-file=no --project=/path/to/json-environment verify-results.jl /path/to/decompressed-cases independent-summary.json
```

Finite simulated behavior does not establish measured stage dynamics, global
stability, hardware limits, physical-device correctness or real-time deadlines.
