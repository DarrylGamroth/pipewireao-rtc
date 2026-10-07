# Independent systemd owner design review

Date: 2026-10-07. Baseline: `dde0bf44eb074ee1583e9fe5adbd2da411c1ecd6`.
Branch: `work/systemd-owners-20261007`.
Worktree: `/tmp/rtc-systemd-owners-20261007`.
The review began with only the proposed design untracked. Concurrent implementation
and probe files created by the primary agent were not modified by this reviewer.

Scope: [proposed owner allocation](../../SYSTEMD_OWNER_DESIGN.md), existing
`deployment/julia/src/deploy.jl`, generated service template, RTC-DEV-019–026/030
and AAR-03. Selected parity is Copper full-frame CPU FGN/JFG with CUDA AOS.
Scientific architecture, HEART and desktop services remain outside this review.
The initial pass was source and design analysis. The implementation follow-up below
includes independent private dummy-service probes. No science, timing or hardware
qualification was performed by the reviewer.

## Final disposition

The selected opt-in Copper full-frame CPU FGN/JFG deployment with CUDA AOS
passes the reviewed process-supervision migration gates at implementation commit
`c088103b30fadc629cfb4d0d072da08dc56723ae`. All nine findings are corrected or
resolved within explicitly stated ownership boundaries. No confirmed defect
remains open for this selected scope. The final four installed receipts were
independently checked against actual installed files, numerical baseline payloads,
terminal state, cgroups and retained diagnostic directories.

The review accepts the 11 selected owner/coordinator fault cases and the final
refreshed core-loss/restart checks for both engines. Each engine completes four
512-command runs across two fresh coordinator cohorts; its 256-frame retained
prefix per run matches its own baseline exactly. Its four measured simulator
tails cover 1,024 exchanges with zero reported Julia heap allocation and GC.
This is not a latency/deadline, general multiple-endpoint, other-profile or
physical-system qualification. Same-user external unit replacement remains
outside the supported authority boundary. Unprocessed late manager messages and
manager outage are not promoted from unverified hypotheses to guarantees.

Historical sections below preserve findings and intermediate dispositions.
The final installed verification section at the end records closure evidence.

## Initial design assessment

Transient user services are a suitable process-ownership boundary. Retaining
native readiness, source control and thread-placement checks preserves the
scientific authority boundary. Process identity checks can avoid spawning
`systemctl` every 5 ms. `Restart=no`, invocation-scoped names and explicit
failure-cohort teardown are appropriate supported-workflow constraints.

The initial wildcard crash cleanup is incomplete: it can stop consumers before
ingress is revoked. The primary agent accepted an ordered private-core-first
fallback during review. The remaining findings specify implementation and
validation obligations; they are not claims that unwritten code has failed.

## Findings

### SOR-01 — Crash cleanup needs its own ingress ordering

Severity: high. Confidence: high. Evidence: observed design omission; derived
ordering defect. Disposition: accepted remediation plan; implementation and
verification pending.

The initial design's service-identity section sends an invocation-wide stop from
`ExecStopPost`. Its normal native shutdown order cannot run after coordinator
SIGKILL. A wildcard stop permits consumer termination while the external source
and private core still run. RTC-DEV-021/025 require ingress revocation before
consumer cleanup. Existing `_stop_processes` explicitly stops the core when a
source pause is unconfirmed (`deploy.jl:980–1014`).

The accepted proposal runs the installed cleanup CLI from `ExecStopPost`, stops
the exact private-core unit first, confirms that its cgroup is empty or absent,
then stops the other invocation-owned units. It does not reconnect scientific
clients. Core absence is sufficient only after pending core starts have also
been reconciled (SOR-03). Failed or uncertain revocation must remain a cleanup
fault; it cannot authorize consumer teardown. Native orderly shutdown remains
the normal path. `ExecStopPost` also runs after failed startup and unexpected
exit, so its input must tolerate incomplete initialization. See the upstream
[service lifecycle documentation](https://raw.githubusercontent.com/systemd/systemd/v256/man/systemd.service.xml).

Cheapest validation: dummy source/core/consumer services with timestamped
termination events; kill the coordinator and assert core cgroup emptiness
precedes consumer stop. Include a core descendant ignoring TERM and a core-stop
timeout. Repeat during partial startup, before READY notification.

### SOR-02 — A namespace is not an atomic incarnation fence

Severity: high if replacement fencing is claimed without qualification;
medium within exclusive supported ownership. Confidence: high.
Evidence: observed API and proposed identity checks; derived race.
Disposition: accepted authority clarification; mismatch tests pending.

The proposed coordinator invocation in a unit name prevents a fresh coordinator
from accidentally targeting the previous cohort. It does not prevent an owner
unit being manually restarted under the same name. The manager's `StopUnit`
method takes a name and job mode, without an expected invocation identity.
Checking InvocationID, PID/start ticks and cgroup before a later stop request is
therefore not an atomic compare-and-stop. Cgroup paths can also be reused.
See the upstream [manager API](https://raw.githubusercontent.com/systemd/systemd/v256/man/org.freedesktop.systemd1.xml).

The primary agent proposes an explicit supported-workflow invariant: one
coordinator owns each invocation namespace, role names are never reused in that
invocation, `Restart=no`, and same-user external replacement is outside the
authority/security guarantee. That is a defensible local deployment boundary.
Reject observed mismatches and do not advertise protection against arbitrary
same-user manager manipulation. A crash hook that has only the namespace can
provide cohort cleanup, but cannot recover a lost per-owner identity merely from
the pattern. If manual replacement becomes supported, this design needs a
stronger lifecycle protocol before claiming replacement-safe destruction.

Cheapest validation: insert an already-visible replacement before identity
verification and assert rejection; ensure retries never reuse a role name;
preserve an unrelated similarly named service and a different invocation.
Document the remaining query-to-stop race instead of treating a passing static
mismatch test as an atomicity proof.

### SOR-03 — Unknown launch completion must remain owned work

Severity: high. Confidence: high for the missing recovery obligation; medium
for a late queued request escaping cleanup. Evidence: derived from asynchronous
manager ownership; late-request escape is an unconfirmed hypothesis.
Disposition: accepted pending-launch registration and reconciliation plan;
fault injection pending.

The direct `spawn` registers the actual child immediately after successful
creation (`deploy.jl:536–549`). With transient units, the manager can accept a
start while `systemd-run` fails, times out or is killed before the coordinator
retains MainPID/InvocationID. A cleanup loop over retained successful handles
would omit this service. Merely discovering active units once also does not
address queued starts or units still activating.

Register the exact intended unit name before submission. On any unknown launch
outcome, prohibit scientific release and reconcile that name, invocation-scoped
units and outstanding jobs with the manager. Keep short-lived launch clients
inside the coordinator cgroup so they cannot submit more starts after its
post-stop hook begins. Stop/cancel pending starts, reconcile within a finite
overall deadline, and confirm empty cgroups. Manager inability to establish
closure is an explicit cleanup failure.

An unprocessed request on another D-Bus connection arriving after enumeration
is a remaining ordering hypothesis, not a demonstrated leak. The smallest useful
experiment delays completion after manager acceptance, kills the coordinator,
and checks both jobs and cgroups after the cleanup hook returns. Also test a
queued start held behind a deliberately blocked dependency. Record whether the
chosen manager/client interaction leaves any later start possible; do not infer
that from a single empty `list-units` result.

### SOR-04 — Preserve launch arguments, role environment and working directory

Severity: medium. Confidence: high. Evidence: observed existing launch contract
and documented transient-service behavior. Disposition: implementation gate.

The direct backend passes an explicit environment, role working directory and
argument vector (`deploy.jl:494–543`). Transient services run in the manager's
environment, and `systemd-run` normally enables argument environment expansion.
Naively substituting the launcher changes literal dollar arguments, relative
configuration lookup, selected library paths and Julia artifact overrides.
See upstream [transient launch documentation](https://raw.githubusercontent.com/systemd/systemd/v256/man/systemd-run.xml).

Pass the effective role environment and working directory deliberately; disable
argument expansion with a supported `--expand-environment=no` capability or an
equivalent exact encoding. Filter coordinator-specific manager variables such as
`NOTIFY_SOCKET`, `INVOCATION_ID` and watchdog state; each service must receive its
own manager identity. Preserve CPU leader initialization as well as role thread
envelopes. Explicit effective RT/memlock and warmed-thread checks remain required:
the coordinator's preflight is not evidence about independently spawned owners.

Cheapest validation: an argument/environment/CWD echo owner with spaces, percent
and dollar characters, then a relocated SDK launch. Inspect selected library,
Julia depot, actual limits and every warmed thread before ingress. Feature
preflight must reject unsupported systemd options before starting the cohort.

### SOR-05 — Budget the complete fallback and preserve failure evidence

Severity: medium. Confidence: high. Evidence: observed existing 300-second
coordinator stop allowance and proposed additional sequential cleanup.
Disposition: implementation gate; finite completion unverified.

The current service grants `TimeoutStopSec=300`; the deployment also exposes
`CLEANUP_TIMEOUT_SECONDS=300` (`deploy.jl:37`). A cold Julia cleanup helper adds
startup, manager queries, core stop, other-owner stops and cgroup checks. Finite
per-command deadlines alone do not establish that the complete helper finishes
inside its enclosing allowance. A manager outage must not leave the helper
blocked indefinitely. This is a lifecycle completion obligation, not a latency
qualification claim.

Use one monotonic overall cleanup deadline, finite subprocess waits and explicit
remaining budgets; validate that generated unit allowances accommodate the
chosen stages. Preserve failure status and exact unresolved names/cgroups in
durable evidence or journal output. Existing runtime-directory removal
(`deploy.jl:1458`) must not erase the only diagnostic record while ownership
remains unresolved. The user manager itself dying is outside any guarantee that
depends on its `ExecStopPost` execution; declare that boundary separately from
coordinator death under a functioning manager.

Cheapest validation: cold helper execution, a TERM-resistant descendant, an
unresponsive manager-client stub and identity mismatch. Measure complete elapsed
cleanup, assert a bounded failure and retain the failed names. No throughput or
real-time inference follows from this check.

## Required closure evidence

1. Resolve SOR-01–03 with focused dummy-unit failure tests before science runs.
2. Preserve native incarnation checks, source hold/release/reset and all-thread
   placement across both process backends; record functional controls separately
   from service ActiveState.
3. Run the selected installed Copper CPU FGN and CPU JFG cohorts with CUDA AOS,
   controls/reset, required owner/manager/core loss, coordinator death and fresh
   admission. Preserve exact numerical prefixes and inclusive allocation/GC tails.
4. Record systemd version, selected executables/prefixes, unit properties,
   coordinator and owner invocation identities, cgroups and failure outcomes.
   Keep desktop and unrelated services untouched.
5. Independently inspect the final implementation and update each disposition.
   This review does not close implementation or parity gates.

No new scientific architecture, broker, custom process reaper, scheduling loop,
or high-frequency systemctl polling is recommended. A persistent manager event
subscription may be useful later, but is not necessary to establish the selected
process-identity health check and cold start/stop scope.


## Implementation follow-up

Reviewed `systemd_owners.jl`, its callers in deployment/session-manager/native
supervisor controls, runtime copying and installation, the generated service
unit, and `qualify_systemd_owners.jl`. Systemd owner module SHA-256 at the successful
independent probes:
`31d0f7343b23708bbf43a467936a5d66cea2d4d14217f639c16cfaa6e26cc342`.
The independent probe used systemd user manager `257.13-1~deb13u1`, CPU 2,
unique private UUID namespaces and the cached installed Julia project. It did
not build dependencies or start scientific owners. Unrelated units were untouched.

Reproduction script: [investigate.jl](investigate.jl).
Evidence: [receipt](investigation-results/receipt.json),
[unknown-launch receipt](investigation-results/unknown-reply.json),
[probe output](investigation.log) and
[hook verification](hook-verification.log).
The receipt is the last successful complete probe run. Earlier harness attempts
encountered a Julia parser error and an idempotent cleanup mistake (second stop
of an already collected dummy blocker); neither was a production failure.

| Finding | Current independently established disposition |
| --- | --- |
| SOR-01 | Core-first function and actual cold ExecStopPost after coordinator SIGKILL pass dummy ordering checks: consumer termination observes the core cgroup absent; both owner cgroups empty and no pending starts. Installed Copper FGN/JFG coordinator-loss closure is independently checked below; this does not add a crash-revocation latency claim. |
| SOR-02 | Supported authority boundary is documented. Actual same-name service restart changes InvocationID; retained handle stop rejects it and replacement remains alive until deliberate probe cleanup. Atomic query-to-stop protection remains outside the stated boundary. |
| SOR-03 | Pending handle retention exists before submission. A private coordinator runs actual `launch!` through an injected client that returns 23 after successful manager acceptance: launch throws, retains the live identity, and exact cleanup succeeds. A core start queued behind a private never-ready notify service is canceled without executing. Arbitrarily delayed unprocessed D-Bus creation is not proved impossible by these probes. |
| SOR-04 | Source and both final installed SDKs verified; recorded native owner/PID/thread placement and exact per-engine prefixes preserve the selected launch/environment contract. No per-poll systemctl calls. |
| SOR-05 | Crash helper uses a 45-second overall operation deadline and finite subprocess waits inside a 300-second coordinator stop allowance. Cold hook completed in the dummy probe. Manager outage, TERM-resistant descendants and worst-case enclosing bounds were not independently exercised here. |
| SOR-06 | Confirmed defective substring hook check replaced by exact selected launcher/argv and one non-ignored command; focused fail-before/pass-after check and actual private coordinator acceptance pass. |
| SOR-07 | Corrected source/no-source caller guards and delayed native quit. Same focused test against baseline: 2 passed, 10 failed; current function: all 12 passed. |
| SOR-08 | Corrected terminal reporting independently verified by focused checks and final installed core-loss cases in both engines. |
| SOR-09 | Corrected source and 32/32 focused checks independently verified; both final installed core-loss runs preserve diagnostics after exit, and both engine restart cohorts pass. |

### SOR-06 — Required crash hook verification accepted a no-op command

Severity: high. Confidence: high. Evidence: observed source and focused
fail-before/pass-after check. Disposition: corrected and independently verified
within selected generated-unit serialization.

Initial `cleanup_hook_valid` searched for the cleanup subcommand anywhere in the
serialized ExecStopPost. `/bin/echo cleanup-systemd-owners --invocation
${INVOCATION_ID}` therefore passed while doing no cleanup. The exact old predicate
accepted this fixture; the current selected-launcher predicate rejects it.
`coordinator(unit; launcher=...)` now checks one complete generated hook command,
including its executable, argv and `ignore_errors=no`. Normal and crash probe
coordinators with the correct hook passed validation. This establishes the
selected generated-unit format, not parsing of every possible arbitrary service.

### SOR-07 — Normal cleanup proceeds after revocation remains unknown

Severity: high. Confidence: high. Evidence: observed caller control flow;
derived conditional ordering failure, then reproduced by the same test before and
after remediation. Disposition: corrected and independently verified for the
injected source/core/native uncertainty cases.

In `_stop_processes`, source pause can fail and exact source/core stop can also
fail because the manager is unavailable or retained identity no longer matches.
`revoked` then remains false, but the final reverse owner loop still stops
consumer services. The no-source path likewise stops remaining owners when
`ingress_stopped` remains false after core stop failure. These loops predate the
migration; the new intentionally refusing service stop makes their unmet
precondition explicit. Failing closed inside `SystemdOwners.stop!` is insufficient
if its caller proceeds with dependent teardown.

Gate consumer teardown on confirmed revocation and preserve the cleanup error
otherwise. This does not authorize adopting/replacing a mismatched owner.
Cheapest discriminating check: inject unconfirmed pause and source/core stop
failures, record requested owner stops and assert no consumer stop follows;
then confirm the same consumer cleanup runs once core/source revocation succeeds.
The crash helper already propagates core cleanup failure before consumer stops.


SOR-07 closure: the final implementation returns with an explicit cleanup fault
before RTC waits, native quit, owner unload or final reverse teardown unless
source/core revocation is confirmed. In the no-source path, native quit now runs
only after that guard, while the core is alive. The initial remediation left this
native quit before the guard; follow-up review found it, and the third test case
now covers an unknown native status result.

[check_ingress.jl](check_ingress.jl) loads just `_stop_processes` from either
baseline `dde0bf4` or current source into a fresh Julia process and runs the same
repository test with a distinct fake deployment type and actual private child
processes. It does not overwrite methods on production deployment types.
[Baseline output](ingress-baseline.log): 2 passed, 10 failed; recorded attempts
include RTC stop and native quit despite unknown revocation.
[Current output](ingress-current.log): 12 passed, 0 failed.
Current function SHA-256:
`78e92ef3b32bd137368f81bdae58e103550466ac95c7288a397fdb3d6cbda887`.

Source inspection also confirms failed cleanup retains its private runtime and
records `retained_runtime`; successful cleanup still removes the private run
directory. The opt-in service uses `RuntimeDirectoryPreserve=yes` to preserve
outer state/error evidence across service exit. These changes preserve diagnostic
files, not admission: `admitted` is false and the deployment remains failed.

At the end of the focused module review, no confirmed blocker remained. The
subsequent scientific integration gate exposed SOR-08 below. Scientific parity,
resource/timing qualification and the explicit unverified cases in the disposition
table remain separate obligations.


### SOR-08 — Exit fallback overwrites a completed failed cleanup report

Severity: high for truthful fault-state reporting. Confidence: high.
Evidence: observed Copper FGN core-loss receipt and source control flow.
Disposition: terminal-report remediation independently verified by focused tests
and the installed Copper FGN core-loss retry. Diagnostic-directory retention
has a separate residual defect, SOR-09.

The primary agent's installed Copper FGN core-loss run reached failed coordinator
state (exit status 1), revoked admission, and confirmed all recorded owner cgroups
empty. Its saved report nonetheless said `phase=stopped` while retaining a
required-core-loss error and cleanup errors. The acceptance gate correctly failed
with `owner loss did not revoke admission`; this diagnostic was triggered by the
incorrect terminal phase, not surviving admitted owners. An exact summary and
original receipt digest are preserved in
[atexit-fault-before.json](atexit-fault-before.json).

Source explains the mismatch: `_run_locked` now preserves its private runtime
when cleanup errors exist. The `main` atexit callback uses runtime existence as
its cleanup trigger. It therefore runs cleanup again after the completed failed
run, assigns `phase=stopped` on the second stop's success, then unconditionally
removes the runtime that was retained for diagnostics. A successful repeat stop
cannot clear the original deployment failure.

Track completion of the normal `run` cleanup independently of directory
existence, suppress repeat cleanup after that path has completed, and preserve
prior failure plus retained diagnostics if emergency exit cleanup is actually
needed. Verify both paths in fresh Julia processes and preserve the original
fault before rerunning the live core-loss gate. The failure concerns control-plane
reporting and cleanup bookkeeping; no numerical delivery or scientific algorithm
defect was established by this evidence.


SOR-08 remediation review: `main` now registers a completion flag with its exit
callback and sets it in the `finally` surrounding `run`. A completed normal
cleanup therefore suppresses the emergency path even when its diagnostic runtime
remains. `_finalize_record!` preserves an existing failure or cleanup error,
revokes admission, and removes the private runtime only when cleanup is confirmed.
The emergency path uses the same finalization policy and retains the original
owner failure even if its own stop succeeds. Native broker-close errors now join
the cleanup record instead of bypassing final publication.

[check_terminal.jl](check_terminal.jl) exercised the current source helpers in a
fresh Julia process using cached dependencies. [Output](terminal-current.log)
records 21 passing assertions: completed-run suppression, prior failure plus
uncertain-runtime preservation, successful emergency stop preserving an earlier
owner failure, and clean emergency stop. Helper SHA-256:
`7d2138faab07e718ae7b16dfd12cfdc59d81340a98b28e9b28ca86ca9d8a1b64`.
These focused checks do not replace the installed core-loss rerun. The failed
original acceptance result remains preserved above.

The reviewed no-source preflight cleanup now also treats absence of any core
handle as absence of ingress. This is justified because the coordinator records
every pending core handle before submitting launch; an unknown launch does not
meet the absent-core condition. The focused terminal fixture covers the clean
no-launch case, while SOR-07 tests continue to cover existing uncertain core
handles.

The qualification restart path now passes the live coordinator PID to
`wait_state(expected_owner_pid=...)`. It rejects conflicting PID arguments and
waits for a matching locator before connection; readiness and UUID still come
from native queries. This addresses the observed old-locator/deleted-remote
failure without promoting saved files to readiness authority.


SOR-08 installed verification: independently read the successful Copper FGN
core-loss retry receipt, compared its terminal fields with the still-present
on-disk `state.json`, and queried all four exact owner service names. The report
remains `phase=failed`, `admitted=false`, with the original required-core-loss
error and cleanup errors intact. The coordinator exited with status 1; every
recorded owner now has MainPID 0 and its cgroup is absent. Current installed
`deploy.jl` matches the reviewed worktree byte-for-byte. These checks are saved in
[atexit-fault-after.json](atexit-fault-after.json), including the exact original
receipt SHA-256. This closes the false `phase=stopped` defect for this installed
case. It does not claim completion of the remaining qualification series.

### SOR-09 — Julia deletes a retained runtime after deployment cleanup finishes

Severity: medium. Confidence: high. Evidence: observed missing retained runtime,
installed Julia source, and discriminating fresh-process probe.
Disposition: repaired; independently verified by the actual `_run_locked`
subprocess-exit regression and final installed core-loss/restart cases for both
selected engines.

The successful core-loss retry still names
`/run/user/1000/rtc-sd-fgn-core-20261007-retry2/run-rdtQpc` as retained, but that
directory is absent at independent inspection. The outer state file remains
correct, and all owners are gone. `_run_locked` creates this directory with
`mktempdir(base; prefix="run-")`. Julia 1.12.7's installed `base/file.jl` defines
`cleanup=true` by default and registers the directory with `temp_cleanup_later`.
Julia's separate exit cleanup therefore removes it even when the deployment's
completed-run callback correctly does nothing.

The focused terminal fixture uses `mkpath`, so its runtime-retention assertions
do not exercise temporary-directory registration. A fresh-process probe using
the production creation expression loses its diagnostic directory on exit;
otherwise identical `cleanup=false` creation preserves it. Both outcomes are
recorded in [runtime-retention-probe.json](runtime-retention-probe.json). The probe's
own scratch directories were removed after inspection.

Use `cleanup=false` for this explicitly lifecycle-owned run directory, retain the
existing explicit success-path removal, and add a subprocess-exit retention test
that covers the actual creation policy. Check the next installed fault case for
both truthful failed state and existence of its retained diagnostic directory.
This defect affects evidence retention, not the confirmed process/cgroup closure
or admission revocation of the core-loss retry.


SOR-09 source verification: the runtime creation now explicitly uses
`cleanup=false`; existing success-path removal remains in `_finalize_record!`.
Reviewed the new test: it invokes actual `_run_locked` in a fresh Julia process,
forces failure immediately after runtime creation without launching owners, then
checks saved failed state and retained-directory existence after process exit.
This covers the production creation policy omitted by the earlier `mkpath`
fixture. An independent rerun of the complete terminal cleanup file passes all
32 assertions; [output](terminal-retention-current.log) includes all five checks
in the new subprocess case.

Verified source SHA-256:
`b93855c7446ced6d8e747b7ddaa79ffe0071289fe48d115f130917e564e49e90`.
Verified terminal test SHA-256:
`be8b03a01f2a50775454e8a6e3e87c332212d7bb34737e3a210e28c3f6972664`.
These checks establish the source correction. Earlier installed receipts used a
frozen SDK and support their recorded failed-state/cgroup claims; they do not
establish this later directory-preservation fix. Refreshed core-loss/restart
qualification is still pending at this review update.


## Committed implementation and initial installed fault matrix

Implementation reviewed at `c088103b30fadc629cfb4d0d072da08dc56723ae`.
No production changes followed that commit at this inspection. The diff remains
within deployment process supervision, its installation/control adapters, focused
tests, qualification tooling and related documentation. Direct supervision is
still the default. Scientific graph/calibration algorithms, HEART and desktop
services are not changed by the implementation diff.

Independently inspected all 11 archived fault receipts and re-queried their exact
owner units and cgroups. Receipt set:

| Engine | Required loss cases | Archived receipts |
| --- | --- | --- |
| Copper CPU FGN + CUDA AOS | core, simulator, WirePlumber manager, RTC, coordinator | [core](initial-installed/fgn-core/receipt.json), [simulator](initial-installed/fgn-simulator/receipt.json), [manager](initial-installed/fgn-manager/receipt.json), [RTC](initial-installed/fgn-rtc/receipt.json), [coordinator](initial-installed/fgn-coordinator/receipt.json) |
| Copper CPU JFG + CUDA AOS | core, simulator, WirePlumber manager, RTC, Julia graph owner, coordinator | [core](initial-installed/jfg-core/receipt.json), [simulator](initial-installed/jfg-simulator/receipt.json), [manager](initial-installed/jfg-manager/receipt.json), [RTC](initial-installed/jfg-rtc/receipt.json), [Julia](initial-installed/jfg-julia/receipt.json), [coordinator](initial-installed/jfg-coordinator/receipt.json) |

Observed checks:

- Each receipt succeeds, records held/reset source sequence 0 in native Ready,
  then injects loss during Running at source sequence 16–18 before completion.
- All 50 recorded owner unit names contain the corresponding coordinator
  InvocationID and expected role. Their MainPIDs match native ready process and
  placement identities. All 267 recorded thread placements exclude CPUs 0 and 1.
- All 50 exact owner units now report MainPID 0 and inactive/failed state. Their
  recorded cgroups and all 11 coordinator cgroups are absent or empty. No manager
  jobs remain in these invocation namespaces.
- The nine owner-loss receipts preserve `phase=failed` and `admitted=false`.
  Coordinator SIGKILL ends its ability to update files: those two saved reports
  remain stale `running`/`admitted=true`. Their closure is established by failed
  manager state, vanished MainPID and empty cgroups. Saved status is not promoted
  to live admission authority.
- The archived [final focused log](focused-tests-final.log) independently sums to
  215 passing assertions out of 215, including invocation parsing, hook checks,
  launch arguments, uncertain ingress, native controls and terminal cleanup.

These records support RTC-DEV-019's effective placement gate for the recorded
cohorts, RTC-DEV-021's required-owner/coordinator failure closure, and the held
source/native reset behavior of RTC-DEV-025. Source review preserves installed
opt-in selection and no implicit start (RTC-DEV-020/023), scientific/native
control ownership (RTC-DEV-022/030), and separate manager link authority
(RTC-DEV-003/013). The coordinator's high-frequency admission check reads process
identity; systemctl remains on cold lifecycle/failure paths.

These are fault-cohort checks, not complete numerical replay, allocation-tail,
sustained cadence or latency qualification. The frozen installed SDK used here
predates the final `cleanup=false` change, so it establishes truthful terminal
reports and process closure but not SOR-09 diagnostic-directory retention.
Final refreshed SDK core-loss/restart receipts and complete-run parity remain
pending at this review update. The explicit same-user replacement boundary and
unverified manager-outage/late-D-Bus hypotheses remain as recorded above.


SOR-09 installed closure: independently checked the refreshed
[FGN core-loss receipt](final-installed/fgn-core/receipt.json), SHA-256
`7278f42ce5f7027edec0f14b98cb59c544604f2715b84f0cf1d3ede2a7dc09bb`.
It records success, failed/unadmitted terminal state, the original core-loss
error, and `retained_runtime_present=true` after coordinator termination.
Its retained `run-S0uh2v` directory still exists at independent inspection, and
the adjacent state file exactly matches the receipt's phase, admission, error,
cleanup errors and retained-runtime fields. All four owner-final records report
MainPID 0 and empty cgroups; independent queries confirm inactive/failed owner
units and absent/empty recorded cgroups.

The installed deployment source is byte-identical to `c088103` and has SHA-256
`b93855c7446ced6d8e747b7ddaa79ffe0071289fe48d115f130917e564e49e90`.
This closes the Julia automatic-directory-deletion defect with installed
fail-before/pass-after evidence. It does not establish completion of the final
JFG core-loss or either engine's refreshed restart/complete-run series, which
remain pending at this update.


## Final installed verification

Independently verified all four final archived receipts:
[FGN core loss](final-installed/fgn-core/receipt.json),
[FGN restart](final-installed/fgn-restart/receipt.json),
[JFG core loss](final-installed/jfg-core/receipt.json) and
[JFG restart](final-installed/jfg-restart/receipt.json).

| Final gate | Independently established result |
| --- | --- |
| Installed source and sealed package | All 122 tracked SDK files in each package match `c088103` byte-for-byte, including all 45 source modules. All 843 FGN and 842 JFG sealed artifact hashes match actual files. The respective 650/649 non-SDK artifacts match both the preserved hashes and actual WirePlumber-realization base files. |
| Identity and restart | Each engine has two completed restart cohorts with different coordinator InvocationIDs and native deployment UUIDs. Final descriptors and qualification-script hashes match the corresponding receipts. |
| Native hold/reset/control | Every final cohort records Ready with source paused at sequence 0 before its run/fault step. Reset changes acquisition generation between the two complete runs in each restart cohort. Successful native quit is followed by stopped/unadmitted clean reports without cleanup errors. |
| Link ownership and invariants | Each cohort has the declared three negotiated links, owned by the recorded WirePlumber client; passive policy is two passive and one non-passive link. The successful qualification checks retain link identities, formats and creator-client identities after each complete run. |
| Fault reports and retained diagnostics | Both final core-loss cases preserve failed/unadmitted reports and their original fault. Both saved retained directories exist after coordinator exit; actual state files match the receipt fields. |
| Owned closure | All 27 owner instances across the six final cohorts have MainPID 0 in the captured final records and at independent re-query. Their recorded cgroups and coordinator cgroups are absent/empty, with no jobs remaining in those invocation namespaces. |
| Unrelated GUI service | Read-only final check reports the original GUI unit active with MainPID 1632744. This review did not modify it. |

For each engine, four runs complete 512 frames and 512 commands each, totaling
2,048 exchanges. Every archived retained prefix contains sequences 1–256 in
order. Independently compared actual payload bytes for all eight runs against
these exact baseline directories:

- FGN: `/tmp/rtc-wp-policy-fgn-readmission-20261007/run-1`.
- JFG: `/tmp/rtc-wp-policy-jfg-readmission-20261007/run-1`.

All 16 frame/command payload files are byte-identical to their respective engine
baseline. Independently recomputed baseline hashes:

| Engine/payload | SHA-256 |
| --- | --- |
| FGN frames | `e206f4cd44096b6d020090e5bb44ee2dd1b62226e0ebe14fcdd6e6cb33075f59` |
| FGN commands | `946e1cb5dc5be9f3ee9059db5597fef1fa02020c2d81ba2aa51c208aacc8554a` |
| JFG frames | `b47321140763e9ba4c0eb6a7d56102aff54835a6ce2ba83418511b70270e71c0` |
| JFG commands | `349c6f6105a780236cd6bc402c8fc849293fdd300838e3f1d74706ed4f12e27f` |

Numerical equality is per engine and applies to the retained 256-frame prefix,
not unretained payloads or cross-engine bitwise equality. Delivery counts and
sequence validation separately cover all 512 exchanges per run.

Each run reports 256 measured exchanges after the retained prefix. Across its
four runs, each engine therefore contributes 1,024 measured simulator exchanges
with zero allocated bytes, allocation counters, GC time, pauses and full sweeps.
The declared interval includes the entire simulator process, optics, transport,
recording, diagnostics, controls and interim paused waiting; it excludes final
report serialization. These observations do not claim zero allocation in graph
callbacks, the coordinator or systemd, and do not cover preparation/warmup.

The archived fault matrix and these refreshed installed gates close the selected
functional ownership transfer. They preserve source/configuration identities,
explicit CUDA selection, native scientific authority and per-engine numerical
prefixes. The unqualified timing, hardware, other-profile and authority boundaries
stated in the final disposition remain unchanged.
