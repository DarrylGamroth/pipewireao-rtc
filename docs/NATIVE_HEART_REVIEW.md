# Native HEART control review

Review date: 2026-10-06. This is an independent source review of the HEART
wrapper migration under RTC-DEV-030. It does not qualify the unchanged vendor
HEART executable or a scientific calibration/correction run.

## Reviewed state and scope

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
Branch: `work/native-control-planes-20261005`.
Starting HEAD: `03f72c1f8ef1f10b574f46735d7b7a5e7f4fe027`.
The worktree already contained the primary agent's uncommitted native client,
endpoint, HEART owner, exporter, deployment, HIL caller and test changes.
Those changes were inspected without resetting, committing or editing them.
The reviewer's sole output is this document. No scientific workload or live
vendor process was launched by this review.

Authority: [operations](operations.md), [architecture](architecture.md),
[roadmap](roadmap.md), and the selected
[HEART wire contract](NATIVE_HEART_CONTROL.md). The
[shared client evidence](NATIVE_CONTROL_CLIENT_VALIDATION.md) and
[HEART client evidence](NATIVE_HEART_CLIENT_VALIDATION.md) are validation
records, with the narrower scopes stated there.

The review covers identity admission, request/effect ordering, reset deadline,
controller and transport loss, cleanup, saved-report binding and the HIL health
consumers. It does not revisit HEART's numerical algorithm, vendor TCP command
implementation, scientific gains or configuration coefficients. Existing
vendor INIT/RUN/ENABLE_HRT_FLAGS/CORRECT/SHUTDOWN operations are retained.

## Findings and dispositions

### NH-001 — An absent snapshot can erase generation fencing

Severity: P2. Confidence: high. Classification: confirmed defect, reproduced on
an actual private core. Disposition: primary accepted the minimal fail-closed
fix; independent source and fail-before/pass-after evidence verification passed.

Affected code:
[NativeHeartClient.require_ready](../deployment/julia/src/native_heart_client.jl),
[NativeControlClient.observe!](../deployment/julia/src/native_control_client.jl),
and the missing-snapshot case in
[the connected HEART fixture](../deployment/julia/test/native_heart_client.jl).
At the reviewed revision, `require_ready` lines 54–60 check the expected
generation/child/ingress only when the newest completion has a snapshot.
`observe!` replaces its retained completion with every newer valid completion.
`NativeControlEndpoint.take!` deliberately completes an expired or removed
queued ticket with a negative result and no snapshot, preserving Ready.

The following sequence therefore passes the final check incorrectly:

1. Admit snapshot S₁ for generation 1.
2. Observe a successful Reset completion carrying generation 2. Checking S₁
   now correctly fails.
3. Observe a newer failed completion with lifecycle Ready and snapshot None,
   for example from an expired queued request belonging to another controller.
4. Call `require_ready(client, S₁)`. The capability is Ready and the absence of
   a snapshot skips the entire identity predicate, so the function succeeds.

The native health API has forgotten evidence that S₁ is obsolete. The current
HIL callers also check `/proc/<old-child-pid>`, which normally rejects the old
child after reset; this limits the immediate caller impact but does not repair
the native subscription contract. This finding does not claim an observed
scientific run continued with the wrong process.

Selected remediation: the primary selected fail-closed behavior when the latest
completion or snapshot is absent. `require_ready` now throws `UnknownOutcome`
in that case, requiring a fresh successful Status before health-authorized work
can continue. It always compares the expected identity when a snapshot is
available. The owner still advertises Ready and its failed completion still
contains None; no child facts or Fault state are invented. The review inspected
the minimal change and confirmed it implements this decision without adding
mutable profile state or changing the wire contract.

Validation: the extended connected fixture exercises S₁ → Reset/S₂ → a newer
Ready/None completion and requires that S₁ remains rejected. A fresh Status then
reestablishes S₂; S₁ still fails and S₂ succeeds. It also requires unknown health
after Ready/None before reset. The prior 44-check fixture tested None before
reset and generation rejection immediately after reset; it did not distinguish
this sequence. The independently inspected logs show **53 passed / 1 failed
before** (the stale S₁ check threw no exception) and **54/54 passed after**.

Evidence root: `/home/dgamroth/.cache/rtc-live-controls-20261005/`.
Logs: `native-heart-client-fail-before-20261006.log` and
`native-heart-client-post-fix-20261006.log`.
Post-fix summary: `native-heart-client-2038358824876979/summary.json`.
The summary identifies wrapper fixture PID 3522286, child PIDs 3522375→3522422,
endpoint instance 2038364759228252 and generations 1→2. The fixture uses a sleep
child; this evidence does not validate vendor HEART effects.

### NH-002 — Maintained adapter instructions still use removed arguments

Severity: P3. Confidence: high. Classification: confirmed documentation defect.
Disposition: resolved; primary corrected the adapter instructions and the
independent followup review compared them with the parser and exported argv.

[HEART_CALIBRATION_ADAPTER.md](HEART_CALIBRATION_ADAPTER.md), in “Association
and owner integration sequence,” directs the operator to supply
`--controller-request` and `--controller-reply`. The migrated
[option parser](../deployment/hil/owner_protocol.jl) rejects those names and
requires `--controller-node`, `--controller-pid`, `--controller-instance` and an
absolute private remote for HEART transport.

Remediation: document the actual launched wrapper PID and generated incarnation
bindings and the new exact endpoint arguments. Identify historical examples as
historical where necessary. The inventory can retain its historical interface
description while its migration disposition is updated after qualification.

Required validation: compare the documented invocation with the maintained
parser and exported owner argv. This is a documentation change, with no wire or
scientific compatibility impact.

Followup verification: the maintained adapter instructions now supply
`--remote`, `--controller-node`, `--controller-pid`, and
`--controller-instance`, explicitly bind the actual spawned wrapper PID, and
describe fresh native report/digest admission and the missing-snapshot health
fence. The removed controller file arguments are no longer presented as the
current invocation.

### NH-003 — Shutdown queries a process PID after that process has exited

Severity: P1. Confidence: high. Classification: confirmed defect in the new
Shutdown path. Disposition: primary accepted retention of the spawned PID;
remediation independently verified against source and portable process evidence.

Affected code: `HeartOwner.apply!(::HeartCommand{:shutdown})`, `report` and
`snapshot` in [heart_owner.jl](../deployment/julia/src/heart_owner.jl).
The followup implementation calls `stop`, which waits for the child to exit,
then `report`, which obtains the child PID using `getpid(owner.child)`.
`snapshot` uses the same operation. In Julia 1.12.7, `uv_return_spawn` clears the
process handle on exit and `Libc.getpid(::Process)` throws ESRCH when the handle
is absent. The local authoritative runtime source is
`~/.julia/juliaup/julia-1.12.7+0.x64.linux.gnu/share/julia/base/process.jl`,
functions `uv_return_spawn` and `Libc.getpid`.

Consequently, after successfully stopping the real child, the owner cannot
produce its requested Stopped report/snapshot. It enters the failure path;
the outer failure report repeats the same invalid PID query. The lifecycle
fixture initially missed this because it saves `child_pid` before stopping its
sleep child and builds its own snapshot instead of calling `HeartOwner.snapshot`.

Fail-before evidence was independently inspected in
`~/.cache/rtc-live-controls-20261005/heart-exited-pid-before.log`: actual
production `snapshot` and `report` both raise
`IOError: getpid: no such process (ESRCH)` after the owned child with PID 3532716
has exited. This is a portable process-lifecycle reproduction, with no vendor
HEART or scientific workload.

Required remediation: retain the actual child PID when it is spawned and use
that retained generation identity in both reports and snapshots after exit.
Clear/replace it deliberately with the corresponding process generation; do
not infer or guess a PID. A portable production-owner regression should stop a
real owned sleep child, then exercise both actual `report` and `snapshot`,
asserting the retained PID, nonalive state and recorded return code. The actual
owner Shutdown/completion/publication path still needs integration evidence.

The new `native_heart_vendor.jl` fixture also obtained `getpid(owner)` in its
finally cleanup after the wrapper might already have exited. The primary
corrected that fixture by retaining the actual spawned wrapper PID for its
owned-process-group cleanup.

Pass-after verification: `Owner.child_pid` is initially absent, assigned from
the actual process immediately after spawn, retained after stop, and replaced
on the next successful spawn. Reports, snapshots and live `/proc` probes use
that identity. The reviewer inspected these paths and the six new production
snapshot/report assertions in `test_heart_owner.jl`. The independently inspected
`~/.cache/rtc-live-controls-20261005/heart-exited-pid-after.log` records **31/31**
portable checks passed, including the six stopped-child checks. They establish
retained PID, nonalive state, return code and process absence after an actual
owned sleep child exits. This resolves NH-003; it does not substitute for the
remaining actual owner Shutdown and terminal-publication integration checks.

## Reconstructed implementation contracts

### Identity and dispatch

The HEART exporter places the wrapper first in the owner list, binds an
explicit private remote, and supplies an endpoint node name and positive
incarnation. The deployment runner obtains `HEART_OWNER_PID` from the actual
spawned wrapper process before substituting the subsequent simulator argv.
The generic client verifies owner PID, profile, endpoint incarnation, registry
global ID, object serial and full NodeInfo. Its exported controller marker must
appear in the owner's admitted controller list before connection returns.

The endpoint is an inactive no-port Filter on the wrapper's own Core/ThreadLoop.
Its callback decodes a bounded ticket. `consume_native!`, running on the existing
owner loop, takes and applies it outside the PipeWire loop lock. Admission and
terminal storage retain one pending ticket, one completion and one independent
rejection. The previously reviewed generic endpoint mechanisms are reused.

### Reset and failure ordering

Reset first checks the active ticket, then selects
`min(ticket.deadline, current_time + 12 seconds)` and publishes Preparing.
It stops and reaps the old child, checks the active ticket again, and starts
the replacement. Startup checks the controller/core before required vendor
commands, verifies listener ownership and selected ingress, validates the
declared placement, writes the startup report and seals the generation report.
Only then does it publish Ready and attempt the successful correlated
completion. `complete!` checks the applying ticket, caller lifetime and original
deadline before publishing success.

An exception after reset starts attempts to stop the replacement, publishes
Fault when the endpoint still permits publication, and propagates failure to
wrapper cleanup. Loss of the core or publication channel cannot be converted
into a fabricated successful result. Generic clients preserve unknown outcome
and do not reconnect, retry or fall back to JSON. Cleanup closes the endpoint,
Core and Context under the native loop lock, then closes the loop. Emergency
child reaping can continue after the request deadline; the code does not treat
that cleanup as an extension allowing a late successful completion.

These statements describe source ordering, not measured vendor command
response time or hardware behavior. Controller/core removal during a blocking
vendor command is checked after that command returns and before subsequent
required startup work; no immediate interruption claim is established.

### Saved reports and HIL consumers

Each successful startup creates a new `heart-generation-N.json` and records
its SHA-256. A fresh native Status supplies the report path, digest, generation
and child identity. The caller requires the exact generation filename under
the declared runtime, rejects a symlink, bounds its read to 64 KiB, checks the
digest and verifies report owner/generation/child identities. It rechecks
subscribed readiness after reading the artifact.

Calibration and correction admission retain their ingress, configuration,
startup acknowledgement and scientific input checks against this bound report.
Their repeated health checks now use subscribed native authority and the
expected process presence. The saved JSON is evidence rather than repeatedly
polled live status. With the NH-001 fix, missing current child identity blocks
health-authorized work until a fresh successful Status supplies a snapshot.

## Validation gates and limits

The connected fixture's initial 44/44 and fixed 54/54 results are private-core transport
evidence with an owned `sleep` child. It does not call `HeartOwner.start`, execute
vendor TCP startup commands, validate vendor placement, or exercise the actual
HIL calibration/correction owner. The primary agent reports passing codec,
owner-unit and parser suites; this reviewer inspected source and the evidence
descriptions but did not rerun those suites.

NH-001 is fixed and independently verified within the stated CPU fixture scope.
Actual unchanged-vendor qualification must additionally
exercise fresh admission, Status, reset with old child reaping/new generation,
original deadline, caller loss during effects, core loss and wrapper cleanup.
Installed calibration/correction report admission and subsequent health
fencing need their own integration evidence. These are open validation gates,
not claims that the corresponding implementation is defective.

Finite CPU functional results must remain separate from scientific acceptance,
convergence, allocation, throughput, accelerator behavior and physical
camera-to-DM or real-time qualification. No such qualification is granted here.

## Followup: native preparation, Connect and Shutdown

The followup source extends the operation profile with Connect=3 and Shutdown=4
and removes the wrapper's prepared/connect/connected/quit marker fields. Its
descriptor declares the exact native profile and node. Deployment still records
the actual spawned wrapper PID and positive incarnation. Client admission waits
through Preparing to Ready and obtains fresh Status followed by Connect under
the original preparation deadline. Connect reuses the status effect and grants
no scientific state or graph ownership.

Shutdown applies the existing child-stop operation outside callbacks, verifies
the applying ticket again, publishes Stopped and completes the request with a
nonalive snapshot. After successful terminal publication, `flush_terminal!`
requests the public asynchronous `sync!` barrier and waits for its exact core
done sequence under the same ticket deadline before endpoint teardown. The
local PipeWireAO `sync!` contract returns precisely the sequence delivered to
`on_done`; the owner checks core ID zero and performs callback reads/writes under
the ThreadLoop lock. If synchronization fails after completion, the exception
path does not replace that already-retained completion with a conflicting
negative completion.

Deployment shutdown uses its existing admitted HEART client. Missing admission,
transport loss or unknown outcome leads to the existing owned-process-group
cleanup; it does not reconnect or retry native Shutdown. Source shutdown/link
revocation precedes wrapper shutdown in the normal cleanup sequence. The
independently verified NH-003 fix supplies the retained stopped-child PID needed
by the terminal report and snapshot.

The followup lifecycle fixture's own dispatcher tests typed Connect and Shutdown
with a sleep child. At initial followup inspection it neither called
`HeartOwner.flush_terminal!` nor removed the endpoint before the client observed
completion, and its `time() + 0.1` readiness delay started before connection
setup. That fixture alone therefore cannot establish terminal synchronization
and removal ordering, or reliably demonstrate admission while Preparing.
Those checks remain explicit actual-owner integration gates unless a later
discriminating fixture establishes them. No source defect in the public core
synchronization sequence is asserted without such evidence.

## Source identities at initial review

SHA-256 values below identify the uncommitted source inspected for this pass.
They must not be interpreted as identities of later primary-agent edits.

| Source | SHA-256 |
| --- | --- |
| `deployment/julia/src/native_heart_client.jl` | `062f92c85101d0a6e0cd6121a6c1f43dc2dafb2cbb8e8221b64186e93c9b0180` |
| `deployment/julia/src/native_heart_codec.jl` | `c1f70372764fe46b1905a66a6a5f056d9b03e797d6bac51ad092159cb930fc37` |
| `deployment/julia/src/heart_owner.jl` | `5bfd662bfaaa4f9f49755b087640778a921a26e757e31c4fcbb082ceadc3dd7e` |
| `deployment/julia/src/native_control_client.jl` | `965207fc8823a4fde6d5ad4363b4aab431124395bb4a76433b39ea37652ce5de` |
| `deployment/julia/src/native_control_endpoint.jl` | `8a3f1de64dce7f6b985bfcae25e24230a1514774c2cbd75a004bd0bde6b3ac96` |
| `deployment/julia/src/deploy.jl` | `cd3c8ca52a6dbd03867192b2fc958786e6f9a5ac69e50f41f744ea267c4cf780` |
| `deployment/julia/src/heart_export.jl` | `4bb8dfaa3823a4f948bdbe7d059b81bd38e04b6ed7e486005b2f1a3ace264b2c` |
| `deployment/hil/native_heart_control.jl` | `d8bc323ae2d5c8dfcc24b2463c9255e34b1225dc31fbab16cd8406c46241788a` |
| `deployment/hil/heart_calibration_owner.jl` | `7f4c06cebfef8901cdfff16d5e2e2d959b79948305397eded17e695513bcacda` |
| `deployment/hil/heart_correction_owner.jl` | `51cde481211fe1cc16799a26f0d781e13b445abb9d96ced86837c9330ad62ea0` |

Independently verified NH-001 remediation identities:

| Source | SHA-256 |
| --- | --- |
| `deployment/julia/src/native_heart_client.jl` | `4ccf5de39803286aeeae9b4357b21b7869402a00b46d1e3360471b095905155e` |
| `deployment/julia/test/native_heart_client.jl` | `12c146cf5a43eac579f2007faad71fabed715ce26a365769f32fb422b5963ad2` |

Followup source identities after NH-002/NH-003 verification:

| Source | SHA-256 |
| --- | --- |
| `deployment/julia/src/heart_owner.jl` | `ded603534f80adeca17bce32f4df78967149656ba4fd2e8cb953eca10f2bba09` |
| `deployment/julia/src/native_heart_client.jl` | `e700d1aeb7932cbc0bce9ab0609c546b29f9ce9a90f89d33dbf42553e12ea4ba` |
| `deployment/julia/src/native_heart_codec.jl` | `4178d916e125828014fcf1b742f036699ff59fa3e607a7c712db40478b36adaa` |
| `deployment/julia/src/deploy.jl` | `643fd4f3b1f137e4f26bde5db99d6760a9dc28c2f5d9d097e841df9c2f031a6c` |
| `deployment/julia/src/heart_export.jl` | `dafce943517cad63e9044ad34c31c36efc46e703a02be8004bc9ae3926bf2a28` |
| `deployment/julia/test/test_heart_owner.jl` | `1ec2e2e371af6f23e1197022bff6fc8d7721a5b92e36f30f999195ca82bf306b` |
| `deployment/julia/test/native_heart_vendor.jl` | `82c93b196d3490b8441199133ff73b770004a568e1468383f1275125c8535b7f` |
| `docs/HEART_CALIBRATION_ADAPTER.md` | `0edd81cb3e6b24d1e6015126bc09afac020175c71dfeaeaa1b522bc7e6abb356` |
