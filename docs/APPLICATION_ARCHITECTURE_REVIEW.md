# Application architecture adversarial review

2026-10-06. Review baseline: RTC `a63dd6d`. Dedicated branch
`review/application-architecture-20261006`, initially clean, in
`/tmp/rtc-architecture-review-20261006`. Source inspection only: no builds,
runtime tests, benchmarks, host tuning or service changes were performed.

Status: consensus reached after two adversarial rounds; accepted findings and
scope corrections are incorporated below.
This is review evidence, not implementation or a new operational acceptance claim.

## Question and conclusion

Can the RTC workstation reuse systemd and WirePlumber while retaining a headless
scientific lifecycle owner, optional GUI/CLI clients, FGN/JFG execution, optional
AOS simulation and AOC calibration?

The division is plausible and worth a small compatibility pilot. The main risk
is transferring lifecycle-sensitive objects between owners. Removing local
link/process code creates distributed obligations; fewer Rust lines alone do
not establish simpler operation. No current WirePlumber integration failure or
deadline violation was demonstrated in this review.

Keep JFG as a separate Julia process. `module-rt` supplies scheduling support,
not application launch or automatic placement of every executor worker.
`pw-module-client` can host native FGN in WirePlumber's separate client context,
but shares the WirePlumber process. Retain established FGN hosting for the first
pilot; evaluate WirePlumber hosting as a separate deployment choice.

## Contract and review boundary

The existing [operating contract](operations.md) remains authoritative:

- RTC-DEV-021: held ingress, exact current-owner readiness, verified placement,
  admission revocation on required-owner loss and fresh dependent-set validation.
- RTC-DEV-022/030: one lifecycle dispatcher, bounded native controls, finite
  deadlines and submission distinct from active adoption. Client disconnection
  neither rolls back an accepted operation nor authorizes automatic retry.
- RTC-DEV-019/020: retain declared full-frame/row profiles and scientific
  contracts; distinguish exact delivery, numerical behavior and latency evidence.

Pixel ingress to DM egress remains the data-path boundary. Progressive evaluation
also needs first-row/first-packet and terminal-row/terminal-packet to command
measurements. Rates, bursts, allowed loss, maximum command age, CPU budgets and
tail targets must be specified per profile before a real-time acceptance claim.
This review supplies no universal numerical deadline.

The source-derived critical path is instrument/source → negotiated PipeWire
buffers → processing callback → FGN helpers or JFG shards where enabled →
completion join → output command. AOS's existing complete-frame HIL exchange is
one frame/command in flight; it does not independently offer camera traffic.

Discovery, lifecycle, artifact preparation and observation are control work.
Their separate execution contexts do not remove shared memory/runtime/resource
interference or the need for bounded failure detection. Physical authority,
durable recording and remote control remain outside this selected scope.

## Strengths agreed in the initial reviews

1. **One scientific lifecycle owner.** The headless runtime admits acquisition
   and coordinates reset and adoption. GUI and CLI clients can disconnect without
   becoming required scientific dependencies.
2. **Reusable scientific boundaries.** FGN/JFG are ordinary typed processing
   nodes; AOS is an instrument endpoint provider and AOC supplies numerical methods.
   Discovery does not need to understand MVM, centroid or optical equations.
3. **Existing readiness and control foundations.** The implementation already
   holds sources, verifies native owner identities, inspects thread placement,
   serializes controls and distinguishes submission from adoption.
4. **Separate Julia and simulation processes.** JFG and AOS keep useful runtime,
   resource and failure boundaries. CUDA/AMDGPU simulation does not force a GPU RTC.
5. **Existing frameworks are suitable candidates.** WirePlumber offers objects,
   links, profiles and hooks; systemd offers supervision and limits. Their use
   is conditional on preserving existing scientific semantics.

The DAW analogy applies to project editing, patch visibility and operator
controls. It does not imply automatic instrument rerouting, unrestricted live
topology edits or that an active graph establishes scientific admission. Existing
stop/reload topology semantics remain authoritative. The selected initial-calibration
session excludes the correction command producer (`architecture.md:548`); client
access does not authorize a second competing producer in that session.

## Findings and disposition

Severity describes the consequence of an unaddressed migration/qualification
gap, not a proven defect in today's selected deployment. Confidence applies to
the cited mechanism; timing magnitudes remain unmeasured.

### AAR-01 — Link transfer changes runtime-loss cleanup

**High; high confidence. Observed mechanism, derived migration risk.**
`src/live.rs:2194` deliberately drops non-lingering RTC-owned link proxies so
their server resources disappear. WirePlumber-owned proxies would instead have
WirePlumber's lifetime. The current source-aware shutdown is in
`deployment/julia/src/deploy.jl:956`.

**Disposition:** migration blocker until runtime loss, WirePlumber loss, core
loss and lost source control have explicit link/ingress dispositions. Preserve
the existing fail-and-readmit behavior. Existing exact control-node incarnation
and removal events may suffice; no new distributed framework is prescribed.

**Validation:** terminate each required owner during preparation and acquisition;
measure admission revocation/source disposition and link cleanup. A surviving
session manager must not continue or reconstruct the admitted session silently.
This establishes development-session behavior, not physical fail-safe operation.

### AAR-02 — Asynchronous realization needs an exact admission contract

**High; high confidence. Observed missing interface, derived stale-state risk.**
The runtime/WirePlumber interface is explicitly unselected in
[integration](ECOSYSTEM_INTEGRATION.md#control-and-deployment). Current realization
is retained by the runner (`src/live.rs:1313`), while start validates owned
topology and usable links (`src/live.rs:1321`, `src/live.rs:2107`).

**Disposition:** before ownership transfer, specify exact runtime/endpoint
incarnations, desired and actual link sets, finite admission deadlines,
withdrawal and rejection of delayed observations. Reuse suitable existing
WirePlumber mechanisms; native serialization alone does not establish these
semantics. The runtime continues to judge scientific readiness.

**Validation:** withdraw a pending realization, replace an endpoint under the
same name, restart WirePlumber and delay events. An old successful observation
must not release a new source. Include concurrent GUI/CLI requests and ambiguous
client timeouts without duplicate effects or automatic mutation replay.
Delay a policy hook or realization observer and verify finite admission failure
without source release. WirePlumber documents non-preemptive main-loop hooks
(`src/config/wireplumber.conf:193`); frame-loop separation does not establish
control-path responsiveness.

### AAR-03 — systemd transfer must preserve the session failure cohort

**High; high confidence. Observed differences, derived recovery risk.**
RTC's unit uses `Type=notify` and `Restart=no`
(`deployment/pipewireao-rtc@.service.in:5`, `:18`). Stock WirePlumber units use
`Type=simple`, `Restart=on-failure` and bind the desktop core. Current deployment
creates fresh owner identities, holds sources, checks placement and only then
publishes readiness (`deployment/julia/src/deploy.jl:1250`, `:1310`, `:1353`).

**Disposition:** migration blocker until independent units preserve required-owner
failure handling, held startup, bounded teardown and fresh readmission. Distinguish
process restart from permission to resume acquisition. Preserve native identity
checks; a PID, active unit, socket or saved marker is insufficient. User units
must not elevate the entire Julia/control process to FIFO.

**Validation:** required-process exit, runtime exit with surviving owners, core
replacement, stale discovery, manual restart and duplicate names. Verify inherited
rights, cleanup of the owned set and absence of automatic RUNNING/mutation replay.

### AAR-04 — Link ordering and passive semantics must survive

**High; high confidence. Observed negotiation behavior, derived migration risk.**
`src/live.rs:1276` documents downstream-first realization with an exception:
latest/hold ingress needs its input pool before output aliases can be allocated.
`src/live.rs:3322` validates passive-link realization. Final endpoint matching
alone does not preserve these dependencies or execution-group behavior.

**Disposition:** preserve explicit negotiation/order/passive requirements without
moving scientific algorithms into connection policy. A simple source-to-sink
pilot covers only the generic compatibility step. Latest/hold remains a separate
declared feature; it is not automatically added to Classic/Copper profiles.

**Validation:** selected full-frame/row graphs, stopped passive branches, failed
intermediate link and teardown/retry; latest/hold and pool replacement only for
profiles claiming those capabilities.

### AAR-05 — Scheduling support is not complete worker placement

**High for enabled parallel/spinning profiles; high confidence about mechanism.**
PipeWire's data loop requests RT scheduling (`pipewire/src/pipewire/data-loop.c:347`);
module-rt responds through thread-utils acquisition (`src/modules/module-rt.c:827`).
FGN helpers use plain `pthread_create` and poll for work
(`spa/plugins/filter-graph/ndarray-executor.c:564`, `:113`). JFG has distinct
Julia shard tasks and adopted native callback threads. The current launcher
checks effective per-thread settings before ingress (`deployment/julia/src/deploy.jl:1357`,
`deployment/julia/src/placement.jl:103`); those checks are not absent.

**Disposition:** preserve placement admission through migration and identify
coordinator, helper/shard, parameter and background roles explicitly. Rights
limits permit scheduling/locking; they do not apply it. Hosted and newly created
workers need their own coverage. Busy polling requires reserved CPU capacity.

**Validation:** inspect actual TIDs/policies/affinities after activation and
restart. Reject misplaced/unexpected critical workers and unavailable rights.
Exercise a delayed helper on isolated test resources. Serial profiles are not
automatically affected, and this review proves no current placement failure.

### AAR-06 — JFG control preparation can interfere through its runtime

**Medium; high confidence about mechanism, unmeasured tail impact.**
`PipeWireAO.jl/src/ndarray_filter.jl:243` permits allocation/blocking in parameter
callbacks while processing runs. JFG prepares replacements in the same Julia
process (`julia/FilterGraphPipeWire/src/graph_node.jl:975`) and worker waits call
`GC.safepoint()` (`julia/JuliaFilterGraph/src/cpu_progressive_graph.jl:339`).

**Disposition:** retain GC correctness and existing warmed adoption paths.
Declare allowed live operations and bounded request sizes/rates. A zero-allocation
frame path does not establish zero runtime interference from cold preparation.
Do not disable GC or introduce a helper process without discriminating evidence.

**Validation:** identical scientific inputs with/without representative operations
and reconnects that reach the scientific owner; separately apply client-only
observation load. Correlate JFG latency with JFG GC/JIT and shared CPU contention.
Preserve existing scoped live-update results. This finding
is not evidence that current frame processing allocates or misses deadlines.

### AAR-07 — FGN hosting inside WirePlumber changes the failure domain

**Medium; high confidence. Observed process topology, derived coupling.**
WirePlumber's `pw-module-client` loader is in
`lib/wp/private/internal-comp-loader.c:995`. Its client context is on a separate
thread within the same process (`src/config/wireplumber.conf:187`). It protects
media objects from long main-loop hooks; it does not provide process isolation.

**Disposition:** retain established FGN hosting for the first pilot. Treat
WirePlumber-hosted FGN as an optional separately qualified deployment profile,
with a shared process failure/resource domain. No new native-host executable
is required by this recommendation. Keep JFG external; Julia embedding adds
unnecessary runtime lifetime/unload obligations for the selected direction.

**Validation:** host/policy failure, module unload/reload and actual resource
placement. WirePlumber process/client-context restart or hosted-module unload
invalidates hosted graph state and requires fresh preparation/admission. A
policy-only component reload requires session revalidation; it does not
necessarily destroy the hosted scientific graph.

### AAR-08 — Buffer bounds and lockstep HIL do not qualify command age

**Medium architecture gate; high priority before progressive real-time claims.**
JFG waits for shard completion (`cpu_progressive_graph.jl:417`, `:636`), and
FGN has a synchronous worker join (`ndarray-executor.c:200`). Negotiated pools
bound storage, not completion time. AOS's one-exchange lockstep reduces offered
load when processing slows. These are observed mechanisms, not newly discovered
deadline violations or a withdrawal of earlier independently paced RTC evidence.

**Disposition:** qualification gate, not a blocker to the small functional pilot.
Specify offered arrival/readout pattern, acceptable command age, whole-frame
loss/rejection, ordering, overload and recovery. Preserve loan/workspace ownership;
do not abandon worker storage using a speculative timeout.

**Validation:** independently paced ingress, row bursts, delayed shards and stalled
sinks; record original identities, age, exact delivery, first/terminal ingress
latency and recovery. Keep lockstep HIL for scientific/lifecycle verification.

### AAR-09 — Minimal reuse requires a narrow profile and native control fit

**Medium; high confidence about upstream facilities, compatibility untested.**
Stock WirePlumber linking policy includes default/best target and audio-specific
hooks (`src/config/wireplumber.conf:815`). Its `sm-objects.lua:7` dynamic loading
surface accepts JSON-valued metadata. The selected RTC live-control contract
requires typed native controls; a saved SPA-JSON profile is a different boundary.
WirePlumber also selects stock PipeWire/SPA pkg-config dependencies (`meson.build:71`).

**Disposition:** use an explicit AO component set and exact connection policy.
Prove library/type/parameter compatibility before deciding native patches or fork
scope. Do not use JSON-valued metadata as the RTC live command bus. Reuse the
existing native lifecycle/artifact interfaces and serialized runtime dispatcher.

**Validation:** typed NDArray discovery/parameters/links, missing intended endpoint,
compatible distractors, duplicate names and unrelated desktop sessions. Existing
upstream dynamic loading is a capability, not the selected RTC control interface.

## Consolidated implementation recommendation

1. Keep the headless lifecycle owner, GUI/CLI contracts and current scientific
   placements. Prove isolated WirePlumberAO discovery and NDArray compatibility.
2. Resolve AAR-01/02/04/09 through one narrowly specified connection pilot.
   Give each link one owner and validate source admission against actual state.
3. Evaluate the maintained responsibility cost. If link transfer adds more
   coordination than it removes, retain runtime-owned admitted-session links
   and use WirePlumber for instrument inventory/availability. That still reuses
   the framework; daemon ownership of every link is not required by the DAW model.
4. Migrate process supervision separately, preserving AAR-03/05 and the same
   foreground/control behavior. Delete redundant code only after behavioral parity.
5. Qualify live-control interference and independent-arrival timing separately
   under AAR-06/08. Evaluate optional WirePlumber FGN hosting after baseline parity.

## Source scope

| Source | Inspected revision / state |
| --- | --- |
| RTC | `a63dd6d`, clean review baseline |
| WirePlumber | `bdc17eb`, clean |
| PipeWireAO | `29da2d6`, clean |
| JFG | `b609116`, pre-existing untracked benchmark caches and `gmon.out` preserved |
| PipeWireAO.jl | `1417b69`, clean |

Source paths in findings are relative to the named repository; architecture and
integration document references are within RTC `docs/`. These revisions support
source conclusions, not an executable deployment
qualification. Existing calibration and numerical evidence was not reacquired.

## Consensus record

Round 1: independent Astra system review and Sol real-time review, plus a bounded
read-only source inventory. The primary agent independently verified the principal
link-lifetime, restart, admission, scheduling and callback facts and consolidated
the findings above. No reviewer reported a demonstrated current timing failure.

Round 2: Astra and Sol independently accepted AAR-01 through AAR-09 and the
consolidated recommendation, with no architectural veto. Their corrections were
incorporated: data-loop RT acquisition citation; owner-reaching control work
versus client-only load; process/client-context restart versus policy-only reload;
bounded realization failure; and the DAW analogy's scientific limits.

Consensus covers the ownership direction, strengths, conditional migration gates
and evidence classifications. Unresolved questions remain explicit: stock
WirePlumber compatibility, the realization mechanism, whether transfer simplifies
maintenance, profile-specific timing/interference magnitudes and optional FGN
hosting. Agreement on these uncertainties is not proof of their resolution,
physical safety or a necessary framework fork.

Final verification: both reviewers checked the applied integration/architecture
amendments and confirmed no regression or veto. A source-path correction and the
initial-calibration scope correction were applied. This final check did not run
code or services.
