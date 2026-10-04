# Immediate execution-group restart review

## Scope and baseline

Independent read-only review of RTC issue 1 at commit
`2f62fd582be3a6e0b5fc2dcb7af4a7b77426d698`, worktree
`pipewireao-rtc-ui-restart`. The worktree was clean when inspected. The reviewer
owns this document only; the implementation worker owns the exclusive live
window. No sessions, production changes or sibling edits were made for this
review. The low-latency design review skill informed the ownership and progress
analysis. Authorities: RTC-DEV-003, RTC-DEV-004, RTC-DEV-011, RTC-DEV-012 and
RTC-DEV-022 in the active operations specification.

## UIR-1 — Cached sink observations falsely fail immediate group restart

**Severity:** High functional lifecycle defect.
**Confidence:** Confirmed false-progress observation from cached sink Props.
**Disposition:** Closed by the narrow RTC sink-cache repair and unchanged
Classic/Copper live regressions. See UIR-3 and final verification below.

Fresh runner SHA-256
`3b3234f1a68f1f3218317f146d5afc3ed253cf6611c4c2d9f0878e412952597e`
fails the GUI lifecycle sequence for both Classic and Copper. Evidence is in
`/tmp/pipewireao-gui-rtc-evidence-pnytgt28/` and
`/tmp/pipewireao-gui-rtc-evidence-vv_7_jul/` (`result.json` and
`client-failure.log`). These are RTC-owned looping FITS sources at 10/1,
complete-frame native FGN graphs and ordinary discard sinks. They are not the
externally held AOS source profile.

The Classic log shows initial Running, group stop acknowledged Stopped while
the session stays Running, and group restart entering Fault. The retained
runner diagnostic is `command-discard remained at 2 after 2 process calls`.
The owner CLI property checks pass for both engines, but they first publish a
reconstructor parameter and perform additional control operations; the worker
reports group stop at count 8 or later. This comparison changes both parameter
traffic and processing history. It cannot identify a parameter-route cause.

### Source reconstruction

`src/live.rs:start_execution_group` reads a live sink-counter baseline, requests
owner-mediated Running in reverse graph order, starts any latest/hold nodes,
then requires a strictly later buffer at each selected sink. The latter wait
has a five-second bound. The failure diagnostic occurs after the run-control
acknowledgement gate, rather than being a timeout waiting for the owner token.
`graph_reached_requested_state` checks the exact requested token, result and
state and rejects conflicting or future statuses.

`stop_execution_group` pauses latest/hold nodes, requests owner-mediated
Stopped, and samples sink quiescence three times at 5 ms spacing within 500 ms.
At 10 Hz these samples alone are not a full frame-period drain witness; the
owner Stopped acknowledgement is also load-bearing. No violation of that owner
contract has yet been demonstrated. Objects and links are retained.

Session start additionally checks active links and triggers pending parameter
publishers. Group start omits those calls. That asymmetry is observed source,
not proof that either call is required to repair this failure. In particular,
the preload-only failing fixture has no initial session parameter publication.
Adding a synthetic parameter publication or rebuilding links would change the
experiment and could conceal the transport defect.

The native FGN owner's run-control path uses public filter activation and
publishes completion after its corresponding processing state. A process cycle
requires every non-optional input and every output buffer. Thus Running and
later buffer delivery are separate conditions. The existing later-buffer gate
is required by RTC-DEV-011 and must remain strict.

## UIR-2 — Existing observations do not locate the first lost progress

**Severity:** Investigation prerequisite.
**Confidence:** Confirmed observation limitation.
**Disposition:** Bounded tests recommended to the implementation worker.

GUI Status reports the adapter's cached discard counters. Repeated displayed
count 2 therefore does not independently demonstrate fresh source or sink
progress before stop. The failure path does obtain fresh sink counters and
process-call counts. First distinguish a source/transport stall already present
after startup from one caused by group stop/restart.

Recommended order, preserving the same fixture, source, buffers and deadlines:

1. Without a parameter write or stop, sample the public sink Props counter
   until count 8 or a finite five-second bound. Record source, graph and link
   public states. A stall here localizes the defect before restart.
2. If ordinary progress continues, stop at observed count 8 and restart.
   Compare with the already failing immediate count-2 sequence. This separates
   early-cycle sensitivity from the presence of parameter publication.
3. Only then test one equal-value parameter publication, with the same
   observed stop-count criterion. Preserve parameter requested/active
   generations. A changed result is evidence of an activation/topology or
   scheduling perturbation, not by itself a scientific-parameter cause.
4. Capture the run-control token/state, public link states, sink buffer and
   process-call counters at pre-stop, acknowledged Stopped and acknowledged
   Running. Acquire the last snapshot during the progress wait, before Fault
   cleanup can change the topology.

The worker's source observation that the FITS timer finds HAVE_DATA and does
not emit another ready callback is a useful transport hypothesis. Discriminate
whether the published buffer is legitimately outstanding, has been consumed
without ownership return, or is not scheduled after activation. If public
snapshots cannot expose that boundary, a separately authorized diagnostic trace
should correlate publication, consumer dequeue, return and ready notification
for the same buffer; timer activity alone cannot establish buffer ownership.
Do not clear HAVE_DATA, resend a published buffer, alter gains or relax the
later-delivery check without the corresponding ownership evidence.

Required acceptance remains an unchanged immediate stop/start sequence passing
for both maintained profiles, preserved nodes/links and algorithm state,
later sink delivery, other-group progress where applicable, and public cleanup.
Software lifecycle evidence does not establish cadence or hardware behavior.

### Initial discriminator interpretation — later corrected

The worker completed the no-write/no-stop observation in
`/tmp/rtc-ui-restart-issue-1-20261003/owner-probe-classic-c705e13b2eb0/`.
The reviewer independently inspected `before-stop-dump.json` and
`before-stop-later-dump.json`: both contain discard buffer count 3 and process
count 3, while recorded source, parameter source, FGN graph and discard sink
all report Running. The worker records one second between snapshots. There
were no scalar/parameter writes or intervening stop. The source's public
completed property is false. This was initially interpreted as an already stalled pipeline before restart.
That inference is retracted by the sink trace and cache discriminator below:
these public counter reads were served from a cache and did not demonstrate
actual processing quiescence or a lost buffer/ready event.
The worker subsequently observed stop and restart failure and cleaned the
owned session. Source loan/status tracing remains investigative; no production
remedy is established by these snapshots alone.

### Source-publication discriminator and downstream trace plan

The reviewer inspected
`owner-probe-classic-fd2892b3a01f/source-debugger.log` under the same issue cache.
It records repeated FITS `process_source` returns of HAVE_DATA (2), matching
core `node_ready` returns of 0, and subsequent source calls returning 0 while
producer buffers return to AVAILABLE. The worker observed more than 40 source
sequences while the sink stayed at three buffers/process calls. This contradicts
source-pool exhaustion and a persistent source HAVE_DATA loan as explanations
of this traced stall. Successful ready return is not evidence that every target
actually ran.

The next bounded trace should distinguish these stages:

| Stage | Concrete observation | Discriminating conclusion |
| --- | --- | --- |
| Native module process entry | Count calls to `module-ndarray-filter-chain.c:process` in the RTC process | If absent while source publishes, investigate activation and client delivery before scientific processing |
| Native module readiness | Record process-failed flag, each ordinary input presence, cached/dequeued output presence and final `ready` | Repeated callbacks with `ready=false` distinguish missing input from output-buffer starvation |
| Scientific call | Record `spa_fgn_graph_process` entry and return, preserving exact input identity | Separates no call from algorithm/host failure; do not alter coefficients |
| Output publication | Record nonzero chunk size, `pw_filter_queue_buffer` result and matching returned buffer | Separates retained/empty output, published output and missing downstream return |
| Sink delivery | Correlate public sink process/buffer counts with those publications | Locates the remaining downstream loss without relying on cached GUI status |

`LiveAdapter::load_owned_module` loads the FGN module into the runner's context.
A debugger attached only to the private core therefore does not observe its
scientific process callback. The reviewed module skips parameter ports in its
ordinary-input readiness test: it invokes `dequeue_parameter` and continues.
An absent parameter payload cannot directly make that local `ready` Boolean
false. It can still affect graph scheduling upstream of the callback, which
remains to be measured. Startup parameter adoption is already reported active
in the public pre-stop snapshots.

If callback entry is absent, follow source-target activation through the
scheduled graph proxy and runner-side filter process: target dependency
pending/required values, active driver, activation transition and wake event,
then runner-side process entry. Public Running states alone do not expose these
steps. The installed core lacks debug information and its Build ID differs
from the worker's local debug build. Do not apply that other build's private
layouts or symbols. Use matching symbols or existing bounded diagnostics; any
new native instrumentation requires the parent's explicit cross-repository
scope decision. The local native source inspection supplies candidate trace
points, not proof of the installed binary's private state.

No production remedy is approved by this review. In particular, neither a
parameter write, an extra source pulse nor resetting buffer status is justified
as a repair before ownership and activation traces identify the missing event.


## UIR-3 — Confirmed discard Props cache mechanism and scoped repair

**Severity:** High lifecycle observation defect.
**Confidence:** Confirmed by source, installed-function trace and control case.
**Disposition:** Closed; source repair and unchanged paired live regressions
independently verified below.

The reviewer independently counted 50 `DISCARD_PROCESS` entries and 50 returns
of 1, with zero `DISCARD_ENUM` entries, in
`owner-probe-classic-6dcf57a02456/core-debugger.log`. The worker attached to exact
installed symbol addresses without applying a different build's private
layouts. The counter-based restart test still entered Fault. In the matched
no-topology-read control case `owner-probe-classic-a44bc4e7680b/result.json`,
ordinary CLI stop/start succeeds and the observed sink count advances 2→3.

The public topology dump broadly enumerates Props. Core parameter enumeration
caches an unfiltered complete enumeration when `node.cache-params` is enabled
(the default). Once the cache is marked populated, even the runner's later
narrow Props queries are answered from it, without calling the discard SPA
implementation. The discard sink's continuously changing metrics do not
invalidate this cached snapshot. Thus the restart's required later-buffer
check repeatedly sees the old count and falsely faults despite ongoing sink
processing. Parameter publication and the sparse parameter route were
confounded hypotheses; the no-route fixture also failed and neither is needed
to explain the cached observation.

This evidence **retracts the earlier claim that unchanged public dump counts
proved a pre-stop transport stall**. Both the core cache and the adapter's
ordinary cached Status must be distinguished from an actual process witness.
Successful sink callbacks do not by themselves reconstruct every payload, but
the trace directly demonstrates that the public counter polls were not asking
the live sink implementation. No generic PipeWire scheduler, buffer-loan or
scientific algorithm defect has been established.

The reviewed `src/live.rs` patch adds `node.cache-params=false` only when creating
the RTC-owned discard sink, matching the existing latest/hold observation
pattern. The property is established before node creation, so a broad observer
cannot populate that stale cache first. Allowed sink arguments cannot override
it: endpoint admission permits only the loop-placement property. The patch
changes no source timing, scientific coefficients, topology, lifecycle token or
later-buffer acceptance condition and requires no generic native change.

Required final evidence: rerun the unchanged immediate GUI topology-read →
group stop/start scenario for Classic and Copper with the patched runner;
verify later sink counts, retained node/link identities, session stop/start and
public cleanup. Keep failed traces and the no-dump discriminator. These remain
functional lifecycle checks, not timing or physical-system qualification.


## Final verification and issue-closure scope

The reviewer verified the unchanged two-line `src/live.rs` patch and its saved
patch hash `9052b6294d1617c2f013815a8458e6d01b00f922cc59e03360e0a75118507392`.
The patched runner SHA-256 is
`7b37da2f558ae37f3139aa6db58ead7f8950dee38508003decb53e747b85b47f`.
All 34 installed Classic/Copper package artifact hashes checked successfully.
The production artifact change is confined to the runner; no calibration,
scientific graph or coefficient change accompanies the fix.

The public topology-read discriminator
`owner-probe-classic-2cac39b3b58b` now reports actual counters 3→13 before stop,
13 while stopped, 14 immediately after restart and 23 at the later snapshot.
These observations retain the same strict later-buffer gate that previously
faulted on cached observations.

The unchanged GUI scenarios pass:

| Profile | Scenario | Evidence directory under `/tmp` |
| --- | --- | --- |
| Classic | Updates | `pipewireao-gui-rtc-evidence-ql042g8f` |
| Classic | Lifecycle | `pipewireao-gui-rtc-evidence-lw45_olq` |
| Copper | Updates | `pipewireao-gui-rtc-evidence-6o6fxzh4` |
| Copper | Lifecycle | `pipewireao-gui-rtc-evidence-jlh6ivyj` |

For all four the reviewer independently verified `passed`, package preservation,
all eight topology object IDs and serials unchanged, successful cleanup records,
absent runtime directories and recorded PIDs, and current inactive systemd unit
state. Logs retain group stop/start, session stop/start, and the distinction
between stopped property submission and later active adoption. Both maintained
owner CLI checks also report successful completion with the fixed runner.

The companion GUI harness change handles an already inactive/failed owned unit,
or a collected unit racing the stop request, during cleanup. It rethrows stop
errors when the unit remains active and leaves runtime-removal and scenario
success checks intact. Three targeted tests cover those branches. It does not
weaken the GUI lifecycle or property-adoption assertions. The reviewer inspected
this diff and the final RTC test/Clippy logs. The RTC private-core integration
case is explicitly ignored in the generic test run; actual installed scenario
results supply the live evidence here. Clippy retains an upstream
`proc-macro-error2` future-incompatibility notice, not a new fix-specific failure.

**Disposition:** Merge and issue closure cleared for the maintained recorded-input
Classic/Copper native FGN lifecycle/UI functional boundary. UIR-1 and UIR-3 are
closed; UIR-2's stale-observation limitation is resolved and the earlier false
transport-stall inference remains explicitly retracted. No generic native
scheduler change, JFG/HEART extension, cadence qualification, physical or
scientific acceptance follows from these results. The reviewer ran no live
session and changed only this document.

The final `evidence-sha256.json` inventory was independently rehashed: all 43
entries match, including preserved fail-before/pass-after binaries, tested
source, traces, package provenance and validation records. RTC cold tests
report 133 passed and three explicitly ignored cases. The saved source and
binaries preserve tested identities independently of later rebuilds.
