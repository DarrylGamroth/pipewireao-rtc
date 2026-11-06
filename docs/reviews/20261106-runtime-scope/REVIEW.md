# Remaining runtime and scientific scope — 2026-11-06

Read-only review at clean `cd46ce6`, branch
`codex/julia-session-policy-20261104`, dedicated worktree `pipewireao-rtc-cleanup`.
The user questioned the package's size given upstream transport and graph
execution ownership. This review proposes reductions; it changes no feature,
scientific equation, protocol or selected authority.

## Inventory and conclusion

The recursive `src/` + `ext/` inventory contains 62,339 physical Julia lines,
including comments/docstrings and excluding tests. Important groups are 13,878
top-level extension lines, 8,612 control lines, 8,488 deployment lines, 5,697
MediaSession lines and 3,505 `ext/aos` lines. These are navigation/counting facts,
not deletion estimates. The package still combines multiple scientific,
deployment and workstation responsibilities.

The largest next reductions concern ownership. Existing upstream primitives do
not always supply complete replacement interfaces. Establish those interfaces,
move their tests, and delete the corresponding RTC implementation together.
Splitting files or adding more forwarding modules would not remove maintained
decisions. No additional large subsystem was proven dead.

## Findings

### NEC-09 — active numerical calibration methods remain in RTC

High confidence. [Optical calibration](../../../ext/optical_calibration.jl),
`calibrate_optical(surface, observe, command_projection; ...)` at line 901,
constructs full/half-poke interaction matrices, branch reconstruction, nulling,
cross-talk and held-out checks from arrays/callbacks. This is transport-neutral
science, although it calls AOC's TSVD primitive. [Modal calibration](../../../ext/modal_calibration.jl)
also fits pupil ramps, constructs QR bases and RMS-weighted inverse products.
[Hidden-mode calibration](../../../ext/modal_hidden_modes.jl), lines 108–136,
forms discarded-SVD forward/reverse projections and numerical diagnostics.

Receiver: AdaptiveOpticsCalibration's existing probe/matrix/reconstructor and
modal domains, with missing product interfaces added there. Keep RTC acquisition,
recipe admission, native correlation, hashes and publication. Start with the
bounded hidden-mode product, then the array/callback optical method. Preserve
formulas, units, signed probes, tolerances and held-out tests.

### NEC-10 — simulator-specific expectation mathematics is in RTC

High confidence. [Optical expectations](../../../ext/optical_expectation.jl)
computes qualified Poisson/ADC rounding envelopes, sampling, control variates and
error estimates. Its opening envelope is explicitly restricted to gain 5000,
scale 1/64, bias 1024 and a narrow read-noise range. These numbers are a recorded
qualification boundary, not arbitrary constants safe to remove.

Move detector-law calculations to AOS and estimator mathematics to AOC; keep
actual executed-chain/provenance checks and native frontend adaptation in RTC.
AOS `Detectors.emccd_mean` excludes the rounding/readout/RNG-error effects, so it
is not a drop-in replacement. The method has active calibration callers.

### NEC-11 — RTC owns simulator stepping and exposure execution

High confidence. [External pupil execution](../../../ext/aos/external_pupil_owner.jl)
owns optical feeding/stepping, warmup, per-camera publication and the processing
loop (`feed!`, `stage_exposure!`, `publish_exposures!`, `run_streams!`).
[Pupil source execution](../../../ext/aos/pupil_source_owner.jl) likewise owns
science stepping/publication. This exceeds application admission adaptation.

Receiver: the existing AOS/HIL execution layer. Its array-stream public APIs
already supply stage/drain/reset/status, but not this complete optical executor.
Add the prepared execution/lifetime interface there. RTC should grant Run/Hold,
retain session policy and translate declared configuration. Preserve data-thread
placement, source/model chronology, pacing, coincident exposures and cleanup.

### NEC-12 — generic graph hosting has parallel implementations

High confidence. [RTC graph hosting](../../../ext/PipeWireAORTCGraphExt.jl),
lines 170–374, and FilterGraphIsland's `src/runtime.jl`, lines 60–142, both prepare
declarations/workers, own prepared graph lifetime, build a PipeWireNode, select
complete-frame/row-block preparation, connect, run and close it.

FilterGraphIsland should own those mechanics. RTC retains FITS admission,
native bootstrap authority, required metadata, correction observers and physical
offset policy through supported composition hooks. The inspected upstream
`run_service` still uses event-file connection orchestration and lacks these
hooks; calling it directly would lose the selected native admission contract.
Extend the existing host interface before removing the parallel RTC host.

### NEC-13 — sparse parameter publication embeds generic transport mechanics

High confidence. [ParameterSource](../../../src/control/parameter_source.jl),
lines 516–664, dequeues buffers, copies payloads, writes chunks/headers, queues
publication, fixes formats and installs callbacks. Those mechanics belong in
PipeWireAO. Its inspected APIs lack a complete sparse publisher with the required
schema/type and publication hooks.

Keep tickets, FITS selection, cancellation/revocation and `_publication_valid!`
in RTC. An upstream publisher must preserve validation immediately before native
queueing; moving copying alone must not publish after authority expires.

## Retained control policy and optional product scope

PipeWire transport and graph execution do not replace application controller
incarnations, admission, exact links, correlation, replay/unknown outcomes,
deadlines or required-loss recovery. The inspected `command_endpoint` is an
in-process typed sender waking a filter owner's loop, not a replacement for
RTC's cross-process application transaction protocols. The control/Hsm code is
not established redundant by its size.

NEC-06 remains a separate product choice: catalog Git/SQLite, optional analysis,
GUI management and cold simulator replacement are eagerly included in the root
package. Separating them can reduce mandatory RTC dependencies and release scope;
retiring unwanted features can reduce overall maintenance. Their current callers
and prior selections prevent treating them as dead code.

The generic capture work was an approved capability/generalization, not a code
reduction: its writer/reader, collector and calibration-owner subset adds a net 184 lines
against `94ecd39`. Its finite evidence ownership was explicitly settled in RTC.
Do not count that work as removal or reverse the decision merely to reduce a
line count.

## Review and validation limits

Two independent read-only investigations examined calibration and hosting
boundaries; root review checked the numerical kernels, parallel host setup and
buffer publication code. The hotspot scanner only prioritized inspection.
Reference-frame and Shack–Hartmann paths already delegate core estimates to AOC;
moving their entire files would mostly move legitimate orchestration. None of
the findings authorizes deleting their active callers or numerical safeguards.
No runtime, hardware or numerical tests were required for this source review.
