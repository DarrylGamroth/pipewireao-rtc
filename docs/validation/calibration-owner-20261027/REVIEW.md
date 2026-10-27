# Native initial-calibration review — 2026-10-27

Independent review of the evolving `codex/calibration-owner-20261027` worktree,
starting from RTC `864281b`. The reviewer added this record and the requested
`test/initial_calibration_bindings.jl` negative selector. The implementation,
other tests and plan were already present or evolving during review.
Authority: RTC-ARCH-023, RTC-DEV-029/030 and [PLAN.md](PLAN.md).

Scope: `src/native/native_calibration_endpoint.jl`,
`ext/calibration_capture.jl`, `ext/calibration_owner.jl`,
`ext/calibration_transport.jl`, `ext/calibration_graphs.jl`, their native/CPU
tests, and the existing native ingress, action codec and FITS preparation
contracts. No installed session or physical device was used.

## Findings and disposition

### CO-01 — Retained controller loss did not fault an idle owner

Severity: medium. Confidence: high. Classification: observed defect.
Disposition: remediated; independently verified for idle loss.

The earlier `NativeCalibrationEndpoint.serve!` predicate only examined a pending
ticket or the previous completion header. After a successful Hold, exact
controller removal left no pending ticket and a successful retained header.
An independent private-core check observed removal, then found the server still
running after 250 ms, with phase `Held` and effects open. The final idle
predicate checks retained controller presence under the native loop lock.

The initial owner also calls the dispatcher's `check_current!` before further
effects, after adoption/capture and on capture wakeups. This preserves one
control authority. Required integration evidence: controller loss during
acquisition must not initiate another exposure or a recovery submission.

### CO-02 — Wakeup closure raced notification producers

Severity: medium. Confidence: high in the source race and protection.
Classification: derived defect; no crash reproduced. Disposition: remediated
in source; concurrency stress remains outside this review's evidence.

Earlier endpoint cleanup closed the `AsyncCondition` without the lock used by
`wake!`; capture notification also checked and used its handle without that
shared lock. A queued timer callback can outlive timer-handle closure, making
an unprotected `isopen`/`uv_async_send` sequence race final condition closure.
Normal and exceptional endpoint/builder cleanup now share the notification
guard. Capture accepts the same guard and uses it for notification and owned
condition closure. Native/stream producers are fenced before final closure.

### CO-03 — Full acquisition domains were passed to UInt64 native fields

Severity: high for functionality. Confidence: high. Classification: confirmed
source defect. Disposition: remediated in source; actual pilot pending.

HIL exposes a full 16-byte `AcquisitionDomain`, while native
`AcquisitionCursor.domain` and `Exposure.domain` are `UInt64`. The earlier
initial-cursor and exposure constructors passed the full domain directly,
preventing the initial workflow from completing. The owner now retains its
full domain, maps this one initial session to positive coordinator ID `1`,
and verifies each exposure's full domain and generation before constructing
the native record. Raw/WFS receipts retain the full identity. Evidence must
retain that mapping rather than equate full and coordinator domains.

### CO-04 — Projection authority must bind selected calibration inputs

Severity: medium. Confidence: high. Classification: confirmed validation gap.
Disposition: graph and selected FITS authority remediated; focused negative
selector independently passed.

The builder now requires both descriptors' `source_graph_sha256` to equal the
selected application's regular graph hash. This rejects projections from a
different graph. It does not distinguish applications with identical graph
bytes but different `rtc/parameters.conf` or selected FITS contents. Projection
preparation retains bindings and owned arrays. The earlier builder checked
neither against its application's selected inputs.

The revised builder reuses `GraphOwner.bindings`, `GraphOwner.prepare_bindings`
and `JuliaFilterGraph.replace_parameters!`. Before plant allocation it prepares
this application's selected parameter ports against each projection's declared
formats, requires exact port sets and equal logical values, then applies fresh
validated arrays to the prepared graphs. It normalizes retained bindings and
arrays to this selection and requires the frozen active mask to match.
Reapplying the inputs also defeats prior graph-parameter replacement without
private graph introspection. No new registry or calibration authority was added.

The focused `test/initial_calibration_bindings.jl` selector passes a same-graph
descriptor with stale same-shape background data and requires the specific
selected-FITS mismatch error before any connection or plant allocation. Full
calibration evidence must retain selected input provenance, including original
and prepared content hashes, HDU, axes, target type and shape; the existing
`Artifacts.prepare` provenance supplies those fields. Hashing only
`parameters.conf` would miss changed FITS bytes at an unchanged path.

## Verification and limits

Independently ran `julia --startup-file=no --project=.
test/native_calibration_owner.jl` under Julia 1.13.2: 22 assertions passed
(14 native dispatch/protocol, eight idle-controller-loss). `git diff --check`
passed. Independently ran `test/initial_calibration_bindings.jl` under Julia
1.13.3 with three threads in the scientific environment: all six assertions
passed, including same-graph stale-background rejection and no loaded GPU
package. The preceding private-core idle-loss experiment established
fail-before evidence for CO-01. Other reported collector, projection and
transport test results are implementer evidence, not independent executions
by this reviewer.

The actual Classic signed-probe pilot remains pending. A source-level closure
of CO-03/04 does not substitute for that integration check or for the required
fault/recovery cases. This increment has no full-basis numerical acceptance,
activatable calibration, GPU, hardware or latency qualification.

An in-flight synchronous HIL adoption/step can finish or reach its existing
finite timeout before the sole owner checks controller loss. The reviewed
contract does not establish immediate hard cancellation. Cooperative checks
must prevent subsequent exposures/work after loss and fence endpoints without
restoration, retry, rebind or ordinary-loop resumption. Physical settling and
worst-case timing require separate evidence.
