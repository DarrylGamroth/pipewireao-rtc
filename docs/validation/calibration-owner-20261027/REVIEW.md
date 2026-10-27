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
contracts. The later focused source review also covered HIL commit `d58959a`
against `4f2f37e` and the RTC publication-cycle wait and teardown order. No
installed session or physical device was used.

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
source defect. Disposition: remediated; actual full-identity association
verified in the implementer's r6 production-path pilot.

HIL exposes a full 16-byte `AcquisitionDomain`, while native
`AcquisitionCursor.domain` and `Exposure.domain` are `UInt64`. The earlier
initial-cursor and exposure constructors passed the full domain directly,
preventing the initial workflow from completing. The owner now retains its
full domain, maps this one initial session to positive coordinator ID `1`,
and verifies each exposure's full domain and generation before constructing
the native record. Raw/WFS receipts retain the full identity. Evidence must
retain that mapping rather than equate full and coordinator domains.
The r6 pilot verified matching full identity, model start and duration at all
raw/WFS sinks before the native response was constructed; this is attributed
integration evidence rather than an independent rerun by this reviewer.

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

### CO-05 — Source queueing did not establish publication-cycle completion

Severity: high for functionality. Confidence: high. Classification: observed
integration failure and source-confirmed ordering distinction. Disposition:
production correction source-reviewed without blockers; r6 transport and known
abort/recovery verified by the implementer.

Earlier r3/r5 optical trials timed out collecting WFS responses after HIL frame
publication. HIL's publication flag is written when its source callback queues
the buffer, before the native source cycle necessarily ends. A test-only r4
listener used private publication state and public `trigger_done` to request
one further native cycle. It demonstrated complete raw/WFS receipts and a
response, but that diagnostic did not establish a production public-API path.

HIL `d58959a` exposes the bounded atomic
`frame_publication_cycle_sequence` witness. Its `on_trigger_done` callback only
records the published sequence and signals existing completion state; it
requests no processing and executes no science. Reset clears the witness;
failure and the pending-exposure fence remain authoritative. RTC waits for
the exact public witness under its original deadline and controller checks,
then requests one public native cycle from the sole control owner. Its listener
only notifies. All raw/WFS receipts must still match the armed full exposure
before `complete_pipewire_exposure!`; the witness and kick cannot establish WFS
success or advance model time.

The r6 trial exercised this pure production path without private HIL access or
test-driven scheduling. It reached an actual native `Responses` result, whose
scientific validity was correctly false: frozen active indices 85 and 104 had
flux approximately 932 and 975, below their unchanged threshold of 1,000. No
nonfinite values explained the rejection. Acquisition reported known
`InvalidEvidence`, then actually confirmed Restore and Release. Settings,
eligibility, thresholds, source data and acceptance policy were not relaxed.
This is successful transport/identity and rejection/recovery evidence, not an
accepted positive calibration.

Teardown now stops HIL admission, requests quit for all native graph workers,
awaits them within a finite deadline, then closes capture/probe/links/core.
Prepared graph storage remains alive until worker tasks stop. The implementer's
r5 cleanup check found no worker errors after this ordering change; earlier
`EPIPE` observations arose only during peer teardown.

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

Additional results reported by the primary: HIL's full `Pkg.test`, including
Aqua and private-core selectors, passed 2,993 assertions; RTC's full root
selector passed 5,624 assertions. The primary subsequently reported the
complete RTC `Pkg.test` also passed 5,624 assertions. These suites were not
independently rerun by this reviewer.

The r7 optical safety run observed all three intended behaviors: the unchanged
under-threshold response aborted and restored/released, early cancellation
restored/released, and idle controller loss fenced without another exposure or
Restore. That run still failed assertions comparing concrete parametric action
types with `UnionAll`; those test comparisons were corrected. The r8 rerun
subsequently passed 106 assertions across those three scenarios, including
application-file preservation and no loaded CUDA/AMDGPU package. This final
result is implementer evidence, not an independent optical rerun.

Current completion gates remain partial. The actual production path has proven
full-identity transport and a scientifically correct invalid-response abort.
There is no positive accepted noisy AOC calibration, full-basis numerical
acceptance, activatable bundle, actual optical consumer-failure case, or
in-flight optical controller-loss coverage. Positive procedure and consumer
failure unit coverage are separate evidence. No GPU, hardware, latency or
physical-settling qualification is established. The asynchronous execution
policy question, including stationary-source versus support for both modes,
remains open; this review selects no default.

An in-flight synchronous HIL adoption/step can finish or reach its existing
finite timeout before the sole owner checks controller loss. The reviewed
contract does not establish immediate hard cancellation. Cooperative checks
must prevent subsequent exposures/work after loss and fence endpoints without
restoration, retry, rebind or ordinary-loop resumption. Physical settling and
worst-case timing require separate evidence.
