# Independent runtime and library reuse review

Date: 2026-10-14. Scope: [review scope](SCOPE.md). Disposition: proposals for
primary-agent adjudication; no production remediation performed.

The existing architecture is a plausible foundation for the non-actuating
development RTC. Its strongest features are explicit session authority,
incarnation-bound requests, one pending operation, owner-applied completions,
source-first stopping, and separation of scientific execution from control
callbacks. The review does **not** establish startup/teardown reliability or a
latency/resource qualification. One confirmed source defect can turn a malformed
session command into a session fault. The recorded warmup and Quit failures
remain unresolved at the causal level. Preserve these distinctions during the
package rename and registered-package migration.

## Source and verification boundary

This report inspects the actual working files, not only the clean review
worktree. Source abbreviations below identify their locations:

| Abbreviation | Checkout and revision |
| --- | --- |
| RTC | `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc`, branch `main`, `f7777e8154f9593b793edb50b5162df05161b9aa`; the three pre-existing changes in SCOPE.md are included |
| REVOLT | `/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl`, `9c3e51ce6d943719ffa9aec180f18b34cfb26a1b`; the four pre-existing HIL/source-control edits are included |
| WP | `/home/dgamroth/workspaces/codex/pipewire/wireplumber`, `d20cd2037fda7b5932b0feb58b0af5aef5226a48`, clean at inspection |
| Installed WP | `/home/dgamroth/.local/state/revolt-rtc/classic-gui-20261013/installed/wireplumber` |
| HIL adapter | `/home/dgamroth/workspaces/codex/AdaptiveOpticsSimPipeWireHIL.jl`, local source declaring version 0.1.2; dependency/release provenance is an integration gate, not established by that version alone |
| Library roots | `/home/dgamroth/workspaces/codex/<package>.jl`, with versions and revisions below |

WP `src/scripts/ao/session.lua` and its installed counterpart have identical
SHA-256 `bb232ff9a615cb205a71558bab1b5a264d0f989c8ac9ad9d1e12e2bf008869d6`.
WP `src/scripts/lib/ao-session-control.lua` and its installed counterpart have
identical SHA-256 `db7fd2fcb2f84f1f255d2686fac74ce7ebf8bbbb70c926a449cc7f67c1bff76c`.
This comparison supports the policy findings; it does not establish equivalence
of every installed Julia dependency or binary.

Read-only source, tests as source, repository instructions, and existing dated
evidence were inspected. No tests, benchmarks, Julia sessions, live services,
GPU workloads, or GUI actions were run. There is no new fail-before/pass-after
execution evidence. Relevant skills: review-low-latency-design and its architecture
checklist, review-julia-package-design, and package-quality dependency placement.
No documentation-only review rule was used to infer permission for live tests.

Evidence classifications: **Observed** means source structure or a cited recorded
observation; **Derived** means a logical consequence of that evidence;
**Hypothesis** requires a discriminating experiment. Source-derived behavior is
not presented as newly reproduced runtime behavior.

Relevant test source includes RTC `test/test_native_control_client.jl`,
`test/test_calibration_acquisition.jl`, and REVOLT's modified
`assets/deployment/hil/test_source_control.jl`. These exercise matching reply
observations, typed calibration/recovery sequences, and the actual source
callback trampoline with pending/rejection preservation. Existing assertions
are useful implementation oracles; they were not executed and do not establish
the newly proposed invalid-session-command behavior gate.

## Findings

### RAR-01 — Pre-effect session validation can fault a healthy session

- **Severity:** High (P1), correctness and availability.
- **Confidence:** High in source behavior; no execution reproduction in this review.
- **Classification:** Observed control flow; derived effect on a healthy session.
- **Disposition:** Proposed confirmed defect, independently adjudicate and fix before broad command/API refactoring.
- **Evidence:** WP `src/scripts/ao/session.lua:450–466` validates operation arity,
  admission state and Reset state with assertions. The ticket has already been
  installed by `lib/ao-session-control.lua:166–177`. Its handler exception path
  unconditionally calls `self.fault` at lines 177–180. `session.lua:180–219`
  marks Fault, invalidates the current epoch, attempts source hold, stops
  consumers after the hold acknowledgement and withdraws links. RTC
  `docs/operations.md:745–746` requires malformed commands to reject without
  terminating a healthy session. Source/installed policy hashes match above.
- **Trigger:** An authenticated native request with a valid envelope but wrong
  command field arity reaches the assertion at `session.lua:460`. No scientific
  effect has been requested yet. Nevertheless the general handler catch faults
  the session. A Reset request while Running also takes this pre-effect failure
  path; its admissibility handling needs an explicit policy alongside the
  unambiguous malformed-command case.
- **Impact:** A client input mistake can cause acquisition hold and link
  withdrawal. Local Julia command encoding catches some malformed inputs but is
  not the server's validation boundary; other native clients can submit valid
  envelopes with invalid operation payloads.
- **Remediation:** Separate pure command validation/admission from accepted
  effects. Return the protocol's negative rejection/completion for invalid
  pre-effect requests while preserving the current admitted state. Keep fault
  escalation for required identity/transport loss and uncertain effects. Do not
  globally turn all caught exceptions into harmless rejection.
- **Required validation:** In an isolated policy harness, submit wrong arity,
  wrong scalar type, unknown operation and invalid state commands while Ready
  and Running. Verify no hold, graph stop, link withdrawal or epoch replacement;
  verify subsequent valid commands still work. Inject a failure after an effect
  was issued and prove the existing fault/Unknown behavior remains. The same
  malformed request should demonstrate fail-before/pass-after behavior.

### RAR-02 — Quit has a shared five-second internal budget without phase attribution

- **Severity:** High (P1) reliability investigation; not a proven scheduling/root-cause defect.
- **Confidence:** High in the shared budget and recorded deadline exhaustion;
  unresolved regarding the consuming phase.
- **Classification:** Observed source and recorded failure; possible causes remain hypotheses.
- **Disposition:** Proposed open investigation; retain CTW-02 rather than invent a second resolved root cause.
- **Evidence:** WP `src/scripts/ao/session.lua:75–92` caps every ticketed internal
  effect at `min(ticket.deadline, now + 5 seconds)`. Quit at lines 509–539 shares
  that one budget across source hold, graph stop, link withdrawal, acquisition
  shutdown, bootstrap shutdown, controller release and client removal.
  RTC `src/native_owner_bootstrap_runtime.jl:406–425` waits for `main_finished`,
  publishes and flushes the terminal reply, and waits for controller release.
  REVOLT `assets/deployment/hil/simulator_owner.jl:576–588` closes the adapter and
  writes its report before returning to bootstrap finishing. The recorded
  CTW-02 timeline is in REVOLT
  `docs/validation/classic-template-20261014/README.md`.
- **Observed outcome:** The frame run returned Unknown at Quit; subsequent
  read-only checks confirmed cleanup. The report records internal expiry at
  13:01:56.727626, report writing at 13:01:56.804467 and an owner deadline error
  at 13:02:00.687415. These timestamps do not identify which earlier phase
  consumed the budget. The successful Reset-before-Quit run is not a causal
  demonstration of a fix.
- **Derived risk:** A timeout on an individual HIL wait does not bound an entire
  frame exchange, report serialization or the whole Quit chain. The adapter
  `src/exchange.jl:954–999` performs plant work and multiple waits; waits at
  lines 874–890 each have their own development timeout. Source controls are
  serviced between exchanges. A compliant individual wait can therefore consume
  much of the session's shared Quit allowance. This is a budget composition
  concern, not proof that it caused CTW-02.
- **Remediation:** First add optional bounded phase timestamps to the existing
  owners and policy. Record entry/exit and remaining shared budget for every
  Quit phase, `main_finished`, terminal publication, release and removal. Use
  these measurements to decide whether cold work needs preparation, the contract
  needs a revised budget, or a specific blocking phase needs repair. Preserve
  no-retry and source-first ordering. A timeout increase alone is not an
  adjudicated solution.
- **Required validation:** Cold and warm Quit after finite and continuous runs;
  Quit while one exchange is pending; report-heavy finalization; owner/core loss;
  terminal publication and exact controller removal. Record the request outcome
  and cleanup result independently. Do not convert later cleanup success into
  a successful earlier Quit completion.

### RAR-03 — Warmup timeout evidence cannot distinguish transport from client work

- **Severity:** Medium (P2) diagnostic/reliability gap.
- **Confidence:** High in the missing discrimination; low for any particular cause.
- **Classification:** Observed; compilation/scheduling explanations remain hypotheses.
- **Disposition:** Proposed open investigation, preserving CTW-01.
- **Evidence:** RTC `wireplumber_cli.jl:142–159` gives each warmup query at most
  ten seconds within the larger startup window. WP `session.lua:480–501`
  immediately replies with `state.warmed`; it does not hold the query until
  preparation finishes. RTC `src/native_control_client.jl:177–204` decodes and
  copies the completion before recording the default observation time;
  `matching_reply` at lines 230–240 uses the same deadline error when no timely
  matching observation exists. The recorded failed run remained at sequence zero
  and never logged Connected.
- **Impact:** The outer 900-second startup allowance cannot rescue an Unknown
  ten-second request. A journal timeout alone cannot justify blaming CUDA,
  cold Julia compilation, WirePlumber or native transport.
- **Remediation:** Trace one exact token at client submission, native WP receipt,
  Lua dispatch, completion publication, client callback entry, decode end and
  match. Record whether a matching completion was present at timeout. Keep
  receipt time separate from decode completion and application acceptance time;
  do not change deadline semantics just to change the diagnosis.
- **Required validation:** A fresh isolated cold start plus a warmed comparison
  with phase tracing, exact versions, thread placement and loaded caches recorded.
  Preserve original failure evidence. No request replay on the retired client.

### RAR-04 — FITS-only deployments need an explicit cold in-memory owner interface

- **Severity:** Medium (P2) required migration work; not a defect against the old packed-file contract.
- **Confidence:** High.
- **Classification:** Observed implementation mismatch with the user's new target.
- **Disposition:** Proposed required design/implementation item coordinated with architecture review.
- **Evidence:** REVOLT `src/artifact_files.jl:132–143,154–198` captures FITS,
  validates the selected HDU, permutes logical axes and writes a packed payload
  plus provenance. RTC `src/native_parameter_source.jl:147–217` declares raw
  packed paths and preallocates byte arrays; lines 220–245 read those files, and
  lines 476–502 stage native publication. The live parameter request carries
  graph/inlet/type/shape/schema/path, with bytes supplied by the parameter owner.
- **Impact:** Merely renaming the package or substituting a FITS pathname for a
  packed pathname would violate the existing reader's byte-count/encoding
  contract. FITS decoding during publication callbacks would also violate owner
  and work-bound assumptions.
- **Remediation:** Keep FITS and configuration as durable instrument inputs.
  Decode and validate through a registered cold owner API before admission or
  before a bounded update is staged; keep the prepared array/packed transport
  storage in memory. Preserve explicit HDU, logical axes, target shape, element
  type, schema, byte order, units/provenance and content identity. The ndarray
  transport representation remains valid. Agree on whether the native path field
  identifies a declared FITS input or a prepared artifact reference before
  changing its semantics; preserve/version the public contract deliberately.
- **Required validation:** Non-square and rank-three axis oracles; exact known
  values before/after permutation; finite conversion, allowed float rounding,
  overflow and null/compressed-HDU rejection; aggregate memory accounting; missing
  or modified files; cancellation before and after publication; stopped submission
  versus observed running adoption. No persistent `.f32le`/`.u8` output should be
  needed in the new instrument deployment.

### RAR-05 — Source duplicate equivalence requires a v1 contract decision

- **Severity:** Low (P3), contract clarification/hardening candidate.
- **Confidence:** High in source behavior; insufficient evidence of a violated existing v1 contract.
- **Classification:** Observed aliasing behavior; defect status unconfirmed.
- **Disposition:** Proposed deferred clarification, not automatic remediation.
- **Evidence:** RTC's untracked `src/native_source_control.jl:116–133` treats the
  same `(kind, token)` as a duplicate without comparing `requested_running`.
  Lines 200–204 retain only the last kind/token. Thus Run(token, true) followed
  by Run(the same token, false) preserves the original request/outcome rather
  than emitting a conflicting-payload rejection. The current sole policy issuer
  generates fresh tokens; the source comment intentionally protects the accepted
  request from competing duplicate replies.
- **Impact:** A faulty direct native source client may misunderstand payload
  equivalence. No duplicate scientific effect or session failure was reproduced.
  The exact-payload duplicate rule for the newer cold-owner envelope must not be
  silently applied to the older scientific source v1 protocol.
- **Next action:** Establish the authoritative v1 request duplicate rule and
  consumers before changing this behavior. If exact payload equality is required,
  retain the accepted requested state and reject conflicts without overwriting
  the accepted acknowledgement. Keep monotonic tokens across Reset.
- **Required validation:** Same token/same payload, same token/opposite Run state,
  same token/different operation, both pending and committed, while preserving
  the accepted outcome and no second application.

## End-to-end trace and ownership

### Cold startup and admission

1. The one-shot installer/launcher validates the sealed deployment, exact systemd
   invocation/cgroup, paths and owner configuration. systemd starts the private
   PipeWire core and ordinary scientific owner processes. The launcher configures
   processes and does not become a session policy loop (`wireplumber_launch.jl`
   module contract; `SystemdOwners` and `SystemdUnitFiles`).
2. Julia owner bootstrap publishes Preparing before scientific construction.
   Construction remains on Julia default thread 1; a cold monitor is pinned to
   Julia thread 2, requiring `--threads=N,0`, N ≥ 2
   (`native_owner_bootstrap_runtime.jl:177–229`). Julia thread assignment does
   not itself reserve a physical CPU.
3. Owners construct/warm AOS or JFG resources while honoring cooperative
   preparation checks. JFG's wrapper calls `prepare_service_graph`, constructs a
   `FilterGraphPipeWire.PipeWireNode`, calls `prepare!`, publishes Prepared and
   waits for the exact Connect ticket (`REVOLT/assets/deployment/hil/jfg_owner.jl:5–38`).
   The simulator prepares its model and diagnostic buffers before admitting an
   exchange. No science executes on a WirePlumber callback.
4. WP waits for the exact prepared owner identities, performs Connect, discovers
   declared endpoints, validates groups and realizes declared links under the
   startup operation (`session.lua:619–784`). Stale callback results are fenced
   by operation identity, epoch, session incarnation and deadline. Owner control
   clients retain the accepted controller and stop broad registry discovery before
   entering ordinary science (`native_control_endpoint.jl:205–224`).
5. The launcher's one-shot warmup query observes readiness; placement inspection
   then checks actual thread affinity, scheduler, expected thread counts and
   locked memory. Only the invocation's exact admission controller may request
   Admit (`wireplumber_cli.jl:142–181`; `Placement.snapshot:103–132`;
   `session.lua:480–501`). A saved record is not the live admission proof.

Cold package loading, compilation, CUDA context/model preparation, FITS decode,
graph/workspace construction and report serializer warmup may allocate and do
I/O. Their costs must be budgeted independently from warmed frame execution;
moving them to an owner process does not remove CPU/cache/GC interference.

### Public control path

`one client task → native PipeWire request → WP C handoff → Lua policy → owner
native request or graph control → scientific owner boundary → native completion
→ Lua completion → client observation`.

The Julia client uses one serialized request and computes a fresh token above
all observed accepted tokens. It validates/encodes before submission, includes
the remaining budget, submits once and correlates endpoint instance, full
controller identity, token and operation. Failure after submission retires the
client; no automatic retry/rebind occurs
(`native_control_client.jl:156–159,496–586`). Matching bytes are retained so
conflicting terminal observations cannot silently replace each other.

The WP C handoff retains at most one copied request and four events, delivers
one event per idle dispatch, coalesces repeated malformed input and records the
native monotonic receipt time. That queue delay consumes the request budget
(`WP/modules/module-ao-control-endpoint.c:45–56,145–220,415–437`). Allocation and
POD copying here are bounded control-path work, not a claim of zero allocation.
Lua admits at most one pending public operation; further requests are rejected
Busy, while exact duplicates republish retained records. At most 32 controller
identities are advertised (`ao-session-control.lua:125–176,190–216`). Overflow
before semantic admission can drop a request without a token-specific completion;
the client must time out as Unknown and must not replay the possible effect.

Julia owner endpoints likewise retain one pending ticket, one terminal request,
one completion and one rejection under their ThreadLoop lock. Callbacks decode
and stage; only the serialized owner takes/applies the ticket outside that lock.
Successful completion checks the same applying ticket, live controller and
deadline; a negative terminal observation does not fabricate success
(`native_control_endpoint.jl:271–315,372–424`).

### Frame and feedback path

`simulator owner → AOS plant step → prepared frame storage → native frame stream
→ declared JFG/FGN graph → native command stream → matching command adoption
→ next model step`.

The HIL adapter owns one frame and one command in flight. The simulator invokes
`exchange_frame!` and updates its sequence only after the matching command is
adopted. Model time advances through the scientific driver; wall pacing is
separate. Source controls are applied between complete exchanges, after adoption,
not by the PipeWire callback (`REVOLT/simulator_owner.jl:509–566`;
HIL adapter `src/exchange.jl:938–999`). Atomic sequence markers and loop-locked
transport state are explicit handoffs. The adapter supplies bounded validation
and copies; JFG/AOS own the algorithms/workspaces. This review does not re-prove
the underlying FGN scheduler, every adapter publication ordering, GPU completion
semantics or scientific equations.

Start runs downstream consumers before upstream graphs, then releases the
source. Stop acknowledges source hold before stopping consumers. Reset requires
Ready, holds the source, stops graphs, obtains a new source acquisition generation
with sequence zero, then resets the graphs (`session.lua:123–177,570–607`).
Control request tokens are not reset with scientific sequence counters. Feedback
uses the declared graph/adapter mechanism; introducing an RTC scheduler would
create a new authority and is unnecessary for this migration.

### Property/parameter updates and calibration

Running property updates require writable declared scalar properties, an
advanced requested generation, matching active generation and matching value.
Float bit comparisons preserve signed zero. Stopped property updates explicitly
report submission rather than active adoption (`session.lua:290–387`;
`ao-control.lua:63–81`). Parameter publication validates graph/inlet/type/shape/
schema against declared sources, reads outside the callback lock, rechecks the
ticket before publication and reports **submitted, active_adoption=false**.
The session intentionally preserves that distinction (`session.lua:390–418`;
`native_parameter_source.jl:476–545`). A later generation/sequence observation
must establish adoption; successful file reading or buffer queueing cannot.

Calibration snapshots its plan again before Hold, preflights reply and retained
payload capacity, and sequences Hold → Adopt → Settle → Collect for each probe →
Restore → Release. It checks exact figure/cursor and clipping/quality evidence.
Cancellation is honored at completed action boundaries; it does not asynchronously
interrupt an accepted scientific operation. A known failure can attempt bounded
restoration/release; an Unknown retires the connection without another submission
(`calibration_acquisition.jl:41–62,179–255`). Domain protocol/analysis/AOC ownership
must remain in their registered packages during the packaging change. Hsm does
not by itself implement these evidence and recovery contracts.

### Quit, fault and cleanup

Normal Quit preserves source-first ordering, withdraws links, waits for owner
terminal acknowledgements, releases the issuing controller and verifies owner
client removal before declaring Offline. Bootstrap callbacks do not close the
scientific node concurrently with main: `finishing!` excludes hooks before
scientific close. The monitor retains transport until main has finished and the
terminal response is flushed/released. The repeated public quit hook handles the
race with main entering native `run!`; replacing it with a generic one-shot stop
signal without that wakeup guarantee would regress shutdown.

Fault invalidates epochs and cancels outstanding observation callbacks before
cleanup. Cancellation of a callback is not rollback of a previously submitted
effect. Unknown source hold disconnects the session and relies on the retained
systemd emergency cleanup path. Cleanup verifies retained invocation/PID/cgroup
identity, sweeps late jobs and units and removes owned unit fragments; it does
not adopt replacement processes. RTC `wireplumber_session_runtime.jl:588–635`
explicitly separates reconciliation after Unknown from successful native Quit.
This is a useful behavior to preserve.

## Capacity, scheduling and measurement contract

| Boundary | Observed bound/owner | Remaining performance or resource obligation |
| --- | --- | --- |
| Public WP ingress | One request/four native handoff events; one Lua operation; 32 controllers; 16 KiB native input bound | No measured burst/service-rate or rejection latency contract; overflow is observable but request-specific completion is not guaranteed before admission |
| Julia native endpoint | One pending ticket and retained terminal records; bounded codecs; ThreadLoop lock | Decode/copy, lock waiting, publication and GC interfere with cold control latency; no measured tail bound |
| Scientific source mailbox | One accepted scalar request and one rejection slot; owner applies between exchanges | A stop request waits for current adoption; additional rejects may have no completion promise; quantify complete-exchange plus reporting/cleanup bound |
| Frame feedback | Exactly one frame/command in flight, prepared transport storage | Complete exchange service time includes plant/GPU, graph, copies and wakeups; native wait timeouts are not hard end-to-end deadlines |
| Parameter source | 1–32 declarations; aggregate packed payload ≤512 MiB; one publication state per source; two proposed native buffers per source | 512 MiB is a payload bound, not RSS: Julia arrays, native buffers, owner arrays and simultaneous old/new artifacts contribute more; file-read checks do not preempt blocked kernel I/O |
| Calibration plan | ≤16384 probes; reply dimension preflight; conservative retained-payload charge ≤512 MiB | JSON/POD/array/object overhead, analysis matrices, report serialization and restoration work need separate memory/time accounting |
| Retained diagnostics | Fixed prefix; continuous truth uses a 512-sample circular window | Diagnostics still cost owner CPU/GPU/GC and must be included or explicitly excluded by the selected performance cohort |
| Duration histograms | Three 100001-bin UInt64 arrays, fixed 10 μs bins through 1 s | ≈2.4 MB of raw counters; counts/maxima/overflow retained. Quantile precision and population are explicit; changing storage must preserve or version report semantics |
| Bootstrap monitor | Julia thread 2; 5 ms `gc_safe` usleep plus yield | Finite polling cadence is not bounded scheduling delay; native blocking hooks and main-thread progress still matter |
| Placement | Explicit CPU exclusion, affinity/scheduler/thread-count/memlock inspection | SMT, NUMA first-touch, interrupts, page backing, shared GPU contention and aggregate runnable demand require cohort-specific evidence |

The demonstrated Classic workflow used 10 Hz wall pacing and a retained prefix
of 16 frames. That does not alter the model period and is not evidence of a
10 Hz latency guarantee or target-rate capacity. The unpaced owner is completion
driven; paced operation skips missed periods and does not issue catch-up bursts.
With one exchange resident, throughput is constrained by complete exchange
service time (L = λW, L ≤ 1 for this closed loop); its latency distribution cannot
qualify an independently arriving camera workload.

Neither the source inspection nor the existing walkthrough supplies a complete
arrival/burst contract, accepted p99/p99.9/max target, core/NUMA/IRQ budget,
worst-case owner work, or overload recovery qualification for the new package
cohort. Existing measurements remain valid only for their recorded versions,
backend, diagnostics and warmup boundaries. No new zero-allocation claim is made.

## Candidate library decisions

These decisions concern actual source/API fit. “Yes” means a useful scoped
integration candidate, not permission to add dependencies during this review.

| Library / inspected version | Decision and concrete fit | Constraints, cost and validation |
| --- | --- | --- |
| **HdrHistogram 0.4.1**, `184f4ed5d62749a59f2bd361932b24b047530db9`, clean | **Yes, scoped diagnostics reuse.** `Histogram(lowest, highest, significant_figures)`, `record_value!`, percentile/equivalent-range queries and post-stop aggregation can replace the local duration bucket mechanics in REVOLT `assets/deployment/hil/sustained_metrics.jl:5–39,190–213`. Keep instrument-specific sequence, unit, clipping, threshold and arrival diagnostics outside the generic histogram. | Fixed three-argument constructor sets `auto_resize=false` (`src/histogram.jl:143–161`); one-argument constructor auto-resizes. Plain Histogram is mutable, not synchronized: one owner writes, query/reset after quiescence, or transfer immutable snapshots through an explicitly bounded handoff. Do not share it with a GUI reader. Preserve exact overflow/min/max/threshold counts and warmup population; HDR relative bucket intervals differ from the existing fixed 10 μs report. Atomix/CodecZlib are runtime deps; Plots is an optional extension and need not enter deployed owners. Measure the integrated path before claiming zero allocation or reduced latency. |
| **Hsm 0.3.1**, committed baseline `bb00ed87a0cd67c65e9198d028c5ff921678f825` | **Defer owner-local use; no session rewrite.** `@hsmdef`, static states/edges, `dispatch!`, entry/exit/effect handlers and guarded run-to-completion can express a sufficiently complex single-owner calibration or bootstrap protocol if a separate design demonstrates reduced complexity. | Reentrant dispatch protection is not cross-thread mutual exclusion or an event queue. A machine needs one dispatch owner. Effects must hand off and later deliver completion events, preserving token/deadline/Unknown checks. Running it alongside Lua as another session coordinator violates RTC-ARCH-025. Runtime dep ValSplit and new specializations add cold compile cost. Working source/SEMANTICS/macros/tests contain substantial uncommitted region work beyond the documented released subset: pin an admitted release, do not infer released API/qualification from dirty source. No demonstrated need to replace the short current state loops now. |
| **Clocks 0.4.0**, `f3d3777b0611adb28a1e54245e5857ad74d708a8`, clean | **Defer broad migration; yes for a narrow injectable clock boundary when deadline testing is implemented.** `AbstractNanoClock`, `SystemNanoClock`, `time_nanos`, and explicitly owned `CachedNanoClock` provide typed monotonic clocks. | No runtime dependencies. Existing `time_ns()/1e9` helpers are adequate for current control granularity; no precision defect was established. Do not substitute epoch clocks for deadlines or compare arbitrary-origin clocks across processes. Cached clocks must be advanced by one owner and can freeze if that owner stalls. `OffsetEpochNanoClock` has a resampling lock/retry path and is unsuitable as an unexamined deadline hot-path replacement. Preserve remaining-budget wire semantics. |
| **Agent 0.4.1**, `71e3af4e5c112f0433e03d57a570bc74ffd05ccc`, clean | **Defer monitor refactor; limited fit for an owner duty loop.** `do_work`, `on_start`, `on_close`, `AgentRunner`, `start_on_thread(runner,2)` and `request_stop!` could replace ordinary loop plumbing. | It owns a task, not PipeWire or systemd/session authority. `start` may migrate; sticky placement is explicit. `close(runner,retry_wait; on_stall)` repeats waits and is not an absolute overall shutdown deadline (`src/agentrunner.jl:180–240,315–353`). A blocked `do_work` needs an explicit wakeup, and errors must retain the RTC's fault semantics. StableTasks is required, ThreadPinning optional. Do not substitute default sleep/backoff without proving progress while thread 1 runs native code; retain GC safepoints and bounded cleanup behavior. |
| **StaticKV 0.7.0**, `56ae4148d3e8bd8717d864fbd20c4ebe6817ecec`, clean | **No current need.** Static property records may suit other typed owner APIs, but existing protocol structs and native Props declarations already express this RTC's fields. | Generated `value!` uses ordinary `setfield!` for value/timestamp (`src/StaticKV.jl:880–888`), not transactional publication or concurrency protection. It does not implement POD validation, incarnation checks or adoption. Clocks compat is `0.2`, incompatible with proposed Clocks 0.4; MacroTools adds compile machinery. Do not replace cold configuration dictionaries solely to obtain advertised warmed lookup speed. |
| **RtcFramework 0.1.11**, `09a5e4ac0dda4132bfc7934d126c20800e616f30` | **No for this architecture.** `BaseRtcAgent` combines Hsm lifecycle, Aeron communications/adapters/proxies, properties, counters and timers (`src/agent.jl:1–73`). That is a broader control framework than the selected native PipeWire/WirePlumber boundary. | Would add competing lifecycle/message infrastructure and substantial dependencies. Compat pins Agent 0.3, Clocks 0.2, Hsm 0.1 and SnowflakeId 0.1, excluding the newer candidates above. `PolledTimer` is a sorted vector with initial `sizehint!(100)` and unbounded `insert!`, not a capacity-enforced timer wheel (`src/Timers/polledtimer.jl:28–87`). Do not import the framework to reuse one timer/helper. An untracked `spiders.xml` was present; no production source edits made. |
| **SnowflakeId 0.2.0**, `6e7c844f0330bc27d66bf682384d192f23678f87`, clean | **No for native request tokens.** `SnowflakeIdGenerator`/`next_id` target distributed IDs; present local protocol already combines endpoint/controller incarnation with monotonic token ordering. | Epoch clock, configured node identity and sequence exhaustion behavior add requirements without replacing incarnation proof. `next_id` busy-spins when per-millisecond sequence space is exhausted (`src/SnowflakeId.jl:136–152`); clock rollback is an explicit concern. Clocks compat 0.3/0.4. Keep standard UUID/session identities and existing protocol counters unless a distributed identity requirement is introduced. |
| **TimerWheels** | **Defer; no applicable Julia package located** in searched workspace/package paths. | No source/API/version claim. Existing WP GLib timers belong to the sole Lua session authority; the Julia owners have few explicit deadlines and need no new timer service. RtcFramework's PolledTimer and Java Agrona DeadlineTimerWheel are not a verified Julia TimerWheels API. |

HdrHistogram integration should begin with a private fixed histogram per metrics
owner and cold output after stop. If interactive sampling becomes necessary,
evaluate `SingleWriterRecorder` with compatible recycled interval histograms and
its phaser protocol. `Recorder(Histogram(...))` serializes writers with a lock;
the default `Recorder(lowest,highest,digits)` instead uses AtomicHistogram.
Interval sampling may allocate replacement storage, and resizing, decoding,
encoding, compression and plotting remain cold work. Concurrent recording does
not make all concurrent reads a stable snapshot. None of these options warrants
adding work to the PipeWire frame callback.

Do not apply coordinated-omission correction mechanically to this completion-
driven loop. Preserve observed latency/source-interval/missed-period populations;
if a new externally paced experiment requires corrected estimates, state its
arrival model and report corrected and measured distributions distinctly.

No current requirement justifies importing Aeron, Liburing, Zarr or a new message
bus/storage stack into this refactor. This is a scope decision, not an assessment
that those libraries lack useful APIs. Future durable recording or independent
arrival requirements would need their own ownership, capacity and failure design.

## Required acceptance sequence

1. Adjudicate RAR-01 and preserve its negative/positive behavior oracle before
   touching protocol organization. Keep RAR-05 a contract question until its v1
   authority is established.
2. Capture CTW-01/02 phase evidence in an isolated owned deployment; separate
   cold/warm compilation, scientific work, transport handoff and cleanup. Do not
   infer a fix from a renamed package or a longer timeout.
3. Introduce registered-package owner entrypoints and in-memory FITS preparation
   with explicit peak-memory/cancellation/adoption contracts. Retain algorithm
   and native protocol semantics; measure cold preparation and startup separately.
4. Evaluate the concrete HdrHistogram replacement under the existing metrics
   owner. Retain a known distribution oracle, exact overflow/threshold counts,
   reset/warmup behavior and report compatibility. Compare memory and integrated
   cost; do not add concurrent recorders unless the actual reader model requires it.
5. Run affected pure protocol/owner tests, then an isolated native lifecycle,
   graph property/parameter adoption and calibration recovery suite. Final
   target-host resource/latency and hardware validation remain separate gates.

The rename itself should preserve authority, wire identities and failure
semantics. A new Hsm coordinator, Agent supervisor, global histogram task or
timer framework is not required to make that rename or the FITS-only deployment
design coherent.
