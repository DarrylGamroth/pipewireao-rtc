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

### CO-06 — Readiness included client state without a matching notification

Severity: medium. Confidence: high for the notification-contract defect;
unconfirmed as the cause of the original registered qualification timeout.
Classification: source-derived defect independently reproduced in an isolated
transport experiment. Disposition: registry-based correction under final
integration validation; independent source review found no remaining blockers.

The original worker published `ready=true` and notified before entering its
native run loop. The constructor also required the worker's client-side
`node_id` to become non-`nothing`, although its condition had no notification
for that later binding update. Registry callbacks could wake the constructor
before the separate client binding became visible and leave it waiting after
the predicate became true.

The fresh registered qualification passed its first two optical cases, then
expired the third constructor's 300-second readiness deadline. An independent
SIGUSR1 snapshot and GDB attachment located the main task in
`calibration_owner.jl:315`'s readiness `await`, while both graph workers were
inside idle native run loops. It was not blocked in `roundtrip`; the finite
deadline did expire. The workers' node IDs were not captured, so this observation
does not by itself establish the initiating cause.

Two temporary source diagnostic runs passed the combined 29 projection,
six binding and 106 optical assertions. The first observed both IDs valid at
a one-shot wake but lacked causal timestamps. In the timed run all readiness
waits ended before the diagnostic timer fired: 7.236 seconds, 2.37 milliseconds
and 5.03 milliseconds. Those passes did not reproduce or explain the registered
failure. The temporary block was removed completely before production edits.

The reviewer then ran a separate 20-cycle private-core experiment with two tiny
PDM workers and the exact original predicate, warming the first cycle. Five of
19 measured cycles remained waiting with both workers ready, neither finished,
and both public node IDs already valid. One diagnostic notification released
each wait; four exited 0.95–1.10 milliseconds after the snapshot, and the first
such snapshot exited after 199 milliseconds. All workers and graphs closed;
no GPU package loaded. This reproduces the missing-notification mechanism
without optical stepping. Evidence files are
`readiness-original-predicate-stress-20261027.jl` and its `.log` in the existing
`standard-calibration-validation` evidence directory; the original registered
failure and both optical diagnostic logs remain preserved separately.

The production correction moves readiness to the exact server registry node
and port state published by registry callbacks, retains IDs and object serials,
and revalidates their incarnations when creating and admitting links. Link-info
callbacks and the original absolute deadline replace constructor roundtrips;
there is no periodic readiness polling. Each preparation generates a fresh
bounded UUID cohort for its private graph names, so a prior same-name graph on
a reused core cannot satisfy discovery. Link removal/error and `UNLINKED` set
sticky failure state and notify; later info cannot revive an invalidated link.
The reviewer checked callback lifetimes and partial-startup resource closure
without finding another source blocker. The original public control endpoint
name and controller authority remain unchanged.

The primary's repaired registry-predicate stress completed all 20 cycles without
a diagnostic wake, and its focused transport selector passed 26 assertions,
including seven registry identity checks. These are attributed results whose
logs were inspected by the reviewer. Fresh final-source combined qualification
remains the implementer's gate; previous optical passes predate this startup
correction.

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
was open during review; this review selected no default. The user subsequently
described daytime internal-source calibration followed by on-sky adjustment;
the primary recorded that operating approach in the plan. Its scientific
settings and positive qualification remain separate work.

After the focused review, the primary reported final-source results of 27
transport/identity, 62 readiness-regression, 106 optical safety and 326 package
assertions. The optical source included UUID names and sticky link invalidation.
These are attributed results, not additional independent runs. They remediate
CO-06 at the scoped software integration level; registered release evidence is
maintained in the adjacent verification record.

The primary subsequently reported all 237 combined registered-only assertions
passing with published RTC 0.2.24/HIL 0.2.7, plus 119 selected instrument-bundle
checks and formatting. These are attributed release results; the record
preserves the first harness's Pkg/PipeWireAO export-name conflict separately
from the earlier production readiness timeout. No additional runtime change
followed the final source review.

An in-flight synchronous HIL adoption/step can finish or reach its existing
finite timeout before the sole owner checks controller loss. The reviewed
contract does not establish immediate hard cancellation. Cooperative checks
must prevent subsequent exposures/work after loss and fence endpoints without
restoration, retry, rebind or ordinary-loop resumption. Physical settling and
worst-case timing require separate evidence.

## Internal-source cold selection: independent source review

Reviewed the uncommitted increment on RTC `8977d4d` and instrument `bcbd339`,
both on `codex/internal-source-calibration-20261027` in their dedicated
`rtc-internal-source-20261027` and `instruments-internal-source-20261027`
worktrees. Authority: RTC-ARCH-023, RTC-DEV-029 and the internal-source
follow-up in [PLAN.md](PLAN.md). No blocking source finding was identified.

The existing production and ideal diagnostic defaults remain compatible.
The optional declared graph passes the existing graph, binding and HIL
boundary validation; absent selections and conflicting diagnostic selections
reject. Common profile/settings expansion and typed AOS preparation still own
the selected graph. The initial-calibration owner permits only production or
internal-source and compares the complete resolved detector-node declarations
with production before allocating the AOS/native endpoint. The normal detector
noise, ADC, exposure and response settings therefore remain authoritative.
The regular RTC graph and selected FITS input checks are unchanged.

The Classic graph removes the atmosphere component and supplies its known
uncompensated-OPD port with the existing typed Float32 zero binding. It retains
the same DM, OPD composition, WFS and detector components and normal command
and frame boundaries. The unchanged on-axis guide photometry and this topology
establish a stationary point-source-equivalent scene by source inspection;
they do not establish a physical lamp-injection model or illumination
eligibility. No controller coefficients, frozen calibration bytes, source
brightness or acceptance threshold change in this increment.

The new selection adds no resource lifecycle or transport owner. Invalid
selection/detector configuration rejects before AOS/native allocation; later
failures retain the existing bounded teardown. Source inspection cannot
establish transported exposure identities or successful worker/core cleanup;
the maintained private-core selector must supply that evidence separately.

The reviewer independently ran `git diff --check` in both worktrees; both
passed. The primary reports 17 cold-selector assertions passing. That result
is attributed, not an independent execution by this reviewer. The reported
stationary-source experiment rejected all 11 samples against the unchanged
frozen mask. It remains a failed scientific eligibility gate; this source
review does not promote accepted interaction measurements, matrix quality,
full-basis acceptance or an activatable calibration. No GPU, live desktop
core, installed session, physical device or timing qualification was used.

## Classic capture files: independent review

Scope: `src/calibration_capture_files.jl` and
`test/test_calibration_capture_files.jl` against RTC-DEV-029's capture clauses,
the native `Captured` descriptor and the existing acquisition cursor semantics.
This is the bounded Classic file boundary in a trusted local/private-core
profile. Owner integration and campaign restoration, shutdown, retention and
cleanup were pending at this review; they are not established by file tests.

### CO-07 — Capture incorrectly required adjacent exposure intervals

Severity: high for functionality. Confidence: high. Classification: observed
defect. Disposition: remediated; independently verified.

The original `_capture_exposure` required each model start to equal the previous
cursor's model time, which is the previous exposure's end. The existing
acquisition coordinator permits a later start while requiring the next exact
sequence, domain and generation. Detector exposure duration can be shorter than
model cadence. An independent synthetic two-frame capture with a 104,000 ns gap
rejected the second completed exposure as stale/discontinuous after acquiring
both frames, leaving partial files without a completion manifest.

The corrected comparison permits `start_model_ns >= cursor.model_ns`, preserving
exact sequence/identity, positive duration and bounded end checks. The focused
test now writes and reads 1,896,000 ns exposures at a 2,000,000 ns cadence and
checks the final 3,896,000 ns cursor. Overlapping intervals still reject at both
writer and reader boundaries. No exposure duration or cadence was changed.

### CO-08 — Final manifest cursor accepted noninteger numeric aliases

Severity: medium. Confidence: high. Classification: observed validation defect.
Disposition: remediated; independently verified.

The original reader compared the final manifest cursor dictionary directly
with the verified cursor. Julia dictionary equality treats Boolean/integer
and exactly equal floating/integer values as equal. An independent rehashed
one-frame manifest with `cursor.sequence = true` was accepted. Payloads and
exposure authority remained verified, but the promised strict integer schema
was not enforced for that final object.

The reader now passes the final cursor through the existing strict cursor
parser before comparing it. Focused negative cases reject Boolean and floating
sequence aliases and a floating model-time alias. This reuses the existing
integer/domain/range rules rather than adding another schema authority.

The reviewer independently ran Julia 1.13.3 with
`julia +1.13.3 --startup-file=no --project=. test/test_calibration_capture_files.jl`:
124/124 assertions passed after correction. `git diff --check` passed. Source
inspection also covered fixed U16/F32/BOOL8 little-endian row-major contracts,
full acquisition-domain mapping, exact wide integer receipts, cumulative
reservation before acquisition, bounded settings/exposure metadata, canonical
paths, symlink rejection, hashes, incomplete publication and caller-selected
profile/settings verification. No remaining file-boundary blocker was found.
These are software/file checks; they do not establish integrated owner effects,
Copper support, physical correctness, fault/restoration behavior or deadline
performance. No GPU or live core was used.

## Capture owner integration: bounded independent review

Scope: the native Capture method and capture preparation in
`ext/calibration_owner.jl`, the extracted storage preflight, and
`GraphOwner.prepare_artifacts`. Authority remains RTC-DEV-029 and RTC-ARCH-023.
This review covers source behavior and CPU/file checks, not a transported
capture or a complete campaign.

### CO-09 — Capture identity omitted selected FITS image interpretation

Severity: medium. Confidence: high. Classification: observed identity defect.
Disposition: remediated; independently verified at the shared FITS boundary.

The initial owner recorded each frontend parameter's source-file hash, target
type and shape. An unchanged multi-HDU FITS file can contain distinct images
with the same type and shape; changing the selected HDU therefore changed the
prepared parameter without changing that capture identity. Axes were likewise
omitted. An independent CPU example prepared Float32 `[1,2]` and `[3,4]` from
HDUs 1 and 2 of the same file and confirmed distinct arrays but identical
original capture identities. Command-projection parameter identities were
also absent from the capture settings.

The shared preparation now returns `PreparedArtifact` values through
`prepare_artifacts`, while `prepare_bindings` preserves its existing array
interface. The owner compares and applies those exact prepared arrays and
retains provenance from their corresponding source snapshots. Capture settings
for both frontend and command projections now bind original and prepared
content hashes, selected HDU, normalized axes, target type and target shape.
Absolute source paths are excluded. This avoids reopening a source merely to
compute provenance after preparation.

The reviewer independently ran `test/test_graph_owner.jl` in the RTC root
environment using Julia 1.13.3: 86/86 assertions passed, including eight durable
same-file, distinct-HDU regression assertions. They verify equal original file
hashes, distinct prepared arrays and hashes, selected HDUs, normalized axes and
compatibility with the existing `prepare_bindings` array interface. The earlier
independent example also confirmed distinct final capture parameter identities.
The focused capture-file selector independently
passed 150/150 assertions after preflight extraction. `git diff --check` passed.

Source inspection found the owner checks current probe and exact cursor before
storage admission. The preflight does not reserve bytes, create request files
or acquire exposures; its validation rejection preserves the settled phase.
Capture repeats admission immediately before reservation. Subsequent
acquisition/write/publication failures propagate to the existing native fault
fence rather than being converted to known pre-effect rejection. Storage uses
the same request deadline and owner checks as exposure acquisition; partial
files remain owned by the campaign and owner closure does not erase evidence.
The fresh directory may remain after a preparation failure and requires the
caller's normal retention/cleanup handling.

No remaining blocker was found in this bounded source review. A private-core
integration selector must still establish actual native Capture completion,
descriptor verification, capacity rejection before another exposure, and the
owner's restoration/release/teardown behavior. These results do not qualify
Copper, physical devices, cadence or deadline performance. No GPU, live core
or physical device was used by this reviewer.

### CO-10 — Capture payload validation overwrote the command format

Severity: high for capture-enabled startup. Confidence: high. Classification:
confirmed source defect, independently reproduced without a core or optical
execution. Disposition: remediated in canonical source; fresh integration and
superseding registered-release qualification remain separate gates.

Registered RTC 0.2.25 (`4698f7b`, package tree
`161bccd8c683b64ab0c3d534fdceeddf2ebd5da2`) rejected capture-enabled preparation
in `calibration_probe_format`, before any native action. The retained
`internal-source-registered-025-capture-20261027.log` reports six assertions
passing and one constructor error. This is a real release failure, rather than
a dependency-format or stale-precompile explanation. The 0.2.25 tag and
registry record remain immutable; the fix requires a superseding release.

The fixed Classic payload-contract loop introduced in `calibration_owner.jl`
assigned its selected payload to the existing function-local `format`. That
binding already held the requested physical-command format. The final loop
role is validity, so the later `prepare_calibration_probe` received the
validity format instead of the requested command format. The Float32 guard
correctly rejected it. Capture-disabled preparation does not enter this loop.

Independent cold inspection used Julia 1.13.3 and the unchanged registered
0.2.25 environment. Both the fresh registered application and the earlier
built application have regular-graph SHA-256
`a9e39891219b83e5a3327027951395c9fdfe74f2e9b8a1cecd511f3f7eb2a575`.
Their requested, demanded and constraint-feedback formats are all Float32,
rank one, shape `(277,)`, with the declared distinct schemas. Each passes
the registered transport helper directly. The extension's PipeWireAO and
Float32 identities match their public modules; `F32_LE` is the expected enum
value 18. Actual frontend validity is Bool, rank one, shape `(188,)`.

The reviewer independently reproduced the original local-variable loop over
those actual prepared graph formats: all four payload contracts pass, then
the returned format is the Bool validity format and the transport helper
rejects it. Repeating the same loop with the primary's `payload_format` local
preserves the original Float32 requested format and the same helper accepts
it. All 16 cold assertions passed. The canonical two-line fix changes only
that loop variable and its validation reference. It retains the payload
contract, command guard, schema, shape and rate checks, and leaves the separate
`capture_format` conversion helper unchanged.

The reproducible evidence in the existing `standard-calibration-validation`
directory is `registered-025-format-inspection-20261027.jl` and its successful
`-cold.log`, plus `registered-025-format-shadow-20261027.jl` and `.log`.
The first inspection log preserves a diagnostic-script syntax failure before
the corrected cold run; it is not product evidence. The earlier source
171-assertion Capture run predates the added payload-contract loop and cannot
qualify the 0.2.25 source. The primary is running a fresh corrected-source
Capture selector; this reviewer has not performed or attributed an optical
rerun. No PipeWire core, GPU or physical device was used in this diagnosis.
