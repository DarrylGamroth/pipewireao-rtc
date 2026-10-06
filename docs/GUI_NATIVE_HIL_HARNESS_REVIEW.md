# Native GUI HIL harness: independent pre-SCI review

Date: 2026-10-06. Scope: GUI harness commit
`e3e22ab9a58aaf884f9e2c8f4bd7d02c96677ba2` in
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-gui-native-hil`, initially
clean; RTC diagnostic `e81c35742a1265d090c0224c5d27281cd7238121` and unused
socket-option retirement `b0c71487e738bcd806cd5cd7ddcd7b405a64e76e` in
`pipewireao-rtc-native-controls`, initially clean at the latter commit.

Review artifact: `rtc-bootstrap-allocation-review`, initially clean at
`13c4e32`; only this document is changed. No production edit, build, SCI,
systemd invocation or test execution was performed in this source pass.
Required qualification boundaries come from
[the final plan](NATIVE_FINAL_QUALIFICATION_PLAN.md), RTC-DEV-006/030 and the
ten-issue acceptance map therein. This is review evidence, not new architecture.

## Findings

Line references below identify the reviewed e3e22ab source, not later edits.

### GUI-HIL-R001 — Failed foreground admission can leave the owned launcher alive

**Severity:** high. **Confidence:** high. **Evidence:** observed source control
flow; runtime failure injection pending. **Affected:**
`scripts/check_native_hil_gui.jl:329–350`, RTC `Deployment.shutdown`.

The harness's only foreground cleanup is `D.shutdown(runtime, process)`.
That function deliberately rejects a still-running, unadmitted supervisor and
can also throw on native Status/Stop/Quit failure or unknown outcome. The
harness catches the cleanup error, marks failure, and writes its result, but
does not interrupt or wait for the still-owned launcher. This is a resource
leak on an explicitly required failure-before-admission/unknown-control path.
An unsuccessful qualification must still retire its owned process.

**Proposed remediation:** retain native shutdown first; on failure, preserve the
failed result and use a finite SIGINT grace against only the retained owned
`Base.Process`, then bounded last-resort termination if it remains alive. Never
signal an unverified numeric PID or report this fallback as a successful normal
shutdown. Audit remaining owned processes separately from direct-child exit.
**Required validation:** actual disposable child plus forced native cleanup
failure, bounded exit, retained failure/exit nonzero, ordinary native cleanup
still succeeds. No SCI needed for this discriminator.
**Disposition:** primary independently confirmed; corrected and source-verified
at `9afc44a`. See the verification limits below.

### GUI-HIL-R002 — Service shutdown does not check the supported signal or exit

**Severity:** high. **Confidence:** high. **Evidence:** observed source.
**Affected:** harness line 283 and lines 334–342.

The generated RTC unit specifies `KillSignal=SIGINT`; the harness transient
unit omits that property and therefore does not reproduce that shutdown
contract. The harness accepts either inactive or failed service state and then
only checks the saved stopped report/PID and removed private directory. It
never checks `Result`, `ExecMainCode` or `ExecMainStatus`. A saved stopped report
and absent directory do not prove a successful service process exit. `--collect`
also permits collection before final service properties can be inspected.

**Proposed remediation:** retain the generated unit's SIGINT behavior; preserve
the fresh unit long enough to inspect exact final exit properties. Require
successful normal exit independently of the final owned saved report and
runtime cleanup. Save journal and service exit evidence; do not use a saved
report as live readiness authority.
**Required validation:** failed/signal exit rejected even with a plausible
stopped report; zero normal exit accepted; current foreground handling unchanged;
actual service SCI qualification remains separate.
**Disposition:** primary independently confirmed; corrected and source-verified
at `9afc44a` with strict exit-property tests.

### GUI-HIL-R003 — Rejected unit-name collision still enters cleanup

**Severity:** high. **Confidence:** high. **Evidence:** observed branch ordering.
**Affected:** harness lines 281–283 and 334–337.

The generated name is assigned to `unit` before the `LoadState == not-found`
check. If that check rejects an existing service, `finally` sees a non-null
unit and stops it. UUID collisions are unlikely, but the rejection branch
explicitly promises to preserve an existing unit and currently does the
opposite. Fresh naming does not confer process ownership.

**Proposed remediation:** distinguish a proposed name from a creation attempt
that passed absence checks; service cleanup must be conditional on the latter
owned action. Preserve failures during launch without falling through to an
unowned name. **Required validation:** injected existing unit, zero launch and
zero stop calls; successful fresh creation and failed attempted creation follow
their correctly bounded owned cleanup paths.
**Disposition:** corrected branch ordering source-verified at `9afc44a`;
overwrite rejection tested, full injected collision branch not executed.

### GUI-HIL-R004 — Service subprocess calls escape the advertised finite bounds

**Severity:** medium. **Confidence:** high. **Evidence:** observed source;
stalled user-bus experiment not performed. **Affected:** `unit_property`,
`wait_unit`, direct `systemd-run` and `systemctl stop` calls.

The outer polling deadline is checked only after synchronous `read`/`run`
returns. These subprocess calls have no harness timeout. Thus a stalled service
manager/client can prevent the advertised startup or cleanup timeout from
being reached. Native requests themselves have finite public deadlines.

**Proposed remediation:** use the existing bounded child-command helper with
remaining deadline, preserving owned subprocess cleanup and output bounds.
**Required validation:** a stalled command is retired within its assigned
budget; an existing unit is never signalled by that command cleanup. Otherwise
state that the service bound remains unqualified and do not claim it closed.
**Disposition:** bounded command helper/remaining-budget calls source-verified
at `9afc44a`; actual timed-out sleep-command test passes.

## Accepted source properties and evidence limits

- Foreground ownership starts from the actual spawned process. Readiness uses
  `Deployment.wait_state` and the same retained native client throughout the
  cohort. Service admission checks MainPID against that client's owner PID;
  discovery compares UUID, PID, incarnation, node and private observation remote
  and obtains a separate fresh selection proof. The public client owns global
  ID/full serial/token matching and fails closed on removal/replacement.
  `N.live_uuid` invokes the healthy-binding check; it is not a stale-file lookup.
  A late service-manager state transition could cause conservative admission
  failure; no false success was established from that possibility.
- The extra selection proof is a read-only explicit client. It does not replace
  the original admission client or silently retry an accepted mutation. Its
  creation is cold allocating control work, as documented, and cannot inherit
  the fixed-client process-zero allocation claim.
- `success=true` is assigned only after the `wait_state` callback returns and
  its client closes. Exceptions in that scope remain failures. Observer timeout
  or witness failure resumes an owned stopped test process before terminating
  it. No arbitrary observer PID or process group is signalled.
- Every science read follows native completed/report-ready generation and
  sequence checks. Required frame/command/metric counts and consecutive retained
  sequences are checked. Each raw file's owner hash is verified; the gzip decoded
  hash is rechecked before raw-runtime cleanup. `compare` rejects partial-prefix
  cohorts and changed protected scientific hashes/source arguments before exact
  full detector and command hash comparison. A genuine difference remains a
  failure; there is no tolerance relaxation.
- The documented full-256 functional cohorts are distinct from the 512-exchange,
  16-prefix inclusive allocation fixture. The harness does not assert allocation
  success or achieved cadence. Baseline reset checks prefix bytes and continuous
  truth, not full-512 recording. These boundaries must remain explicit in results.
- Native offscreen rendering exercises production adapter/panel code with live
  pixels and no mutation intents. It is not a desktop/window-system test. The
  render scenario's external SIGSTOP witness establishes required progress while
  that reader is stopped; final full-trajectory comparison is still needed for
  equivalence. Generic GUI sample revisions are not Acquisition sequence IDs;
  an independent metadata-aware reader remains required for those checks.
- The harness alone does not cover the entire final plan: it admits simulator
  HIL, not HEART calibration/correction; it does not exercise service/operator
  records in a shared registry, duplicate labels, optional-link removal/reset
  and every RTC-DEV-006 cohort automatically. Its private fresh XDG registry
  isolates the tests but cannot by itself prove preservation of pre-existing
  operator registry objects. Prior evidence and missing integrated cases must
  remain separately attributed.

## RTC changes reviewed

**e81c357 — accepted source change.** Failed runner Status now includes the
matched result/lifecycle/incarnation/token/operation and native error fields in
the existing failure. The success branch, request budget and science scheduling
are unchanged. Documentation retains the failed Copper FGN cohort and does not
claim its root cause was repaired. Recorded fixture result is four missing-detail
assertions before, all five afterward, 20 focused assertions overall; this source
pass did not rerun them.

**b0c7148 — accepted source change.** Both maintained calibration exporters stop
emitting the unused `--calibration-socket`; the common calibration owner parser
stops requiring/returning it. The ordinary native option parser rejects the old
option. Searches of maintained owner/export source found no remaining reader
of the removed field. Applicable capture/WFS native path conflict checks remain;
only conflicts involving the removed unused path disappear. Native action,
acquisition, scientific storage and restoration bodies are unchanged. Existing
sealed old calibration argv must be re-exported, not silently given fallback.
The retained positive-options fail-before/30-check pass-after and HEART/export
regressions are software evidence; actual installed acquisition remains open.

## Remediation verification and pre-SCI disposition

Primary remediation commit `9afc44a4dc0266736282719d2fef36b90687b6a0` was
independently inspected after the initial blockers were reported. GUI worktree
was clean at that commit. No Rust source or binary changed in this remediation.

- Foreground native cleanup failure now invokes bounded SIGINT/last-resort kill
  only on the retained owned process and rethrows the original failure. The
  result stays failed even if fallback retires the process. The fallback report
  explicitly leaves descendant cleanup proof separate.
- Service mode creates a fresh runtime user-unit file after checking both
  loaded-unit and path absence. Only successful file creation assigns cleanup
  ownership. SIGINT matches the generated RTC template. This version assumes
  exit properties remain available and requires `Result=success`, `ExecMainCode=1` (CLD_EXITED),
  `ExecMainStatus=0` before final-report acceptance. Only the owned inactive or
  failed unit file is removed, followed by bounded daemon reload.
- Service manager commands use `C.run_checked`; polling passes its remaining
  budget. The initial review inferred that inherited
  `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` would preserve manager
  access inside the private-XDG scope. **The actual failed service trial refutes
  this inference.** The correction and exit-property limitation are below.

The primary's retained `~/.cache/gui-native-hil-qualification-20261006/cleanup-after.log`
was read independently: 34 assertions pass, including actual owned `sleep 60`
retirement, bounded timeout of a separate sleep command, strict exit triples,
unit SIGINT/notify/affinity fields and overwrite rejection. It does not execute
an actual service, science owner, or the complete `check()` failure branch.
The earlier `cleanup-before.log` errors because the new fallback helper is
undefined. This proves the helper was absent, **not** an end-to-end fail-before
demonstration of an orphaned SCI owner or false-green service exit. Those old
branches are confirmed by source flow. The full collision branch is likewise
source-verified rather than exercised by the lower-level overwrite test.

Exact final hashes:

| Artifact | SHA-256 |
| --- | --- |
| `scripts/check_native_hil_gui.jl` | `43cd1c3a7f72eb0bf073b6df7c1df5986ce49fe455cc62a6abb1e02d30abaf67` |
| `scripts/test_native_hil_gui.jl` | `d04231180c451cef111307c1d5091c5d46330f5ada10afa8f2ed88bf3d936c7b` |
| `cleanup-before.log` | `ffb05989d04ffb2d06ba645d2659014a7210e93469946a4ac29717e67f7ff044` |
| `cleanup-after.log` | `f5d8cab1fa1208fbb984098508799a0f17e043e3865d23f5cdd61c70d8228971` |

No further pre-SCI source blocker was found in the bounded review. The primary
may proceed with the coordinated fresh service cohort. That execution, actual
descendant cleanup, native systemd startup/exit, complete GUI stress/trajectory
matrix and overall issue acceptance remain experimental gates. No test was
independently rerun by this reviewer and no SCI success is claimed here.

## Actual service failure and independent follow-up review

The first real service trial at `9afc44a` failed. Its retained
`~/.cache/rtc-native-final-deployment-20261006/gui-hil-service-classic-fgn-v1/result.json`
records both operation and cleanup errors: `Failed to connect to user scope bus
via local transport: No such file or directory`. It retains `success=false`
and the active owned unit rather than removing its file. This is actual
integration evidence, stronger than the earlier environment inference.

### GUI-HIL-R005 — Private registry context prevents user-manager access

**Severity:** high. **Confidence:** high. **Classification:** observed actual
failure plus source. **Affected:** all cold service-manager commands inside
the private `XDG_RUNTIME_DIR` scope.

The inherited D-Bus address did not make these commands reach the manager.
Primary remediation `0e21a58ad082171481d741b174e800ed8f49066e` captures the original
user-manager XDG directory at module load and applies that override through
the bounded command helper. All service-manager calls use the helper, and the
runtime unit file uses the same original directory. The launched deployment
retains its separate private registry environment.

**Validation:** focused fixture enters a different private-XDG scope and checks
that the helper's subprocess receives the captured original value. Source
routing was independently inspected. **Disposition:** source and focused
software remediation accepted; actual fresh service success remains pending.

### GUI-HIL-R006 — Persistent unit file does not retain main-process exit fields

**Severity:** high for service qualification. **Confidence:** high.
**Classification:** observed integration behavior; conservative rejection,
not an observed false green. **Affected:** service exit evidence after stop.

After primary manually stopped exactly the owned failed-v1 service with SIGINT,
the manager reported inactive, PID zero, `Result=success`, `ExecMainCode=0`,
`ExecMainStatus=0`. A persistent unit file did not prevent collection of the
main-process exit statistics. Code zero cannot be accepted as an observed
normal exit. The retained `manual-cleanup.json` separately records four absent
owned PIDs, no remaining group/session members, absent private instance and
removal of the owned unit and XDG directory. It explicitly preserves failed
qualification; this supplemental cleanup does not rewrite the original result.

At `0e21a58`, the unit has an `ExecStopPost` direct absolute `printf` command.
It writes a tagged receipt using manager-provided invocation/exit/result
variables to the fresh owned deployment log. Admission first captures the live
32-hex-digit InvocationID alongside MainPID. After bounded stop/inactive
confirmation, acceptance requires exactly one complete newline-terminated
receipt for that invocation with `exited 0 success`. Missing, duplicate, partial,
other-invocation, signal and nonzero-exit receipts fail. Saved state remains a
cleanup cross-check, not live readiness authority.

Independently reviewing the draft exposed a weaker branch that ignored Result
and status whenever code was zero. The primary corrected it before commit.
Final source requires either exact retained success `(success,1,0)` or exact
unretained neutral `(success,0,0)`, **in addition to** the valid receipt. A
code-zero timeout or nonzero status is rejected. The neutral triple supplies no
affirmative exit evidence of its own.

**Validation:** independently inspected final source and negative fixtures.
The retained manager-context suite has 46 passing assertions. Generated-unit
`systemd-analyze` exit-status validation is retained separately; its unchecked
stderr made the original parse-success interpretation too strong, as the v2
trial below demonstrates. Neither constitutes
an actual invocation receipt from a successful SCI service.
**Disposition:** remediation accepted for a fresh coordinated integration
attempt; actual manager receipt and complete owner cleanup remain to validate.

Exact follow-up evidence hashes:

| Artifact at `0e21a58` | SHA-256 |
| --- | --- |
| Harness | `6d0ac855e9b0608a02174bfe1481d57a7c39520a6f4417b83f3a6545c790e7f1` |
| Tests | `368c91cc3828010ae3adf31a80a48d9896f1692f4dc2155195eb0bb05ac15134` |
| `manager-context-after.log` | `a38f1425268c1b03a53b7bf6777bda568715c7341fe8c070337409006f902f8b` |
| `unit-parse-check.log` | `a4bd95e0773042fd8e95881029bbd2d59b47c7ebfc76cf84b4f27668d7ac42a9` |

Both logs are under `~/.cache/gui-native-hil-qualification-20261006/`; hashes
and test totals were independently checked. Review worktree started clean at
`61995f7`. Only this review document changed. The source worktree contained the
primary's additional uncommitted FFTW-wisdom provenance inclusion during the
final inspection; the table identifies committed `0e21a58` exactly. No new
build, test execution, service-manager action or SCI was run by this reviewer.

## Structured output correction after actual v2

### GUI-HIL-R007 — Warning-only unit parse error discards receipt destination

**Severity:** high for service qualification. **Confidence:** high.
**Classification:** observed actual journal plus source. **Affected:**
`create_unit` StandardOutput serialization and prelaunch verification.

The second actual service journal reports `Failed to parse output specifier,
ignoring` for the quoted `"append:/.../deployment.log"`. The unit verifier's
zero exit code did not mean it accepted every property; earlier verification
did not inspect stderr. The v2 result remains failed: a native owner Status
request returned the generic native runner Status failure, and cleanup could
not open the missing deployment log. The underlying runner error is unresolved;
the output formatting defect does not establish or repair its cause.

The same journal independently demonstrates that the manager actually supplied
the exit variables: it records invocation
`bf506e48830d4d0dad0ca1a4d779a7c1`, matching the admitted result, followed by
`exited 1 exit-code`. Systemd also records the main process's status 1. This is
actual failed-exit receipt evidence, not proof of a successful service cohort
or receipt delivery to the intended file.

Primary remediation `7995709f763a33832a70ea90189d03968637f274` was independently
inspected in the clean GUI worktree. The structured directive is now emitted
as unquoted `StandardOutput=append:PATH`; `%` is escaped for systemd specifiers,
and CR, newline and NUL are rejected. Before reload/start, a bounded verifier
subprocess runs with the captured manager environment. Its return code, stdout
and stderr are retained in the result, and admission requires exit zero **and
empty stderr**. Warning-only parser rejection therefore prevents SCI launch.
The invocation-bound receipt and strict property-consistency checks remain
unchanged.

**Validation:** source inspection; independently read retained 50-assertion
focused log, including generated-unit verification exit and empty stderr.
Log `~/.cache/gui-native-hil-qualification-20261006/standard-output-after.log`
has independently checked SHA-256
`0cc3d7086d5fa460fbd448ce253a0e03f1b40359c35582ca6de04eeb619fbccf`.
Committed harness SHA-256 is
`a63861971b80ae6f108118eccb528b6cf13c2b2a1bbf7abcf575e67457fd6c87`.
Actual v2 evidence is under the same final-deployment cache as v1, in
`gui-hil-service-classic-fgn-v2/{result.json,journal.log}`.

**Disposition:** source correction accepted for a fresh v3 attempt. Actual
successful receipt delivery, native runner completion and normal owned cleanup
remain integration gates. A diagnostic SDK clone may improve error attribution;
it must retain its own package/source provenance and cannot retrospectively
qualify v2. No build, test rerun, service invocation or SCI execution was
performed by this reviewer for this addendum.
