# WirePlumber realization and withdrawal design

## Status and scope

The opt-in integration passes native primitive, clean deployment, held adapter
retry, all eight required-loss and fresh-admission checks for Copper
complete-frame CPU FGN/JFG with CUDA AOS. Acceptance is limited to their
functional, numerical-preservation and simulator-allocation evidence. It does
not qualify systemd supervision, target timing or physical actuation.

Source baseline: RTC `8886d6ac35c41f71b532f610a15c36f4f63c40be`, initially clean
worktree `/tmp/rtc-wireplumber-realization-20261007`, branch
`work/wireplumber-realization-20261007`. CPU0/1 are excluded; scientific artifacts
are preserved. HEART and the desktop session remain outside this work.

WirePlumber realizes and withdraws the declared session links. RTC retains the
native GUI/CLI lifecycle, scientific readiness and source/acquisition authority.
Default direct RTC link ownership remains available. The opt-in path follows
the revised ownership requirements and the evidence scopes below.

Use one ephemeral RTC-owned Filter per realization, inactive and without
ports. Its immutable typed `SPA_PARAM_Props` snapshot identifies the runtime,
manager and ordered declared endpoints by exact global ID and serial, including
each link's passive flag. The only mutable field is a monotonic typed Id phase:
`Prepared = 0`, `Realize = 1`, `Withdraw = 2`. Prepared never authorizes links;
Realize is published only after RTC binds the exact marker identity. No saved file or JSON
metadata is live authority. No command bus or alternate graph-authoring format
is introduced.

In Realize, WirePlumber resolves exact Port and Client incarnations, checks
Port parent node IDs, and creates
standard, non-lingering PipeWire Links in downstream-first order. RTC validates node serials and actual node/client provenance before projection,
before admission and while admitted. This avoids Lua ObjectManager subscribing
to every scientific Node's Props; its public constructor activates all features.
RTC observes the actual link cohort, verifies ownership and negotiated Formats, and only
then completes readiness and releases the source. A Link factory call does
not atomically compare endpoint serials and create the Link. Admission can
reject a link created after an endpoint replacement race; the design does not
claim that a transient link can never exist.

## Lifecycle and withdrawal

Every realization has a unique generation and exact marker identity. Publishing
Withdraw permanently fences that generation. A Boolean cannot distinguish
initial preparation from withdrawal when intermediate snapshots are coalesced.
WirePlumber must handle a first observation of Withdraw even when it never saw
Realize, and must reject phase regression or immutable-cohort mutation. WirePlumber tracks every
pending activation. If a delayed callback arrives after withdrawal or for a
stale generation, it deactivates the captured link and cannot create or adopt
another link. Withdrawal waits for pending activation count zero, deactivates
all bound links, performs its own `Core.sync`, then calls `request_destroy` on
the Filter as its withdrawal acknowledgment. RTC accepts cleanup completion
only after a fresh, locally successful Withdraw submission for an observed live
marker, its subsequent removal and zero correlated links for that exact
realization. A marker already removed before that submission cannot supply the
acknowledgment. Alternatively, the exact manager Client disappearing with zero
correlated links fences the old non-lingering creator cohort; a replacement
manager cannot adopt the old intent.

Marker removal caused by runtime death initiates withdrawal. Manager loss
faults the realization; a manager replacement cannot adopt old requests and
must bind the exact new manager ID and serial for a fresh realization. The
same-generation retry path is fenced: unload/retry must complete withdrawal
before another generation can be admitted. Local Prepared-marker destruction is
allowed only when Realize was definitely never submitted. Once publication of
Realize was attempted, including unknown outcome, RTC must publish Withdraw and
wait for its fence before claiming successful cleanup. Loss of WirePlumber or its Core
must have bounded failure and cleanup behavior; process activity alone is not
acknowledgment.

The existing native runner endpoint remains the serialized lifecycle interface.
The realization object accepts no caller commands or request tokens; it is a
bounded typed Props projection of the sole RTC owner's intent. Existing caller
envelope rules continue to apply to GUI/CLI lifecycle endpoints. This narrow
projection and its destruction acknowledgement must be documented under
RTC-DEV-030 before production enablement. RTC keeps source
hold/release, science readiness, acquisition, admission failure, and terminal
fault decisions.

## Requirement allocation and evidence state

The ownership allocation is documented under RTC-DEV-003/013/030. [Evidence](validation/wireplumber-realization-20261007/README.md) distinguishes
primitive, deployed clean and failure checks. The default direct RTC link path
remains in force; the selected opt-in integration retains that fallback.

| Requirement | Candidate allocation | State |
| --- | --- | --- |
| RTC-DEV-001 | Preserve non-actuating runtime and existing native lifecycle; links carry only declared data paths. | Opt-in clean FGN/JFG deployments pass; non-actuating scope retained. |
| RTC-DEV-002 | Resolve every required node/port from the declared session and bind exact IDs/serials; verify actual cohort and negotiated Format before readiness. | Exact projection/admission checks implemented; clean three-Link cohorts pass. Negative checks retain their narrower source/native scopes. |
| RTC-DEV-003 | Create links downstream-first with declared passive semantics; RTC admits only the exact expected cohort. | Native primitive and selected deployed manager ownership pass. |
| RTC-DEV-004 | Treat failed/missing/replaced links as required-topology failure and fence readiness/source release. | Existing RTC checks remain active; all eight selected deployed loss cases pass with failed admission and whole-cohort cleanup. |
| RTC-DEV-006 | Keep optional observation separate; observer loss cannot revoke science readiness or own links. | Existing observer boundary remains; no transfer evidence. |
| RTC-DEV-009 | Tie lifecycle to the existing exact native runner endpoint and serialized dispatcher. | Existing native Stop/Reset/Resume/Quit passes for both selected engines. |
| RTC-DEV-013 | Preserve explicit endpoint/link ownership and cleanup semantics across unload/retry. | Normative optional ownership revised; held adapter Load/Unload retry passes for both engines. Native caller reload is not claimed. |
| RTC-DEV-021 | Bound runtime, WirePlumber and Core loss handling; latch failure and require fresh admission after recovery. | Selected runtime/manager/Core loss and fresh post-series admission pass with whole-cohort cleanup; no universal timing bound. |
| RTC-DEV-030 | Use native PipeWire control serialization for live authority; saved JSON/configuration cannot establish readiness. | Primitive Filter/typed intent and selected native deployed admission pass. |
| AAR-01 | Link lifetime changes to the selected manager; runtime/manager/core loss withdraws the realization without automatic repair. | Selected manager/runtime/Core loss and exact clean cohorts pass; no automatic repair. |
| AAR-02 | Exact generation/cohort, finite admission, cancellation and acknowledged withdrawal; stale callbacks cannot satisfy readiness or resurrect links. | Cold/native pending-withdrawal and deployed startup pass; adapter retry evidence remains distinct from caller reload. |
| AAR-04 | Preserve downstream-first negotiation and passive semantics for the selected complete-frame profiles. Latest/hold is not qualified by this slice. | Native and actual deployed three-Link passive/Format checks pass; latest/hold remains excluded. |
| AAR-09 | Reuse narrow upstream components, public native typed Props and standard Links; no metadata JSON command bus or alternate authoring format. | Public native mechanism, selected clean deployments and required-loss checks pass. |

## Verification obligations

The exported Filter's typed Props update and remote destruction semantics pass
isolated experiments. The following obligations remain authoritative for the
selected connection path; evidence distinguishes source/unit, cold policy,
native primitive and deployed checks rather than promoting one level to all
others:

- Missing, duplicate, wrong-owner, wrong-serial, wrong-port, wrong-Format and
  wrong-passive endpoints fail admission without source release.
- A link failure, removal, replacement, ID reuse, duplicate or unrelated link
  cannot satisfy the required cohort; failed state remains latched until a
  fresh realization.
- Cancellation before activation, during activation, after callback dispatch,
  and during withdrawal cannot resurrect a stale generation. Every pending
  activation is accounted for; a failed intermediate link is withdrawn.
- Unload followed by retry in the same process waits for the old marker removal
  and zero correlated links before admitting the new generation.
- Runtime death, manager loss/replacement, WirePlumber death/restart and PipeWire
  Core loss have bounded outcomes. Old requests cannot be adopted by replacement
  identities; cleanup failure remains a fault rather than success.
- Readiness and acquisition remain RTC-owned and occur only after verified
  realization. Retain exact identities, failure evidence and cleanup receipts.

Demonstrate fail-before/pass-after behavior for each claimed correction. Software
checks do not establish timing or physical-loop qualification. The selected
opt-in link owner is accepted after its scoped parity checks; the default RTC
owner remains available. Systemd supervision, native caller reload and broader
profile/timing qualification remain separate. Remove redundant code only after
the corresponding replacement is qualified.

## Known race boundary

The standard Link factory consumes endpoint IDs, not an atomic `(ID, serial)`
compare-and-create contract. WirePlumber must revalidate exact Port/Client serials before
creation; RTC validates node serials, actual creator provenance, the resulting
Link cohort and current endpoint
incarnations before readiness. An endpoint may still disappear or be replaced
between those operations, so a transient wrong-incarnation Link is possible.
The required guarantee is bounded withdrawal and rejection before admission,
not prevention of every transient server object. If that boundary is
unacceptable, this mechanism cannot qualify without a public atomic API.

## Decoder and trust boundary

The sole trusted RTC encoder emits a canonical bounded snapshot (at most 32
links and 16 KiB). Native Struct filtering rejects primitive-tag substitutions;
the policy checks the Props object ID and recognized outer properties. Lua
`parse()` folds duplicate outer properties into one table key, so this policy
is not a strict arbitrary-publisher decoder. No untrusted or physical-device
admission claim follows. Exact manager identity and marker creator checks
precede authority; malformed unknown markers cannot authorize link creation
or destruction. At most 32 matching marker scopes are retained.

Initial cache absence waits within the admission budget because the Port and
Client ObjectManagers populate independently. Explicit removal of a declared
endpoint fences the scope, even before initial discovery completes. Creator
proxy destruction and Link registry removal are monitored separately: upstream
`proxy_event_removed` only traces, so its creator proxy does not necessarily
emit `pw-proxy-destroyed` after external Link removal.
