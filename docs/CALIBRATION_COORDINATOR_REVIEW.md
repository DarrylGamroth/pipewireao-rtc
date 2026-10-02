# Calibration coordinator review

This is evidence for the first completion-driven acquisition slice of
RTC-ARCH-023 / RTC-DEV-029, based on `e82879d` (2026-10-02). It is not an
operational calibration or physical endpoint qualification. The main checkout
was clean; implementation uses branch `work/event-calibration-20261002` in a
separate worktree. HEART and ordinary closed-loop deployment were unchanged.

## Scope and ownership

[src/calibration.rs](../src/calibration.rs) owns one serialized coordinator,
with one pending request. Prepared absolute Float32 probe figures and reference
figures use the scientific client's declared command units/order. The client
constructs the basis with AdaptiveOpticsCalibration and retains the complete
instrument/calibration manifest. This module does not synthesize probes,
perform WFS processing, average measurements or estimate matrices.

An operational endpoint must establish command ownership/integration hold,
confirm adoption, satisfy the selected settling rule, collect a completed WFS
response batch, fence outstanding operations and restore the reference, then
release ownership. Submission is prompt nonblocking enqueue, not completion;
queue exhaustion fails immediately. Effects carry monotonic host deadlines.
Endpoint acquisition cursors and exposure intervals use declared model time,
not host receive timestamps. Physical endpoints must define their own reliable
adoption/settling evidence.

The synchronous wrapper blocks only its calibration caller, while endpoint
execution/event serving remains independent. It consumes the same completion
contract as asynchronous coordination and does not sleep to establish success.
External asynchronous owners must service deadlines/cancellation and map Fault
to retained command ownership/integration hold or deployment failure. Dropping
a coordinator is not restoration. The wrapper invokes endpoint fault handling
before returning an unrecoverable state.

The retained payload/record budget is 512 MiB, including spare vector capacity.
There are at most 16,384 prepared probes and 4,096 contributing exposures per
probe. Allocator bookkeeping, endpoint staging and matrix estimation are outside
that budget; it is not a process RSS or peak-memory bound. No pixel arrays enter
this coordinator; accepted response buffers transfer ownership without copying.
Existing frame callbacks are unaffected. Current deployments do not select
this calibration path yet.

## Independent review

Astra reviewed the acquisition transitions and interface contract, then checked
the fixes. All four findings below are confirmed by source inspection. The
second pass found no additional material defects; it did not run tests.

| ID | Severity / confidence | Evidence and effect | Remediation / disposition |
| --- | --- | --- | --- |
| CAL-R1 | Medium / high | Length-only checks admitted oversized spare capacity in prepared probe and response vectors, bypassing the declared retained-size bound | Charge capacities and container records; reject before retaining a response. Fixed, independently rechecked |
| CAL-R2 | Medium / high | A release failure erased the distinction between acknowledged restoration and failed restoration | Preserve `restoration_confirmed()` through release failure. Fixed, independently rechecked |
| CAL-R3 | Medium / high | Submission lacked a nonblocking contract and deadline, allowing an adapter to defeat finite waits | Carry effect deadlines, check expiry before submission and require prompt nonblocking enqueue. Fixed contract; live adapter compliance remains unverified |
| CAL-R4 | Medium / high | Restoration could occur before the endpoint saw the probe settling rule or confirmed initial ownership | Carry settling rule in every restoration request; restoration establishes/retains the hold and fences outstanding work. Fixed contract; live fencing remains unverified |

## Verification and remaining gates

Focused coordinator and synthetic-endpoint tests cover event correlation,
exposure causality, clipping, cancellation, deadlines and restoration/release
failures. These tests establish orchestration behavior only. The 19 focused tests pass. Results and exact commands are recorded in the
active roadmap and [evidence summary](CALIBRATION_COORDINATOR_EVIDENCE.json).
The final independent pass inspected the tests and found no blocking findings.

Public endpoint reconnaissance found no held-probe/multiple-exposure operation
in AdaptiveOpticsSimPipeWireHIL, and no deployed calibration probe control,
integration-hold control or WFS response-batch readback surface in the current
FGN/JFG deployment adapter. Unchanged HEART's `CALIB_INTER` is a stub; its legacy
DM shape application and WFS averaging still need live qualification and
association. Those are implementation/integration gaps, not reasons to use
hidden AOS optics or fake a normal lockstep exchange.

Operational background/reference acquisition, AOC matrix/reconstructor export,
all three RTC endpoint adapters, Classic/Copper correction, CPU/CUDA/AMDGPU
execution and attainable cadence remain unqualified. RTC-DEV-029 stays partial.
