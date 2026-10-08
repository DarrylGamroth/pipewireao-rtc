# WirePlumber session independent review

Status: independent documentation recheck complete; WPS-01 through WPS-08
resolved in the reviewed documentation. The implementation recheck below finds
source remediations for WPI-01 through WPI-09 and resolves WPI-C01/C02 at source
level. Later integration passes below record WPI-10 through WPI-26 and their
current source dispositions. Lifecycle coverage and qualification gates remain
open. No runtime gate is closed.

Review date: 2026-10-07. Baseline: RTC
`e791361eaa491dae7e99e1d3df69816de58061a3`, worktree
`/tmp/rtc-wireplumber-session-20261007`, decision RTC-ARCH-025. The recheck
compared the revised operating contract and migration design with the original
review findings, including the architecture and roadmap statements about
provider allocation and retirement. Evidence below is observed document text;
it does not establish implementation behavior.

The IDs and severities below preserve the original independent findings. An
intermediate correction draft used unhyphenated IDs with different groupings;
that draft is superseded by this record. Confidence is high for each finding
and disposition because the removed and restored clauses are directly visible
in the source documents.

| ID | Severity | Confidence | Original finding and evidence | Final documentation disposition |
| --- | --- | --- | --- | --- |
| WPS-01 | High | High | RTC-DEV-021 removed exact systemd owner identity, restart restrictions, cleanup-hook validation, uncertain-start reconciliation and abrupt authority-death ordering. | Resolved. [RTC-DEV-021](../../operations.md#rtc-dev-021--admission-and-coherent-lifecycle) now requires fresh owner unit names, `Restart=no`, verified MainPIDs and process incarnations, owned-only termination, installed emergency-hook verification before startup, reconciliation of uncertain launches and pending starts, finite manager/cleanup budgets, and explicit non-atomic name-based stop semantics. The hook must revoke ingress before consumer teardown after WirePlumber death when Lua cannot run. [Design gate 3](../../WIREPLUMBER_SESSION_DESIGN.md#migration-and-removal-gates) retains those obligations. |
| WPS-02 | High | High | RTC-DEV-009/012 lost explicit internal effect cardinality, non-reused tokens and token/kind/transition/group completion matching. A single public pending request did not replace these constraints. | Resolved. [RTC-DEV-009](../../operations.md#rtc-dev-009--serialized-lifecycle-execution) and [RTC-DEV-012](../../operations.md#rtc-dev-012--serialized-execution-group-control) bound internal session/group effects to one in flight and require unique tokens within the manager incarnation plus kind, originating transition, session incarnation and applicable group identity. Stop, unload, reset and required loss cancel or fence pending work; late results cannot mutate subsequent state. |
| WPS-03 | High | High | Retirement of the realization Filter also removed the pending asynchronous Link-creation fence, allowing an empty registry snapshot to precede a late creation. | Resolved. [RTC-DEV-003](../../operations.md#rtc-dev-003--exact-topology-realization-and-cleanup) and [RTC-DEV-030](../../operations.md#rtc-dev-030--native-local-live-controls) require accounting for pending creation completions, cancellation/withdrawal, proxy deactivation/destruction, manager Core synchronization and exact correlated Link absence before success or a new generation. A zero-Links snapshot alone is explicitly insufficient. |
| WPS-04 | High | High | RTC-DEV-009 described the C transport shim as the executor of potentially blocking work, although transport callbacks/actions share the WirePlumber main context. Filesystem/configuration restrictions were also lost. | Resolved. [RTC-DEV-009](../../operations.md#rtc-dev-009--serialized-lifecycle-execution) requires asynchronous PipeWire operations, forbids blocking roundtrips and filesystem/configuration/science work in Lua and native handlers, and bounds external owner operations. The shim and clients cannot own lifecycle state. [Design gate 1](../../WIREPLUMBER_SESSION_DESIGN.md#migration-and-removal-gates) preserves this separation. These are implementation obligations, not proof that all candidate transport paths satisfy them. |
| WPS-05 | Medium | High | RTC-DEV-022 reduced scalar transactions and declared parameter/generation operations to generic updates, omitted ordering against lifecycle changes, and removed the existing dispatcher bound. | Resolved. [RTC-DEV-022](../../operations.md#rtc-dev-022--bounded-local-control) restores scalar transactions, declared ndarray replacement and property/parameter generation queries. WirePlumber orders updates against reset, stop and reload; exact scientific owners apply values and report adoption. Submission is distinct from adoption, disconnect does not retry or imply rollback, and the five-second session-effect bound remains unless separately changed by an approved contract. |
| WPS-06 | Medium | High | RTC-DEV-004 weakened `OFFLINE` to absence of admission, which did not establish resource cleanup. | Resolved. [RTC-DEV-004](../../operations.md#rtc-dev-004--basic-lifecycle) requires no authority-owned session resources and no pending realization or cleanup. Externally owned nodes may remain. Unload must complete cancellation, withdrawal, stop and cleanup fences or retain `FAULT`. |
| WPS-07 | Medium | High | The design incorrectly stated that LocalModule hosting does not move execution into WirePlumber and conflated existing data paths with proposed hosting alternatives. | Resolved. [Design gate 4](../../WIREPLUMBER_SESSION_DESIGN.md#migration-and-removal-gates) distinguishes FGN/JFG data paths from hosting choices. LocalModule runs FGN inside the WirePlumber process; a separate FGN service uses another process. Placement and failure qualification remain open. Neither option assigns frame scheduling to Lua. The [architecture allocation](../../architecture.md#accepted-workstation-integration-boundary) agrees. |
| WPS-08 | Medium | High | Retained normative references to “the runner” left mandatory behavior assigned to a provider that the new decision retires. | Resolved. The [operating-contract terms](../../operations.md#terms) explicitly map “the runner” to the WirePlumber session authority except in historical/client passages. This retains the owner-applied completion, timeout, run-control and update obligations in otherwise unchanged requirements without retaining a Statig implementation mandate. [RTC-DEV-009](../../operations.md#rtc-dev-009--serialized-lifecycle-execution) explicitly retires that mandate. |

The additional wording corrections are also resolved. The design, architecture
and roadmap restrict one-shot use to Julia deployment tooling while retaining
Julia scientific owners and calibration clients. They describe the native
transport foundation as underway and the lifecycle policy and installed
replacement as unimplemented and unqualified.

The [removal gates](../../WIREPLUMBER_SESSION_DESIGN.md#migration-and-removal-gates)
and [current work](../../roadmap.md#current-work) preserve the existing runtime,
foreground/service support, graph hosting and scientific paths until relevant
replacement evidence passes. “Retired target components” describes the selected
destination; it does not mean either existing coordinator has been removed.
Foreground and user-service operation retain the same required session contract.

No documentation blocker from this review remains. Session policy, native
operation coverage, systemd failure cleanup, FGN hosting selection and installed
profile parity remain implementation and qualification gates. The compiled
transport candidate, API additions and `ao-control.lua`/`ao-owner.lua` helpers
do not establish those gates; their implementation correctness was not assessed
in this documentation recheck.

This recheck changed only this review record. No production files were edited,
and no tests, builds, live deployments or hardware checks were run. Document
dispositions must not be promoted to functional, numerical, allocation, timing
or hardware qualification.

## Independent implementation source review, 2026-10-07

Scope: read-only inspection of `src/scripts/lib/ao-connections.lua`,
`src/scripts/lib/ao-session-control.lua`, `src/scripts/lib/ao-control.lua` and
`modules/module-ao-control-endpoint.c` in
`/tmp/WirePlumberAO-session-20261007`, with supporting inspection of existing
WirePlumber/PipeWire behavior and the current Julia native endpoint. This was
an uncommitted candidate undergoing concurrent development. References below
identify lines and functions at initial inspection; remediation can move those
lines. No implementation fix or changed disposition is inferred from a later
file timestamp or the primary agent's intention to fix the finding.

The findings are confirmed by source inspection, with high confidence, rather
than by executed fail-before experiments. Their described consequences follow
from the observed control flow. No tests, builds, deployments or live actions
were run for this review. Suggested validation below remains outstanding.
The documentation findings above remain resolved independently of these
implementation defects.

| ID | Severity | Confidence | Observed source evidence and consequence | Required remediation and validation | Disposition |
| --- | --- | --- | --- | --- | --- |
| WPI-01 | High | High | `ao-session-control.lua:127–128`, `server.new`, constrains `pipewireao.rtc-control.profile` with `type = "pw-global"`. PipeWire `src/pipewire/impl-node.c:189` omits that custom property from `global_keys`; WirePlumber `lib/wp/object-manager.c`, `wp_object_manager_is_interested_in_global`, rejects failed global constraints before NodeInfo binding. Ordinary controller nodes cannot be discovered through this constraint. | Discover through exported standard candidate properties, then prove full NodeInfo, or use an appropriate NodeInfo property constraint. Validate discovery of a real controller whose registry announcement lacks the custom profile, plus invalid-proof rejection. | Remediation and independent verification pending. |
| WPI-02 | High | High | `ao-session-control.lua:151` routes every `transport-error` to the session fault handler. The C endpoint emits that signal for malformed incoming PODs (`on_filter_param_changed`, initially line 398) and bounded handoff overflow (`deliver_event`, initially line 145). Invalid input or competing requests can therefore fault an otherwise healthy session. | Distinguish invalid-input/busy diagnostics from transport loss or publication failure. Preserve accepted state and retained completion while rejecting bad input. Validate malformed input and request contention during an accepted operation without session fault, plus genuine transport failure. | Remediation and independent verification pending. |
| WPI-03 | High | High | `ao-connections.lua:239–245`, `connections.withdraw`, succeeds immediately when no cohort exists, without cancelling `catalog.waiting` or discovery's timer (`connections.discover`, initially line 134). A late object addition can deliver successful discovery after cleanup has reported completion. | Cancel/fence discovery and every late callback before cleanup success, using an operation generation or equivalent identity. Validate unload during incomplete discovery followed by late endpoint arrival; no successful old completion or subsequent realization may occur. | Remediation and independent verification pending. |
| WPI-04 | High | High | `ao-connections.lua:23–35` observes registry addition/removal; format validation occurs once during realization around line 199. `present` compares object identity only. No continuing handler validates required node/client/port property or format mutation while the incarnation remains present. | Observe relevant info/format changes and revalidate captured ownership and declared contracts. Validate incompatible changes without object removal in both READY and RUNNING, retaining failure and source-revocation semantics. | Remediation and independent verification pending. |
| WPI-05 | High | High | `ao-connections.lua:181–208` requests `link.passive` but never checks the observed property before successful realization. Ignored or altered passive semantics can be admitted. | Verify observed passive semantics, endpoint identities and creator provenance before admission, with continuing relevant mutation checks. Validate an ignored/changed passive property and endpoint/owner mismatch. | Remediation and independent verification pending. |
| WPI-06 | High | High | `ao-session-control.lua:51–60`, `server.complete`, accepts success without rechecking deadline or controller proof. Controller mutation/removal around lines 134–148 only retires a catalog entry. The existing Julia `NativeControlEndpoint.check_ticket` rechecks both before success. A pending candidate request can report success after controller loss or proof change. | Add a pending-ticket check before effects and successful completion. Fence further work on loss/expiry and retain unknown outcomes. Validate controller removal, changed proof and deadline expiry while an asynchronous operation is pending. | Remediation and independent verification pending. |
| WPI-07 | Medium | High | `ao-session-control.lua:130` refuses additions once the controller array reaches 32. Removal at lines 144–148 only marks rows retired; rows are never pruned. Thirty-two sequential distinct clients exhaust future controller admission. | Prune retired records when their exact registry incarnation disappears, while retaining tombstones for invalid proofs on still-live incarnations. Validate more than 32 sequential clients and ensure a still-live invalidated incarnation cannot regain authority. | Remediation and independent verification pending. |
| WPI-08 | Medium | High | `ao-session-control.lua:95–100` rejects all pending duplicates as busy and completed duplicates as stale. The retained terminal ticket is not consulted for canonical duplicate equivalence, unlike existing native endpoint behavior. | Match controller, token, operation and canonical payload against pending/terminal requests; republish the retained record for an identical duplicate and reject conflicting reuse without reexecution. Validate identical pending/completed duplicates, changed payload and changed caller. | Remediation and independent verification pending. |
| WPI-09 | Medium | High | `ao-connections.lua:118–131`, `bounded`, relies on timer dispatch and schedules even expired deadlines at least one millisecond later. Other callbacks can therefore start or report successful work after expiry before the timer runs. `ao-session-control.lua:101` also starts the budget at deferred Lua delivery, excluding C handoff delay; the inspected C event did not carry receipt time. | Check monotonic deadlines before effects and successful completion; reject an already-expired deadline immediately. Carry native monotonic receipt time into deferred delivery and derive the owner deadline from that receipt. Validate delayed handoff and event ordering where completion is delivered after expiry before the timeout callback. | Remediation and independent verification pending. |

The table above preserves the initial findings and their initial dispositions.
The later source recheck below supersedes those pending dispositions. It does
not replace the original observed-source evidence with a report of intention.

## Unresolved implementation concerns

These concerns were not established as defects in the reviewed scope. Keep them
distinct from the confirmed WPI findings until the stated evidence is available.

| ID | Classification | Evidence and uncertainty | Required disposition evidence | Status |
| --- | --- | --- | --- | --- |
| WPI-C01 | Hypothesis; medium confidence | `wp_ao_control_endpoint_publish_records` emits `transport-error` synchronously on publication failure. If the completed `session.lua` fault handler republishes lifecycle state through the same failing endpoint, failure handling could recurse. The final policy handler was outside this review. | Inspect the integrated handler and establish a nonrecursive terminal publication/transport-failure path, including failure while publishing the fault state. | Open; not a confirmed defect. |
| WPI-C02 | Verification concern; unresolved | `connections.withdraw` inspects the ObjectManager catalog immediately after manager Core synchronization. The inspected code does not itself establish whether that fence also settles all manager activation/removal processing, especially for a Link created but never admitted to the catalog. | Establish the relevant WirePlumber ordering guarantee from implementation, or use a discriminating delayed-activation/removal check proving that cleanup cannot acknowledge while a correlated Link remains or can still appear. | Open; not a confirmed defect. |

The INFO-only observation masks avoid automatic scientific Props subscription,
and the C handoff bounds copied requests and defers Lua delivery beyond native
callbacks. These observed design choices do not close the defects or any runtime
qualification gate. Existing coordinators and working foreground/service paths
remain required until replacement parity and removal gates pass.

## Independent implementation recheck, 2026-10-07

This pass inspected the current Lua policy/helpers, native endpoint and native
Link APIs in `/tmp/WirePlumberAO-session-20261007` (branch
`work/ao-session-20261007`, baseline
`4c2648faeff714b19e806e747075f6f9f8f4b02c`); the launcher, codecs and parameter
publisher in the RTC worktree above; and direct-session reply changes in
`/tmp/pipewireao-gui-session-20261007` (branch
`work/wireplumber-session-20261007`, baseline
`3cebf28877a47ac6ee8fc543184132a938f57d57`). All three worktrees already contained
uncommitted implementation changes. The primary agent and implementation
workers continued editing during review. Function names and the described
control flow identify each observation when subsequent edits move its lines.

Evidence is observed source and derived control-flow consequences. No tests,
builds, deployments, daemon operations or hardware actions were run. This pass
changed only this review record. Source remediation means that the original
defect mechanism is addressed in the inspected source; all behavioral
validation listed in the initial findings remains outstanding.

### Original implementation dispositions

These dispositions supersede the initial pending entries while preserving
WPI-01 through WPI-09 and their original severities.

| ID | Current source evidence | Disposition |
| --- | --- | --- |
| WPI-01 | `ao-session-control.lua:176–177` now uses a `pw` property constraint with INFO features, allowing NodeInfo binding before evaluating the custom controller profile. | Source remediation reviewed; real-controller discovery validation pending. |
| WPI-02 | `ao-session-control.lua:205–209` rejects malformed/overflow input separately from endpoint state loss. Native publication failure returns failure to its caller. | Source remediation reviewed; malformed-input, contention and transport-loss validation pending. |
| WPI-03 | `ao-connections.lua:359–366` clears the waiting callback and cancels discovery before the no-cohort success path. Terminal realization cancels its completion and prevents later creation. | Source remediation reviewed; late-endpoint and pending-create cleanup validation pending. |
| WPI-04 | `ao-connections.lua:117–153` freezes relevant endpoint properties, including their absence, and observes inventory/state changes. `:291–339` rechecks admitted Link state, properties and current Format, including Format loss. | Source remediation reviewed for captured data endpoints/Links. Integrated owner-control capture must still be checked with completed startup; mutation/failure validation pending. |
| WPI-05 | `ao-connections.lua:305–314` checks observed endpoint IDs, creator `client.id`, passive semantics and both declared formats before admission and on subsequent change. | Source remediation reviewed; ignored passive property and wrong-provenance validation pending. |
| WPI-06 | `ao-session-control.lua:57–89` checks pending identity, deadline and freshly proven controller properties before successful completion; `:124–129` repeats proof at ingress. Controller port-count/property changes retire the proof. | Source remediation reviewed for ingress/completion. Complete policy effect cancellation remains WPI-13. |
| WPI-07 | `ao-session-control.lua:196–202` removes disappeared controller incarnations from the bounded array; a mutated still-present incarnation remains retired. | Source remediation reviewed; sequential-client/tombstone validation pending. |
| WPI-08 | `ao-session-control.lua:131–138` matches retained pending/terminal identity, operation, token, budget and canonical POD equality before republishing without executing again. | Source remediation reviewed; duplicate/conflicting-token validation pending. |
| WPI-09 | The C endpoint records `g_get_monotonic_time()` in `on_filter_param_changed` (`module-ao-control-endpoint.c:423`) and passes it with deferred delivery (`:154`). `ao-session-control.lua:148–150` derives and checks the receipt-based deadline. `ao-connections.lua:207–227` checks the clock before effects and successful completion. Native owner operations also check remaining time before submission. | Source remediation reviewed; delayed-handoff/event-order validation pending. |

### Disposition of the two original concerns

**WPI-C01 — resolved at source level, high confidence.** The C publication
action (`module-ao-control-endpoint.c:457–500`) returns false and logs on failure
without synchronously emitting `transport-error`. `server.publish`
(`ao-session-control.lua:34–41`) sets `transport_lost` before calling the fault
handler, so a nested fault publication returns immediately, then requests
disconnect. `session.lua` also guards repeated fault handling. This removes the
reported recursion mechanism. Fault-publication failure and disconnect cleanup
still need behavioral validation.

**WPI-C02 — source ordering concern resolved, high confidence within the
current factory/lifetime contract.** The proof is the following native lifetime
chain, rather than an empty ObjectManager snapshot:

1. `ao-connections.lua:369–393` marks the cohort terminal, cancels realization,
   waits for every counted creator activation callback, deactivates every
   creator proxy again, and only then sends `Core.sync`. A terminal activation
   callback deactivates its proxy and cannot start another Link (`:343–346`).
2. WirePlumber `lib/wp/proxy.c:380–391` deactivation of BOUND calls
   `pw_proxy_destroy`. PipeWire `src/pipewire/proxy.c:208–236` queues
   `pw_core_destroy` for a still-live remote proxy and marks the local proxy
   destroyed. Creator activation cancellation is signalled through WirePlumber
   `on_proxy_destroyed` and its activation-abort path.
3. This cohort explicitly requests `object.linger=false`. PipeWire
   `src/modules/module-link-factory.c:498–520` registers each created Link
   synchronously; `src/pipewire/impl-link.c:1719` synchronously emits initialized.
   The factory's `link_initialized` (`:224–241`) binds the client resource and
   installs its nonlingering destruction listener. Resource destruction calls
   `pw_global_destroy` (`:179–185`), whose Link listener calls
   `pw_impl_link_destroy` (`src/pipewire/impl-link.c:1652–1657`). Thus no deferred
   factory initialization can recreate this Link after the ordered destroy.
4. WirePlumber `lib/wp/core.c:1239–1245` documents that sync orders prior methods
   and their resulting events. `lib/wp/private/registry.c:124–149` handles
   removal from both exposed and temporary globals. Its removal path notifies
   managers, deactivates/aborts pending proxy activation and invalidates the ID
   (`:508–543`). `expose_tmp_globals` skips removed/invalid entries (`:309–313`).
   ObjectManager emits removal synchronously for admitted objects and adds a
   pending object only after successful activation (`lib/wp/object-manager.c`,
   `wp_object_manager_rm_object` and `on_proxy_ready`, `:760–787`).

Consequently a successful fence establishes the server resource lifetime even
for a Link not previously admitted to the catalog. Catalog absence is an
additional conservative check. An activation that throws without a known
completion leaves its count outstanding and cleanup fails by deadline; it does
not acknowledge success. This conclusion does not claim that Core.sync flushes
every arbitrary GLib callback, or apply to lingering Links, another factory,
other client connections, or a failed/disconnected core. Delayed activation,
removal and disconnect scenarios remain runtime validation gates.

### Additional session-integration findings

All findings below have high confidence from observed source. Severity remains
High even when a small source correction was made during this review. Proposed
validation is outstanding, not evidence of an executed experiment.

| ID | Severity | Observed evidence and derived consequence | Required action and validation | Disposition |
| --- | --- | --- | --- | --- |
| WPI-10 | High | Initial `ao-owner.lua`, `node_records`, allowed only two graph Props records and rejected ordinary science Props. Maintained PipeWire `module-ndarray-filter-chain.c`, `build_graph_param_offsets` (`:875–905`), exposes science Props followed by run/reset controls. Initial graph stop therefore failed before READY. | Permit the bounded ordinary scientific record while strictly parsing the known reserved control namespaces. Validate real FGN and JFG enumeration plus malformed/duplicate control records. | Source remediation reviewed: `ao-owner.lua:358–388` now allows three graph records and ignores ordinary values while rejecting unknown reserved control fields. Runtime validation pending. |
| WPI-11 | High | Initial RTC `native_parameter_source.jl:252–253`, `Process`, used `length(bytes)` although only `source.bytes` exists in that callback. Pending publication caught `UndefVarError` and recorded failure. | Use the owned payload extent consistently; validate an explicit initial payload and a later parameter submission against the declared stream dimensions. | Source remediation reviewed: both references now use `length(source.bytes)`. Runtime validation pending. |
| WPI-12 | High | Inspected `session.lua:397–429` treated group Stop/Start like a session stop: it held the shared source, set session lifecycle READY, then controlled one group's graphs without restoring ingress. This prevents other groups from progressing and breaks RTC-DEV-011. Startup `:520–523` also required every group member to be a graph, despite the contract allowing sources and requiring sink membership. | Validate full declared membership, control only each member's proper owner interface, preserve RUNNING and other-group progress, and retain source/session distinctions. Validate two independent groups and a shared-source fork with one branch stopped/restarted. | Partially remediated: subsequent dispatch (`:360–362,416–420`) requires RUNNING and controls the selected graphs without changing lifecycle or shared source. Startup membership remained graph-only at the last inspection; full integration recheck and runtime validation pending. |
| WPI-13 | High | Initial fault handling advanced the policy epoch but discarded cancellation closures returned by `owner.node_operation`/`owner.request`. Those helpers' internal enum callbacks can still submit native effects before their final guarded callback. The partial revision adds `effect`/`cancel_effects` (`session.lua:24–38,146–152`), but inspected Start/reset/bootstrap call sites (`:401,416,423,482,494`) still bypass that registration. | Register every effect's logical cancellation before beginning cleanup/new effects, including startup and source release/reset. Cancel pending helper submissions/polling; keep submitted outcomes unknown and enforce source revocation ordering. Validate loss/expiry before and after native submission with delayed callbacks. | Partially remediated; integration recheck required. Final-callback epoch checks alone do not close this finding. |
| WPI-14 | High | `session.lua:536–538` publishes READY after graph/link admission and `:398–407` permits Start without effective resource proof. RTC `wireplumber_cli.jl:140–172` observes READY and only then takes effective placement snapshots before locator publication. A direct native controller can release the source before those checks; withholding a locator does not gate the published endpoint. RTC-DEV-019/021 require effective warm-thread placement and prerequisites before ingress. | Keep policy CONFIGURING until a bounded native admission completion binds current authority, checker and required owner incarnations. Reuse the one-shot launcher for inspection; Lua remains the only admission/state writer. Reject Start before that completion. Validate a direct controller racing checks, failed rights/affinity and owner replacement during inspection. | Accepted by primary; a native admission operation is being integrated. No admission gate closed. |
| WPI-15 | High | `session.lua:350,397–416` initially admitted Reset in RUNNING and performed source hold/graph stop before resetting instead of rejecting the invalid initial state. RTC-DEV-018 explicitly requires READY-only reset; RTC-DEV-025 retains stopped-session source reset semantics. | Check the stable state before any effects. Validate Reset while RUNNING leaves lifecycle, source and graph unchanged; validate acknowledged stopped reset followed by explicit restart. | Source remediation reviewed in the subsequent dispatch guard (`:364`): Reset requires lifecycle READY before `begin`. Runtime validation pending. |
| WPI-16 | High | `session.lua:88–93`, `complete`, initially called `ingress.complete` for public tickets without copying `state.lifecycle` into `api.lifecycle`; only `publish` did that. Start could set policy lifecycle RUNNING while its outer native completion and capability still reported READY. Typed GUI replies use the outer lifecycle, so client-visible state was incorrect. | Centralize lifecycle publication/update before every public completion; keep capability, completion and operation detail consistent. Validate Start/Stop/Status sequences and the direct GUI reply path. | Source remediation reviewed: `complete`, `operation_error` and query dispatch now copy the authoritative lifecycle into the ingress state. Runtime validation pending. |

### Rejected inference and remaining scope

An initial review message incorrectly identified operation 11 as Unload. This
is **retracted**: Julia `native_session_codec.jl` reuses `NativeRunnerCodec`,
whose `OPERATIONS[11]` is `source_ended`; Rust `native_runner_codec.rs:31,52`
agrees. Returning READY after confirmed source completion is appropriate.
There is no confirmed "Unload returns READY" dispatch finding. Fresh source
completion proof, normal end-of-source handling, and the systemd teardown path
must be reviewed as their own behaviors. Opcode names must come from these
codecs, not inferred branch positions.

The direct GUI reply diff preserves native session completion/rejection and
lifecycle without manufacturing supervisor state (`src/rtc_adapter.rs`,
`reply_dto`; `src/main/rtc_session.rs`). No new confirmed GUI defect was found
in that bounded diff inspection. This does not establish GUI/runtime parity.
The parameter publisher's corrected callback and explicit initial-payload
selection likewise do not establish parameter adoption or numerical parity.

Acquisition startup integration, complete owner cancellation, public lifecycle
coverage, required-owner failure cleanup and the resource-admission handshake
remain in development. Their absence must not be represented as qualified
replacement support. The systemd unload/shutdown path, bounded retry/reload,
normal finite completion and foreground support need explicit coverage against
the retained operating contract. This review does not authorize removal of
either existing coordinator and does not close functional, scientific,
allocation, timing, CPU-placement, installed-runtime or hardware gates.

## Focused integration recheck, 2026-10-07

Scope: WPI-12/13/14, private native operations 15/16, the four dependency-string
decoding changes in WirePlumber's component loader, and the renderer's
client-node context module. Baselines/worktrees remain those recorded above;
implementation changes were still uncommitted and concurrent. This recheck
used source inspection only and edited only this record. It did not run tests,
builds or live actions. The dispositions here supersede the earlier interim
dispositions for these IDs.

### Open findings and reviewed remediation

**WPI-12 — partially remediated; High, high confidence.** The current
`session.lua:383–387,453–457` requires RUNNING for group controls, retains that
session state, and controls only the selected processing graphs without
holding the shared source. Startup `:588–610` now retains the complete declared
member list separately from its graph subset, checks duplicates, graph
membership, intergroup links and passive boundaries. This fixes the original
group operation and graph-only member rejection mechanisms.

The remaining validation differs from the maintained ownership rules in RTC
`src/config.rs:655–783`: application-controlled external members are excluded
there, while nonexternal sinks require group membership. The inspected Lua
accepts external members and checks required membership only for graphs; it
also does not reject an empty/NUL group name. RTC `Deploy.decode` is a format
decoder, not this semantic validator. Apply the ownership-aware declaration
checks before admission. Two-group/fork behavior and invalid declarations still
need validation.

Clarification to the initial WPI-12 wording: the existing external-endpoint
exception matters. HIL's `hil_export.jl:353–354` correctly keeps its external
simulator source/sink outside execution groups. This is not itself a defect,
and they must not receive graph run-control merely to satisfy a membership
check. The required-sink check concerns nonexternal session-owned sinks.

**WPI-13 — source remediation reviewed; High, high confidence.** The current
`effect` and `cancel_effects` register each logical effect's returned cancel
closure and cancel before fault cleanup (`session.lua:24–38,172–178`). This now
covers startup `owner.wait_prepared` and Connect (`:542–554`), acquisition
preparation (`:579–582`), graph control/reset, source hold/release/reset, and
parameter requests. `ao-owner.lua`, `request`/`wait_prepared`, clear the exact
pending identity and stop timers; their enum callbacks check that identity
before native submission. `ao-acquisition.lua:216–235` also cancels its current
underlying stage and guards against a synchronous callback replacing the stage
before a returned cancellation closure is installed. Connection discovery and
creation remain separately fenced by terminal withdrawal as recorded in C02.
These observations close the original stale owner-helper submission mechanism
at source level. Delayed-callback cancellation and unknown submitted outcomes
still require behavioral validation.

**WPI-14 — source remediation reviewed for the supported null-QoS profile;
High, high confidence.** Scientific startup now sets `state.warmed` while
retaining CONFIGURING (`session.lua:616–618`). Warmup operation 15 captures the
configured one-shot admission controller instance and its actual registry
identity/PID; operation 16 requires that same controller, warmed state,
CONFIGURING and no pending internal operation before setting READY
(`:402–421`). Regular Start is therefore rejected before native admission.
The one-shot CLI retains this controller across Warmup, systemd/process identity
checks, effective per-thread placement snapshots, Admit, and fresh Status
(`wireplumber_cli.jl:138–188`). The launcher remains an inspector; Lua performs
the state transition.

The recheck found a concrete QoS omission: `Placement.credentials` only opens
and closes `/dev/cpu_dma_latency` to verify access. The new path did not write
or retain the requested lease, whereas existing `deploy.jl:1472–1478` does.
The primary selected an explicit unsupported-feature rejection. Inspected
`wireplumber_launch.jl:371–372` and `wireplumber_install.jl:33–34` now reject
non-null `cpu-latency-us` before owner startup/installation. This prevents
admission with silently omitted requested QoS; it does not implement the lease
or preserve that capability yet. The null-QoS profile's actual rights,
placement, source silence and admission race scenarios remain unqualified.

### WPI-17 — successful Warmup outside CONFIGURING violates its wire grammar

- **Severity:** Medium. **Confidence:** High. **Classification:** confirmed
  source defect; derived failure path, not an executed experiment.
- **Evidence:** `session.lua:402–421` checks the stable state for Admit (16),
  but not Warmup (15), then calls `complete_admin` with the current state and a
  successful header. `ao-session-control.lua`, `complete_admin`, retains that
  record. Julia `native_session_codec.jl:75–76` and Rust
  `native_session_codec.rs:55–56` require every successful operation-15
  completion to have lifecycle CONFIGURING.
- **Consequence:** after a startup fault, a subsequent request in the launcher's
  Warmup loop can retain a successful operation-15 completion with lifecycle
  FAULT. Both clients classify it as malformed. Since clients also decode the
  retained completion during observation, that record can prevent later fresh
  Status diagnostics until another valid completion replaces it.
- **Remediation:** require CONFIGURING for Warmup before publishing success;
  preserve the standard correlated negative-completion grammar when the state
  is FAULT or READY. Do not relax the client decoder to accept contradictory
  successful preparation replies.
- **Required validation:** Warmup after a startup fault and after admission;
  a newly connected client must still decode retained records and query Status.
- **Disposition:** reported to the primary; source remediation pending recheck.

### Component loading and native export configuration

No confirmed defect was found in the four dependency-string changes.
`internal-comp-loader.c:221,232,243,254` now uses
`wp_spa_json_parse_string` for `requires`, `wants`, `before` and `after`.
`lib/wp/spa-json.c:323–325` shows that the previous `to_string` simply copied
the raw token, retaining JSON quotes. `:739–757` shows that `parse_string`
decodes the token into a newly allocated string. The dependency arrays own
their entries with `g_free`, and feature comparisons/hash lookups need the
decoded name. This preserves allocation ownership and handles the renderer's
quoted dependency names. Quoted/bare/escaped dependency configurations and
ordering still need software validation; no such test was run in this pass.

`wireplumber_configuration.jl:191–192` loads
`libpipewire-module-client-node` alongside protocol-native in the WirePlumber
context. Maintained `src/config/wireplumber.conf:222–223` does the same.
PipeWire `src/modules/module-client-node.c:256–263` registers the native Node
and SPA Node export types used by a client context. This is a grounded module
dependency for the native control endpoints, not a new session authority or
frame scheduler. Installed module resolution/export remains unqualified.

### Missing lifecycle coverage, distinct from confirmed defects

- **Quit:** operation 1 still reaches the explicit unimplemented response in
  `session.lua` dispatch. This is a missing public lifecycle capability, not a
  false success or proof that the systemd stop/cleanup path is incorrect.
- **Normal end of source:** operation 11 correctly means SourceEnded and now
  queries a fresh completed/nonrunning source snapshot before stopping graphs.
  The inspected policy has no automatic finite-source completion observer; its
  only persistent policy timer is the startup timer. Automatic normal-end
  transition coverage remains missing, separately from the corrected opcode
  interpretation.
- **HEART bootstrap:** `ao-acquisition.lua` supports the legacy simulator and
  calibration/correction lifecycle profiles, and explicitly rejects using
  HEART supervision as acquisition control. `session.lua` bootstrap discovery
  currently constructs the generic owner-bootstrap profile. A distinct HEART
  integration remains absent; no claim is made that the established HEART
  owner or its numerical path changed or failed.

These missing capabilities, plus installed lifecycle/cleanup and numerical,
allocation and placement validation, prevent a migration-complete or existing
coordinator-removal claim. Source fixes and truthful unsupported-feature
rejection close neither runtime nor feature-parity gates.

### Bounded direct operator CLI review

The subsequently added `sessions`, `select-session` and `control` paths in
`deployment/julia/wireplumber_cli.jl:235–342` were inspected with
`NativeSessionClient.select_direct_session` and `render_direct`. No confirmed
defect was found in this bounded source pass. Listing returns unverified local
POD hints. Selection opens only the direct session profile, obtains a fresh
typed Status, compares its UUID/endpoint/owner/registry identity with the
selected hint, and retains that exact client. It does not invoke the separate
legacy selector's supervisor fallback. `control_session` parses through the
existing bounded typed `RunnerCommands` grammar, shares one finite deadline
across selection and mutation, and closes the retained connection in `finally`.

`NativeSessionClient.request!` delegates to the existing native client's
serialized request path, including exact reply correlation and permanent
unknown-outcome retirement after a sent request fails. `render_direct` adds the
verified UUID and WirePlumber authority to the typed result; it does not invent
a supervisor snapshot. This review does not establish command functionality,
CLI exit-status conventions for negative replies, installed invocation, or
freshness beyond the actual native selection/request protocol. No CLI command,
module load, test or live connection was executed by this reviewer.

### Final policy-source follow-up in this pass

The completed worker changes to `session.lua` and `ao-session-control.lua` were
read after the preceding observations. This section supersedes the WPI-12 and
WPI-17 pending source dispositions and the earlier statements that Quit and
HEART bootstrap had no implementation. It does not supersede unrun validation.

**WPI-12 — source remediation reviewed; High, high confidence.**
`session_controlled` (`session.lua:237–250`) now distinguishes runner-owned
nodes, external graphs with an explicit session run-control grant, and
application-controlled external endpoints. Startup (`:664–701`, before later
line shifts) requires nonempty/NUL-free group names, unique eligible members,
membership for session-controlled graphs and nonexternal sinks, and a numerical
graph in each group. Latest-hold membership is required, but the object is
excluded from scientific run/reset control and from satisfying the numerical
graph requirement. The final refinement (`:688–709`) requires groups exactly
when a session-controlled graph exists and skips required sink membership for
application-only compositions with no groups, matching the existing
`requires_execution_groups` exception. These checks match the inspected
ownership distinctions in RTC `src/config.rs:655–803`. Shared-source group behavior remains as corrected
above. No original WPI-12 source defect remains in this inspected path; group
runtime behavior and latest-hold's separate standard control coverage remain
validation/integration gates.

**WPI-17 — source remediation reviewed; Medium, high confidence.**
`session.lua:442` now rejects Warmup outside CONFIGURING before changing the
admission-controller binding or publishing a successful administrative reply.
The existing dispatch error path publishes a correlated negative completion,
which both administrative decoders accept. Startup-fault and retained-record
validation remain unrun.

**WPI-18 — Quit initially used a daemon-disabled API; High, high confidence;
source remediation reviewed.** The first worker implementation called
`Core.quit` after completion publication. WirePlumber
`modules/module-lua-scripting/api/api.c:253–263` explicitly ignores that API
when `wireplumber.daemon=true`, and `src/main.c:226` sets that property for the
installed daemon. Consequently the original branch would remain alive with
withdrawn Links and a closed request gate, preventing systemd exit cleanup.
This is observed source incompatibility; no runtime failure was executed.

The final `session.lua:470–500` holds the acquisition source, acknowledges graph
stop, completes the existing Link-withdrawal fence, sets terminal OFFLINE and
the closing gate, then publishes the established Quit Accepted/true result.
The primary adjudicated OFFLINE after removal of session resources; this does
not mean the public control transport or externally supervised owners have
already disappeared. Publication synchronization, synchronization failure,
setup exception and deadline all reach the existing deferred endpoint
`disconnect` action. That C action schedules `wp_core_disconnect` after the Lua
callback (`module-ao-control-endpoint.c:93–104`), and daemon `on_disconnected`
exits (`src/main.c:71–75`). A one-shot `finished` guard prevents duplicate exit
actions. The ingress closing gate rejects new operations after checking exact
retained duplicates (`ao-session-control.lua:142–153`), preserving the accepted
completion while the final synchronization runs. Publication failure already
uses the nonrecursive fault/disconnect path recorded under C01.

Required validation for WPI-18 remains: installed Quit from READY/RUNNING,
source revocation before consumer teardown, pending-Link withdrawal, completion
delivery versus disconnect, publication failure, sync failure/expiry, duplicate
Quit and actual ExecStopPost cleanup. Core synchronization does not prove that
an arbitrary client consumed the reply; clients must preserve unknown outcomes
if disconnected before observing it. Quit acceptance is not an owner-process
reaping receipt.

**HEART bootstrap is now implemented at source level.** The completed startup
discovers the declared `pipewireao.rtc.heart/1` endpoint with exact owner/endpoint
identity, waits for Ready capability, sends its existing Connect operation 3,
and validates the three-field completion/nine-field Ready snapshot before
acquisition preparation (`session.lua`, `heart_connected` and `prepared`). This
matches the maintained `native_heart_codec.jl`/`native_heart_client.jl` profile
and keeps HEART child supervision separate from acquisition control. Both
readiness and Connect are registered with the startup cancellation path.

This bounded source pass does not establish complete HEART lifecycle parity:
stopped reset of the HEART child, child-exit observation after admission,
effective child-thread placement/report evidence, numerical invariance and
installed cleanup still need explicit integration/validation. Likewise the
normal finite-source observer remains absent; fresh operator-triggered
SourceEnded proof does not implement automatic end-of-source transition.
Quit remains guarded to admitted READY/RUNNING in this candidate; wider
managed-state unload/cancellation coverage must be established through the
selected public/systemd lifecycle paths. Non-null CPU DMA latency requests
remain explicitly unsupported. No runtime, installed-profile or coordinator
removal gate is closed by these source dispositions.

### Installer correction source review

**WPI-19 — legacy installation rewrote sealed artifacts; High; source
remediation reviewed.** The primary reported a failed migration-package
installation caused by `WirePlumberInstall` calling legacy `D.install`, which
regenerated sealed legacy systemd units and produced an artifact-hash mismatch.
The failed install and subsequent successful install are primary-reported
observations; this reviewer did not execute either. The retained legacy
implementation confirms that `deploy.jl`, `install`, writes
`pipewireao-rtc@.service` and `pipewireao-rtc-systemd@.service` (`:1868–1881`), so
it is not an appropriate sealed-copy primitive for the new installer.

Current `wireplumber_install.jl:63–117` independently validates the source
profile/hashes and required runtime/assets, requires a new destination, copies
the sealed package, and validates the copied profile/hashes before generating
only `bin/pipewireao-rtc-session` and `systemd/pipewireao-session@.service`.
A sealed installation-specific new unit is rejected (`:67–68`); a sealed new
launcher is preserved only if its bytes equal the selected Julia invocation
(`:95–100`). The generated launcher invokes `wireplumber_cli.jl`, and the new
unit starts WirePlumber with the one-shot prepare/publish/cleanup commands.
No call to legacy `D.install` or a legacy runtime coordinator remains in this
new install path. Shared profile/path/runtime validators do not start one.

This bounded source review found no remaining artifact-rewrite mechanism in
the corrected installer. Copied legacy package files may remain as inert sealed
artifacts; copying them does not invoke their coordinator. The primary's
installation success is not runtime/lifecycle qualification, and the separately
started isolated qualification unit is outside this reviewer's actions and
evidence. No tests, builds, installs or live service operations were run here.

### Held Link format publication: causal failure and source correction

**WPI-20 — a new Link bind clears pending updates for existing observers;
High, high confidence; fail-before observed, source remediation reviewed.**
The dedicated PipeWire worktree is `/tmp/PipeWireAO-link-info-20261007`, branch
`work/link-info-mask-20261007`, based on
`29da2d6699d24fff77a693d3988ad6432594ef81`. The reviewer independently read the
following existing journal records; no service operation or experiment was
performed by this reviewer. The affected isolated core unit was
`pipewireao-owner-eb3aa6e84a824b0cb7307881f8cd44c0-core.service`, core PID 753551,
and WirePlumber PID 753634. Monotonic journal timestamps and selected fields:

```text
2193760.161644 core Link49 bind resource39: state0 mask0 format0
2193760.162179 WP   Link49 0x555e82366670: state0 mask7 cached-format0
2193760.162610 core Link49 bind resource40: state1 mask3 format1
2193760.162440 WP   Link49 0x555e82352f00: state1 mask7 cached-format1
2193760.185672 core Link49 broadcast: state3 mask1 format1
2193760.185739 WP   Link49 0x555e82366670: state3 mask1 cached-format0
2193760.186067 WP   Link49 0x555e82352f00: state3 mask1 cached-format1
```

Cross-process journal arrival timestamps do not establish an exact total
order. The core's own records establish that a second bind encountered pending
STATE|FORMAT (3) with a negotiated format before PAUSED was broadcast with
STATE only (1). The two cached Link instances then disagree about format.
This directly supplies the intervening bind required by the source defect;
it is stronger evidence than a fresh observer merely seeing a format.

At the baseline, `src/pipewire/impl-link.c`, `global_bind:1036–1038`, writes
ALL (7) into shared `this->info.change_mask`, sends the initial snapshot to the
new resource, then resets that shared mask to zero. This erases pending FORMAT
(2) for already-bound resources. `info_changed:59–74` later broadcasts the
remaining mask and clears it. Native `link_marshal_info`
(`src/modules/module-protocol-native/protocol-native.c:1778–1801`) includes the
raw format even in a STATE-only event, but `pw_link_info_merge`
(`src/pipewire/introspect.c:553–555`) correctly copies it only when FORMAT is
set. Thus the creator's cached NULL survives PAUSED, and its format getter
cannot satisfy held-startup admission even though a newer observer sees the
negotiated format.

The earlier proposed negotiation-order explanation was not confirmed:
`complete_ready` advances to ALLOCATING, and the ordinary `check_states` path
commits `info.format` in `do_negotiate` before `do_allocation` can reach
PAUSED. The observed pending mask immediately before the second bind instead
identifies the confirmed publication defect. Rebinding through another
ObjectManager would refresh one observer while leaving this defect intact.

The inspected candidate `global_bind:1030,1042–1044` takes a local
`struct pw_link_info` copy, sets ALL on that copy, and sends it without
modifying the shared pending mask. This is the minimal source correction:
the newly bound resource still receives a full snapshot and the next broadcast
can deliver the pending FORMAT to every resource. The native marshal copies
the borrowed format/error/properties synchronously before returning, so this
stack snapshot adds no retained-pointer lifetime. No negotiation, scheduling,
buffer or scientific operation changes are needed. The final inspected
PipeWire diff removes the temporary diagnostic logs and retains only this
local snapshot correction (`global_bind:1028,1037–1039`).

**Disposition: corrected, with causal fail-before/pass-after evidence for the
FORMAT publication defect.** The reviewer independently read the saved
[core trace](startup-attempts/format-mask-pass-after-core.log) and
[WirePlumber trace](startup-attempts/format-mask-pass-after-wireplumber.log)
from the fifth isolated attempt, owner incarnation
`fd1984d544f4482f870ab2427db24c33`. At 19:23:55 the second bind again encounters
Link49 with mask3/format1; this time the PAUSED broadcast retains mask3.
The creator at `0x55f805a3e550`, initially mask7/format0, receives PAUSED with
mask3/format1, and Lua reports `AO link format present=true`. The other
observer also receives PAUSED mask3/format1. This demonstrates correction of
the original lost FORMAT update through the server, native cache and Lua
getter under the reproduced ordering.

This attempt subsequently fails at `ao-connections.lua:189`, `Expected ndarray
Format`; held startup therefore did **not** succeed. That parser failure is
separate from WPI-20. The primary reports the simulator remained connected at
sequence zero with the source held and no traffic, and reports clean PipeWire
and WirePlumber rebuilds after diagnostic removal. Those source-state/build
observations were not independently executed by this reviewer and are not
established by the two saved format traces alone. This disposition closes no
installed lifecycle, resource or coordinator-removal gate. No tests, builds,
source edits or live service actions were performed by this reviewer; only
this review record was edited.

### Fixed Choice format decoding review

**WPI-21 — negotiated Choice.None fields were interpreted as scalar Lua
values; High, high confidence; original failure observed, source remediation
partially reviewed, corrections pending.** The WPI-20 pass-after WirePlumber
trace reaches `format present=true`, then fails `Expected ndarray Format`.
The source explains the separate failure: `modules/module-lua-scripting/api/pod.c`,
`push_luapod:1249–1263`, represents Choice values as a tagged table. Contextual
Id choices therefore remain tables; String, Array and Fraction children have
no value-emission case in `push_primitive_values:994–1037`. Comparing the
unmodified parsed `mediaType`/`mediaSubtype` against strings cannot admit the
negotiated fixed Choice representation. The worker's identification of the
negotiated Choice.None properties is consistent with this source behavior;
the saved trace itself does not dump every property.

The first correction inspected in `src/scripts/lib/ao-connections.lua:185–230`
unwraps fixed Choice children and rebuilds a temporary Format object to
preserve contextual enum decoding. The additive C accessor
`spa_pod_get_choice_child:1316–1338` checks the Choice body header, rejects an
incomplete or nonintegral value extent, then returns an owned copy and the
number of stored values. `wp_spa_pod_get_choice_child` returns a borrowed-data
wrapper (`lib/wp/spa-pod.c:1795–1798`); copying before the automatic wrapper
release correctly gives Lua independent lifetime. The temporary object leaves
the original POD and property flags unchanged. The original element type,
schema, layout, shape/rank and declared rational-rate comparisons are retained.

Two corrections are required before accepting this candidate's full parsing
claims:

1. **Confirmed valid-input rejection:** `ao-connections.lua:203` requires
   `n_values == 1`. Native SPA fixation changes Choice kind to None while
   retaining stored Range/Enum values (`spa/include/spa/pod/iter.h:277–285`;
   `spa/pod/filter.h:398–410`). Thus Choice.None selects the first value but
   does not require physically singleton storage. Accept one or more complete
   stored values and consume the first; continue rejecting non-None and nested
   Choice. This is source-confirmed compatibility behavior, not an assertion
   that the current installed profile already hit the case.
2. **Confirmed validation-order gap; runtime reachability unqualified:**
   the initial `pod:parse()` at `:187` recursively parses all properties before
   the 32-field bound or extent checks. The later `value:parse()` at `:201`
   also parses Choice contents before invoking the new checked accessor.
   Existing `wp_spa_pod_iterator_next_choice` advances by `child.size`
   (`lib/wp/spa-pod.c:2861–2867`): a zero-size child with remaining payload
   does not advance, so legacy parsing can loop before the new accessor would
   reject it. Malformed-array children likewise require validation before
   legacy value iteration. Metadata-only object-ID/Choice-kind inspection
   followed by bounded child validation should precede recursive parsing.
   No malformed owner payload was injected; this review does not establish
   its reachability through the complete negotiated-format pipeline.

Required validation remains installed held admission with scalar and fixed
Choice fields, retained-value Choice.None, wrong schema/rank/shape/rate,
unfixed Choice rejection, and bounded malformed-body rejection. The primary
reports successful builds/syntax checks and a newly warming isolated attempt;
this reviewer ran none of them and has not observed its result. WPI-21 remains
open for the above source corrections and pass-after evidence. Only this
review record was edited.

### Julia calibration client migration: bounded source review

Scope: `deployment/julia/src/wireplumber_session_runtime.jl`, migrated callers
in `calibration_campaign.jl` and `heart_calibration_export.jl`, and calibration
exporter owner maps. No tests, builds, module loads, installations or live
commands were executed by this reviewer. Worker-reported module loading is
compile/load evidence only.

**WPI-22 — pre-dispatch failure suppresses required session cleanup; High,
high confidence; confirmed from source, remediation pending.**
`wireplumber_session_runtime.jl:324–331` sets `handle.stop_attempted=true`
before the read-only `_identity` lookup and before `checked` computes the
remaining command budget. If the stage deadline expires or identity lookup
fails before submission, no stop effect has occurred. Nevertheless
`calibration_campaign.jl:602–606` skips its separate 320-second abort cleanup
because this flag is already set. A live session can be left running after
the stage exits without ever submitting its intended stop.

Track mutation uncertainty at the actual dispatch boundary, after identity
and command-budget preconditions. A pre-dispatch failure must permit the
independent cleanup path. An uncertain dispatched stop must not be blindly
retried; allow bounded read-only reconciliation of unit/process/cgroup and
the exact invocation's cleanup ledger. Required validation: deadline expiry
and query failure before dispatch, command timeout after dispatch, and
successful cleanup reconciliation without a second uncertain stop effect.

**WPI-23 — failed start leaves its linked unit and lacks cleanup verification;
Medium, high confidence; confirmed from source, remediation pending.**
`wireplumber_session_runtime.jl:145–153` submits stop on a failed startup but
does not verify the invocation cleanup ledger, retain a final receipt, or
remove the exact runtime unit link created by `:135`. For example, successful
link followed by daemon-reload failure leaves a registration even when stop
succeeds. Failure after owner launch likewise gets only the stop command's
exit status, without the cleanup-complete/error checks used by normal
`stop!`. No Handle is returned, so the caller's cleanup cannot finish this
work. A link-command timeout can also occur after registration but before
`linked=true`; that outcome needs read-only reconciliation.

Reconcile the reserved unit and any known invocation on failed start, retain
cleanup evidence, and remove only the symlink whose target matches this
stage's installed instance after quiescence is established. Preserve both
the original failure and any incomplete cleanup result. Required validation:
link/reload failure, startup failure before/after owner creation, uncertain
link/start outcome, and mismatched-link refusal.

The inspected successful path preserves the selected authority boundary:
installation/start/stop use bounded one-shot systemd commands, while session
Start/Stop are direct native commands to WirePlumber. No scientific transition
state machine or legacy coordinator forwarding was added. `_identity`, the
stage receipt and `_ledger` match unit, invocation, PID, start ticks and
cgroup; owner verification checks each retained owner incarnation and process
membership. Native selection requires one matching UUID locator, then fresh
Status on its retained endpoint and exact WirePlumber PID/control-instance/
remote checks. `ready` accepts only fresh READY or RUNNING; `running!` sends
Start only from READY and requires another live RUNNING observation. No
automatic mutation retry was found. These are point-in-time proofs; systemd's
name-based stop remains non-atomic with its prior identity query.

Direct acquisition Status uses the declared calibration profile, owner PID
and endpoint instance. The existing completion/report checks still require
a fresh successful paused owner snapshot, restored/released ownership and
matching typed current/report cursors before saved scientific reports are
accepted. HEART reduction binds the retained cleanup ledger to the captured
unit/invocation, WirePlumber identity, session UUID and owner identities, and
checks the independently retained final report count. Successful normal stop
checks old-process absence, cgroup emptiness, cleanup-complete and no cleanup
errors before saving its final ledger. Its unlink guard matches the runtime
symlink target to this stage's installed instance; no unrelated-unit unlink
was identified in that successful branch.

Calibration owner maps follow the source/sink owner and the graph roles that
generated the owner arguments; this pass found no confirmed mismatch there.
End-to-end calibration, scientific invariance, abrupt authority death,
uncertain effects and stopped-evidence reduction remain runtime qualification
gates. WPI-22 and WPI-23 require source correction before accepting the new
client’s complete failure/cleanup path for coordinator deletion.

### WPI-21/22/23 remediation recheck

**WPI-22 — source remediation reviewed; runtime validation pending.**
Current `wireplumber_session_runtime.jl:517–527` performs identity and command
budget checks before setting `stop_attempted` at the dispatch boundary.
Pre-dispatch failures therefore permit the caller's abort cleanup. A submitted
stop proceeds to `_stopped_record`/`reconcile_stop!` (`:475–513`), which poll
the retained incarnation, process/cgroup absence, jobs and exact cleanup ledger
without sending another stop. `calibration_campaign.jl:613–618` now uses this
observation path with a fresh cleanup deadline after an uncertain submitted
stop. Failed service outcomes remain errors after their cleanup evidence is
saved; they are not relabeled successful. The original source defect is
corrected. Injected deadline/command/query failures remain unrun.

**WPI-23 — source remediation reviewed; runtime validation pending.**
Failed startup now always enters `_reconcile_failed_start!` (`:152–247`),
including an uncertain link-command result. It validates the owned symlink
and loaded FragmentPath before any stop, tracks observed invocation/cgroup,
submits at most one cleanup stop, and requires repeated quiescent unit/job
observations. A started invocation requires an exact cleanup-complete ledger,
no cleanup errors, no outstanding owner jobs or live owner units, and absent
retained owner processes/empty cgroups. It saves the final ledger and original
failure, then removes only its matching runtime link. Missing cleanup evidence
or mismatched identities produce an explicit cleanup failure. The previous
unverified stop-only branch and unconditional linked-unit residue are removed.
Fault injection and systemd lifecycle qualification remain pending.

**WPI-21 — principal source corrections reviewed; one schema-validation
correction remains.** `ao-connections.lua:192–257` now checks the object size,
reads only object/Choice metadata, bounds the top-level property loop, and
selects the seven public numeric ndarray Format IDs. It unwraps Choice.None
with at least one complete value, checks scalar widths and the shape Array's
Int width/count before the final bounded temporary-object parse, and does not
recursively parse unused fields. Numeric builder keys avoid the Audio:rate/
NDArray:rate short-name collision. Owned child-copy lifetime remains correct.
The new metadata accessors check relevant body extents; the selected-child
type checks reject nested Choice. The earlier prevalidation recursive parse
and physical-singleton assumptions are corrected in this inspected path.

The corresponding Julia `native_parameter_source.jl:268–287` also accepts
fixed None with retained complete alternatives, rejects nonzero Choice flags,
zero child size and incomplete extents, and copies only the first child.
The reviewer read [fixed-choice-default.jl](fixed-choice-default.jl) and its
[saved output](fixed-choice-default.log). The script demonstrates the old
singleton predicate rejects a valid fixed default, the corrected helper reads
Int32 value 5 while retaining the original alternatives, and an unfixed Range
is rejected. The reviewer did not execute it. This supports the Julia cold
format conversion only; it is not Lua/runtime or callback-allocation evidence.

Residual WPI-21 source defect (`ao-connections.lua:234–235`): schema checks run
after `lua_pushstring` (`api/pod.c:1103`) has truncated at the first NUL. SPA's
`spa_pod_body_get_string` only checks that the final body byte is NUL
(`spa/pod/body.h:234–244`). A body containing the expected schema followed by
NUL and extra bytes ending in NUL therefore passes parsed equality and the
ineffective search for NUL. Retain the selected String byte extent and require
the parsed byte length to equal its body length minus one terminating byte
(`get_size() - 9`). This rejects hidden suffixes without changing the generic
Lua parser. No such malformed negotiated schema was injected; the defect is
source-confirmed and its complete-pipeline reachability remains unqualified.

The primary reports successful builds/syntax/module loading and a new isolated
unit warming. Those statements do not establish admitted startup. No new live
actions or tests were performed by this reviewer; only this record was edited.

**WPI-21 final source recheck — source remediation reviewed; installed and
negative-case validation pending.** The final `ao-connections.lua:222–224`
captures `schema_size` from the selected String after Choice default
extraction. At `:235–238`, parsed schema byte length must equal
`schema_size - 9` (eight-byte POD header plus one terminating NUL), in addition
to UTF-8 validity and the existing schema equality. A hidden interior NUL now
shortens Lua's parsed string relative to the declared child body and fails
this comparison. A Choice.None's retained alternatives do not inflate the
comparison because the size comes from its copied default child. This closes
the residual WPI-21 source defect identified above.

The primary reports syntax/diff checks passed. Its currently warming isolated
incarnation `1c104…` was staged before this final negative-case check; any
positive result from that artifact must preserve that revision distinction.
No current-candidate installed startup, malformed-schema test or broader
lifecycle qualification is established by this source recheck. The reviewer
performed no tests or live operations and edited only this record.

### Required registry loss: Lua wrapper identity review

**WPI-24 — removal checks index captured objects with a fresh userdata
wrapper; High, high confidence; source-confirmed defect, remediation pending.**
`ao-connections.lua:30–34` uses `catalog.captured[object]` inside the
ObjectManager removal callback. Captures at `:60–61`, `:119–120` and `:395`
use earlier Lua wrappers. These wrappers are not interned: signal argument
conversion (`wplua/closure.c:90`, `value.c:342–344`) calls `wplua_pushobject`
(`object.c:219–225`), which always calls `lua_newuserdata`
(`userdata.c:25–40`). Its `__eq` compares the underlying GObject pointers
(`userdata.c:104–115`), but Lua table indexing uses raw userdata identity and
does not invoke that equality metamethod. Thus the later removal callback's
fresh wrapper cannot find the earlier required-object table key even when
both wrap the same GObject. This suppresses that immediate required-loss
notification for captured Nodes, Ports, Clients and Links.

The reviewer independently read the existing isolated-unit journal: parameter
owner `pipewireao-owner-1c10460020d247ed831377b1d99fc0ad-parameters.service`
reports `negotiated parameter format differs from declaration` at 20:00:15
and exits unsuccessfully at 20:00:16. The session unit `wf-0710` later reports
`direct session did not warm before publication deadline` at 20:03:16;
WirePlumber's recorded fault at that time is publication failure. The primary
also observed two paused frame Links and the disappearing parameter Link, with
no source release. Those graph/source observations were not independently
replayed by this reviewer. The source defect explains why the removal callback
does not fault; it does not, without further callback evidence, establish why
every separate Link state/destroyed handler also failed to terminate startup.

The alternative bound-ID hypothesis needs a precise distinction. Ordinary
registry removal notifies ObjectManagers before deactivating BOUND
(`lib/wp/private/registry.c:519–524`), then invalidates the global ID at `:539`.
That path does not establish early invalidation as this attempt's cause.
However, owned-proxy destruction can notify via removal of OWNED_BY_PROXY
(`global-proxy.c:285–297`, `registry.c:499–503`) after `proxy_event_destroy`
has cleared the native proxy (`proxy.c:269–277`); `bound-id` then returns
SPA_ID_INVALID (`proxy.c:464–466`). Consequently deleting
`objects[object["bound-id"]]` is not a reliable cleanup identity for all
supported removal paths.

Minimal remediation: resolve the incoming removal wrapper against retained
objects using explicit GObject `==`, delete the map entry by its saved key,
and check captured wrappers using the same explicit equality. The captured
scan must also handle a creator Link wrapper distinct from the ObjectManager
wrapper; indexing only by the latter would retain the defect. Alternatively,
capture immutable numeric identity at addition with an equally reliable way
to recover it after destruction. Do not change WirePlumber's generic wrapper
cache or infer safety from a possibly invalid live bound ID. The controller
removal path already uses `row.node ~= node` (`ao-session-control.lua:210–215`)
and correctly invokes GObject equality.

Required validation: loss of each required Node/Port/Client/Link during
CONFIGURING and after admission, owned-proxy removal after BOUND loss,
unrelated removals, replacement ID reuse and intentional withdrawal suppression.
Use the existing parameter-owner failure as the first fail-before/pass-after
case and retain the exact fault timestamp/cause. No experiment, test or live
service action was performed by this reviewer; only read-only source/journal
inspection and this review-record edit were performed.

**WPI-24 remediation recheck — source correction reviewed; focused mock
evidence inspected; installed required-loss qualification pending.**
Current `ao-connections.lua:30–45` scans retained map values using explicit
GObject equality and deletes their saved numeric key. It separately scans
captured keys with the same equality, clears every matching wrapper and emits
one loss notification unless withdrawal is intentional. This fixes the
fresh-wrapper table-key defect without consulting a removed proxy's live
bound ID. Duplicate removal does not repeat the loss, and removing an old
object cannot delete a different object that reused its numeric ID.

The reviewer read `/tmp/wp-wpi24-check.lua` and the saved baseline
`/tmp/wp-wpi24-before.lua`; the reviewer did not execute either. The mock uses
distinct full-userdata wrappers whose equality compares a retained proxy
identity, verifying that raw table lookup misses while explicit equality
succeeds. It drives all four manager removal callbacks, multiple captured
wrappers, invalid live BOUND IDs, repeated removal, replacement ID reuse,
unrelated removal and withdrawal suppression. The worker reports baseline
failure in 8/8 required-removal cases and 11 passing corrected checks. The
two phase names in the mock are labels for repeated callback cases; no real
CONFIGURING/admitted session state machine, GObject signal marshalling,
PipeWire registry or systemd owner exit is exercised. Thus this is focused
Lua callback evidence, not an installed lifecycle test.

Distinct creator and registry **GObjects** remain a separate path: their
underlying pointers differ, so explicit equality intentionally does not
correlate them. The primary retained the creator Link's existing state and
`pw-proxy-destroyed` callbacks for that case. This recheck neither changes
that decision nor establishes why those callbacks did not independently fault
the earlier installed attempt. The parameter-format failure remains under
separate investigation. No live services, tests or production files were
changed by this reviewer; only this review record was edited.

### Sparse parameter format rate correction

**WPI-25 — an omitted sparse rate was incorrectly required to remain absent
after negotiation; High, high confidence; source correction and isolated
fail-before/pass-after evidence reviewed.**
The saved [owner failure](parameter-format-fail-before-parameters.log)
reports otherwise identical received/declared F32_LE, shape `(253, 3600)`,
ROW_MAJOR and `org.calculon.ao.pwfs-reconstructor/1`; the sole difference is
received rate 500/1 versus declared `nothing`. The previous callback required
`format.rate === nothing`, causing the parameter owner to reject the negotiated
format. The primary reports owner exit 1 in that isolated attempt.

`native_parameter_source.jl:139–192` permits no rate field in saved sparse
declarations and constructs `NdArrayFormat` without a rate. The operating
contract (`operations.md:85–88,236–239`) distinguishes sparse parameters from
repeated frame cadence, and `config.rs:1444–1448` rejects a repeated-data rate
declaration on sparse parameters. Absence of a declared constraint therefore
does not require the negotiated peer format to omit a rate property.

The corrected `on_param_changed` predicate (`native_parameter_source.jl:313–316`)
accepts the negotiated rate when the source has no declared rate, while
retaining rate equality when a source format explicitly contains one. Type,
shape, layout and schema equality remain mandatory. This does not add rate
support to the saved declaration grammar. Successful callback execution adds
no diagnostic logging; detailed received/expected formatting occurs only on
mismatch. Sparse publication still requires `source.phase == PENDING` and
advances to SUBMITTED after one queued buffer (`:241–257`); the correction adds
no periodic publication or frame control. No allocation/performance guarantee
was measured in this review.

The reviewer read the [isolated probe](parameter-format-probe.py),
[retained bootstrap client](parameter-format-connect.jl),
[pass-after owner log](parameter-format-pass-after-parameters.log),
[pass-after client log](parameter-format-pass-after-connect.log), and
[registry snapshot](parameter-format-pass-after-registry.json). The probe
starts a private core, FGN and parameter owner, retains its bootstrap client,
and creates the parameter Link. The pass-after client receives successful
Connected then Quit/Stopped completions. The primary reports parameter-owner
and client exit 0; these exit codes were printed by the probe harness rather
than included in the two saved process logs. The registry snapshot captures
the Link with the same 500/1 ndarray format while its state is **negotiating**.
It proves neither PAUSED nor WirePlumber READY admission. No frame source is
launched by this isolated probe, so it is not a frame-processing or scientific
equivalence run.

**Disposition:** corrected for the isolated negotiated-rate rejection,
with reviewed source and saved successful owner-lifecycle evidence. Full
WirePlumber startup, parameter submission/adoption, failure handling and
scientific qualification remain separate gates. The primary's newly running
full-startup experiment has no result asserted here. The reviewer ran no
tests or services and edited only this review record.

### Stopped sparse parameter publication

**WPI-26 — stopped parameter submission waited for a process callback that
need not occur; High, high confidence; fail-before evidence/source correction
reviewed, deferred-effect fencing correction pending.**
The saved [failure trace](stopped-parameter-fail-before.log) shows direct READY
Status with three owned Links, successful stopped Reset and submitted scalar
update, followed by parameter operation 521 returning FAULT with `Internal
session effect expired; outcome unknown`. The prior owner publication path
depended on a process callback, while a stopped graph need not schedule one.
The trace supports the failed stopped operation and unknown outcome, not a
claim that the payload was adopted or that its owner operation completed.
The trace's timing is consistent with the five-second internal session-effect
budget; it does not establish a fifteen-second timeout.

The inspected correction extracts `_publish_pending!`
(`native_parameter_source.jl:241–267`) and invokes it immediately after staging
under the ThreadLoop lock (`:429–443`), when buffers are added (`:297`), and
from existing process/state callbacks. PipeWire `stream.c:1070–1077` puts an
output buffer on its free queue before emitting add-buffer. Its public
dequeue/queue functions (`:2552–2633`) do not require STREAMING. For reliable
output, an outstanding queued buffer or HAVE_DATA returns EAGAIN instead of
offering a replacement (`:2558–2565`). The stream does not request RT_PROCESS
or driver flags; `stream.c:2102–2105` places non-RT processing on the main loop.
The actor call is locked, and native callbacks execute on that loop. The
inspected source therefore supports stopped queueing without forcing graph
processing or frame cadence.

Only successful `queue_buffer!` changes the phase to SUBMITTED. Completion
still reports submission with `active_adoption_observed=false`; staging and
copying alone do not produce an accepted submission receipt. No already queued
buffer is rewritten. The actor resets a cancelled PENDING phase to IDLE under
the lock, and teardown clears phases before closing streams. Buffer/copy
exceptions retain failure and do not report successful submission. No
callback-allocation or latency guarantee was measured.

**Remaining confirmed source gap:** `_publish_pending!` checks only PENDING
and `source.failure`. If initial staging cannot dequeue a free buffer, a later
add-buffer/process callback can execute after the request deadline or after
controller removal but before the actor resumes at `:462–468` to check the
ticket and clear PENDING. The callback can then queue an expired/invalid
request. ThreadLoop serialization prevents simultaneous mutation but does not
make the earlier ticket validation fresh. Each deferred publication attempt
needs the current request/owner validity check at the effect boundary, with a
separate explicit-initial-payload case; a large payload copy must not bypass
the final pre-queue validity decision. Retain submission uncertainty if queueing
already occurred; never relabel it unapplied or replace its queued buffer.

**Disposition:** stopped queueing mechanism is source-supported; WPI-26
remains open for deferred publication fencing and pass-after evidence. The
primary's isolated publication probe and next full startup were still pending
at this review. Required cases include first stopped submission, reliable
queue occupied by an unconsumed update, buffer arrival after deadline or
controller loss, explicit initial payload, queue failure and teardown. The
reviewer performed no tests or service actions and edited only this record.

**WPI-26 deferred-publication remediation recheck — source correction
reviewed; runtime and negative-case evidence pending.**
`NativeParameterSource` now retains a `Publication` containing the exact
parameter endpoint/ticket, an explicit `initial_pending` flag, the bootstrap
runtime and a distinct revocation error. `_publication_valid!` is called before
dequeue and after the payload copy immediately before queueing. Both attempts
check atomic bootstrap cancellation and loop-owned bootstrap endpoint health.
Before controller retention, the exact currently applying bootstrap Connect
ticket must still be valid; afterward, its retained controller must remain
present. A requested payload additionally checks its exact applying parameter
ticket, including deadline and controller identity. Initial payloads require
their explicit preload flag and have no fabricated parameter request ticket.

The reviewed check avoids `Bootstrap.preparation_check!` and never takes
`runtime.lock` from a PipeWire callback. This matters because bootstrap
`_ready` holds that lock while invoking a hook that takes the ThreadLoop lock
(`native_owner_bootstrap_runtime.jl:339–342`). Instead, the fence reads the
atomic cancellation flag and endpoint/controller state owned by the loop;
the nested `Endpoint.check_ticket` only reacquires the existing recursive
ThreadLoop lock. The retained controller is refreshed by native info/removal
callbacks. No ThreadLoop-to-runtime-lock inversion was found in this path.

If validity fails, the pending phase and publication authority are cleared
and the actor is woken for failure handling. If the second check fails after
dequeue, the `finally` block returns the unqueued buffer. If no free buffer
exists, the request remains pending with its exact authority and every later
callback repeats the checks. The actor's deadline timer and controller-change
wake continue to resolve a pending request even when no buffer callback
arrives. Successful queueing alone sets SUBMITTED; later cancellation cannot
turn that outcome into an unsubmitted receipt. Initial-payload failure remains
an owner failure, and teardown clears all pending authority before closure.

The source gap recorded under WPI-26 is corrected in this inspected candidate.
The worker's module-load/negative checks and the primary's publication probe
were not run or claimed passed by this reviewer. Full stopped-publication,
deadline-after-copy, controller-loss and no-free-buffer cases still require
their own evidence. This review clears the scoped source blocker, not an
installed lifecycle or performance gate. Only this review record was edited.

## WPI-27 — unused inherited systemd template

**Severity:** medium. **Confidence:** high. **Disposition:** corrected;
independent scoped source review found no confirmed defect.

A fresh random instance can report LoadState=loaded because systemd resolves a
shared template. Requiring not-found rejected JFG before any owner was launched.
The guard now accepts only inactive, never-run instances with zero PID, empty
invocation/cgroup, no jobs/runtime or exact instance files, and a genuine template
FragmentPath. After installing the private exact instance, it requires that exact
retained link/fragment before Start. Pre-Start cleanup preserves the inherited
template and removes only its own verified link.

The saved `inherited-template-probe.log` and
`session-template-guard-check.jl`/`.log` cover classification/fragment checks;
they do not exercise every job/path/cleanup race. The actual JFG incarnation in
[the session checks](SESSION_CHECKS.md) subsequently reached fresh Ready and
completed 512 exchanges, native Quit and full cleanup while the shared FGN
template remained untouched. No general systemd race-qualification claim follows.

## Coordinator removal review

The Rust Statig runner, Julia DeploymentRunner, their session realization and
supervisor runtime roles are retired. Direct session selection requires the
WirePlumber profile, UUID, exact live NodeInfo identity and fresh Status on the
retained client. No supervisor fallback or reconnect policy remains.

Independent source review of `native_session_client.rs`,
`native_session_transport.rs` and `session_cli.rs` found no confirmed regression
in exact request correlation, terminal-before-retirement ordering, permanent
unknown-outcome retirement or no-retry behavior. Public operations cannot match
private admission completions. Runtime timeout/disconnect injections specific
to the rewritten Rust client remain a validation gap; this source review does
not close that gap. Scientific-owner execution and local acquisition controls
remain separate from session policy.

## Final calibration integration findings

| ID | Severity / confidence | Observed source defect | Correction and disposition |
| --- | --- | --- | --- |
| WPR-01 | High / high | Fresh calibration exports inherited session-manager paths but omitted the sealed WirePlumber assets, so one-shot installation rejected them. | Copy sealed inherited WirePlumber assets and validate them before final hashing. Independent recheck found the source correction complete; [production export/install](calibration-export-install-check.jl) and [output](calibration-export-install-check.log) pass. This uses a placeholder calibration executable and does not qualify acquisition. |
| WPR-02 | Medium / high | Normal calibration shutdown used systemctl cleanup and labelled it successful public shutdown without native Quit acknowledgement. | Normal shutdown now sends exactly one verified native Quit, requires Offline/shutdown acknowledgement, then observes exact systemd cleanup. Persisted attempt/acknowledgement prevents another Quit after uncertainty. Emergency cleanup has a separate result. Independent recheck found no remaining scoped defect; [live shutdown](jfg-final-sdk-shutdown.log), [acknowledgement](jfg-final-sdk-shutdown-attempt.json) and [cleanup](jfg-final-sdk-cleanup.json) agree on the retained invocation. |

The [focused checks](native-quit-focused.log) contain 76 assertions, eight
specifically covering native Quit ordering. Full calibration campaigns,
uncertain-outcome injection and timeout/disconnect matrices remain separate.
