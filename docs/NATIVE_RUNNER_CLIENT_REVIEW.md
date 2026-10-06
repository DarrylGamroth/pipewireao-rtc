# Native runner Julia client review

2026-10-05. Independent review of the cold Julia request/reply codec, native
runner client, argv/presentation adapter and subsequent narrow production
supervisor wiring.
The authoritative wire profile is [NATIVE_RUNNER_CONTROL.md](NATIVE_RUNNER_CONTROL.md).
The endpoint review is [NATIVE_RUNNER_ENDPOINT_REVIEW.md](NATIVE_RUNNER_ENDPOINT_REVIEW.md).
This review makes no production edits.

## Scope and source identity

Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-native-controls`.
Branch: `work/native-control-planes-20261005`; endpoint increment started at
`03770074b590a73156c664ea0d4ea816b5853921`. Other agents own concurrent endpoint,
client and deployment changes. The reviewer owns this new artifact only for the
client review. SHA-256 of the inspected files:

| File | SHA-256 |
| --- | --- |
| `deployment/julia/src/native_runner_codec.jl` | `be239b081f970d85278e747c2abb41dd015d06eac3b7cb506eb05584c9a08473` |
| `deployment/julia/src/native_runner_client.jl` | `1e03b0516202c834029d9ab56a29dde8cd72b446d548ad19b3d0c151a11e0bf1` |
| `deployment/julia/src/runner_commands.jl` | `c2fd2a1ec460fd52942af7947db6f11242ec3f45835943d813675ec489aa43cd` |

The production wiring review below covers the supervisor-to-runner boundary.
Other legacy caller removal and complete installed application qualification
remain separate. No scientific,
GPU, hardware or allocation-free behavior is promoted by these cold controls.

## NRC-001 — Same-task reentry can clear the outer pending request

Severity: Medium. Confidence: High. Evidence: original request/close source and
Julia ReentrantLock semantics. Disposition: addressed in inspected source and
focused synthetic plus actual-client tests.

The original guard used `trylock(request_lock)` without a separate active flag.
A user-supplied `check()` callback can call request! or close from the same task;
a ReentrantLock admits that task again. A nested request could eventually reject
because the outer pending header existed, then run unconditional finally cleanup
that cleared the outer header and matching reply. Nested close could retire the
outer request's resources. Thus the intended one-pending contract was not
established by the lock alone. This was source-confirmed and independently
confirmed by the implementation worker before correction; no separate executable
fail-before run is claimed.

The corrected client sets `active` before the first external check callback.
Nested request and close calls reject before entering mutation/finally paths and
release only their nested lock count. A request tracks whether it installed its
own pending header; cleanup clears only that exact header. The outer operation
alone resets active and releases its lock ownership.

Required validation is satisfied by the focused client test: synthetic same-task
reentry retains the exact pending header and resources; a real native status
request invokes nested request/close checks repeatedly and still returns its
matching completion. Subsequent requests and normal close remain usable.

## NRC-002 — Repeated observations must preserve the first reply chronology

Severity: Medium. Confidence: High. Evidence: initial observation assignment and
selected absolute-deadline/retirement contract. Disposition: primary-agent finding,
independently verified correction and focused tests.

Replacing a matching record on an identical repeated publication also replaces
its observation timestamp. A completion first observed before the deadline could
then appear late solely because a duplicate arrived later. The corrected client
retains the first matching completion/rejection timestamp and byte identity.
Conflicting matching records remain fatal. The bounded-observation tests submit
equal duplicates on opposite sides of a deadline and retain the first resolved
outcome for both completion and rejection.

A related correction distinguishes ordinary connection/proxy retirement from a
malformed or conflicting native record. A matching reply observed before later
retirement remains resolved, supporting Quit. Earlier retirement prevents a
subsequent reply from reviving the request. Malformed/conflicting data sets a
separate fatal failure and invalidates resolution even if ordinary retirement
was already observed. Tests cover these orderings explicitly. This is local
observation chronology, not proof that remote execution is atomic with removal.

## NRC-003 — Controller instance seeds must be selected at runtime

Severity: Low. Confidence: High. Evidence: initial module-level time seed and
Julia precompilation lifetime. Disposition: primary-agent finding, independently
verified source correction; uniqueness across processes also relies on actual
registry lifetime identity.

A module-level time-based integer can be retained in a precompile image and
reused by later processes. The corrected counter starts at zero and is seeded
under a lock on the first actual connection, then advances monotonically with
explicit exhaustion rejection. The marker name includes the process ID; request
identity additionally contains the observed registry global ID and unsigned
object serial. The counter is not represented as cryptographic authentication or
as sufficient identity without those registry fields. Focused tests check
positive and advancing instances; they do not constitute an exhaustive
cross-process collision experiment.

## NRC-004 — Local argv rejection can terminate the deployment

Severity: Medium. Confidence: High. Evidence: production deployment diff against
`0377007`, RunnerCommands parser and existing broker exception handling.
Disposition: addressed in source and focused fail-before/pass-after tests.

The new `native_control` calls RunnerCommands.parse before submission. Expected
invalid commands throw ArgumentError. `serve_control` classifies an exception
from coordinate as a fatal control outcome, sends an error, and rethrows into
`_run_locked`, which tears down the deployment. Thus a structurally valid public
request such as `["bogus"]` now stops supervision. Previously the Rust parser
returned an ordinary failed reply, allowed by the old native_control's
`allow_rejection=true`; the deployment remained usable.

Validation also must precede source coordination. `["stop", ""]` is recognized
as a stopping operation, so the current coordinate code queries and pauses the
source before the local codec rejects its empty group name. Catching only the
later parse failure would leave that source paused after a rejected command.

Required correction: validate the public command before any source/runner effect
and render ordinary local validation failure as a rejection. Keep unknown
submitted outcomes and source coordination failures fatal. Required validation:
an invalid command and invalid scalar/name return failure without native/source
calls, followed by a successful status on the same broker; a running source must
remain unchanged. This is an observed source regression, not a request to expand
the selected Phase F broker migration.

## NRC-005 — Startup admission no longer rejects unsuccessful replies

Severity: Medium. Confidence: High. Evidence: `_run_locked` startup diff and
native error rendering. Disposition: addressed in source and 10 focused
admission assertions.

Old startup calls used control's default `allow_rejection=false`, so a failed
status/start could not pass admission. The replacement native_control returns
rendered failed completions and admission rejections. Startup currently checks
only Ready or Running in their state fields. A failed Status can retain Ready
(e.g. discarded-buffer observation failure), and a rejected Start can report an
already Running lifecycle. Neither is a successful matching admission result.

Required correction: require `ok == true` together with the expected state for
both startup Status and Start. The native successful-result decoder already
constrains the operation/outcome. Required validation: false/Ready and
false/Running replies fail startup; true replies with the matching states pass.

The revised coordinate validates before any source or runner call, catches only
expected ArgumentError, and passes the parsed typed command onward. Unknown
submitted outcomes retain fatal handling. The shared runner_admission helper
requires `ok === true` and the expected state at both startup sites. Inspected
corrected deployment SHA-256:
`9be47542acc9109c5d2c514670911bd2d27989b6d8b1e750280b7932d69432c6`.

NRC-004 fail-before evidence is
`native-runner-coordination-before-corrected-fixture.log`: malformed command
exceptions escape the broker, and invalid source-coordinated argv reaches source
status instead of rejecting locally. The first pass-after run has 26 successful
coordination assertions and three fixture return-value failures because
serve_control returns true on success, not nothing; all 10 admission assertions
pass. The corrected fixture passes all 29 coordination checks plus 10 admission
checks in `native-runner-coordination-after-final.log`. The expectation was
corrected to successful task completion without requiring a particular return
value; no production workaround was made for that fixture mismatch.

The deployment source at discovery of NRC-004/005 had SHA-256
`2824b3627d35ef2f12564cd8e586fa299fcb73e6aee50c33848fcf610ae8db31`;
`test_deploy.jl` had SHA-256
`8fdc1399a264d9ebdee256ed724e6a7a14f5dba41cfa125efcab89215ecdb5bd`.
The reviewer makes no production deployment edits.

## NRC-006 — Supervisor diagnostic fallback cleanup has unexercised errors

Severity: Low (diagnostic fixture). Confidence: High. Evidence: source inspection
of `deployment/julia/test/native_runner_deployment.jl`. Disposition: fixture
addressed in source and independently inspected primary-agent replay: 41/41
checks pass. The reviewer also inspected the resulting stopped-state evidence.
No production defect attributed.

The initial kill_fixture_tree! calls unqualified control although the binding is
DeploymentTest.control; its catch silently skips the intended ordinary Quit.
The fallback loop destructures `(pid, expected)` from records containing
`pid` and `identity`, then accesses `expected.identity`. The destructured value
already is the identity NamedTuple and has no identity field, so fallback aborts
whenever the captured list is nonempty. Finally also skips the cleanup helper if
the supervisor has already exited, even when captured owned groups could remain.
The normal successful deployment path does not exercise these branches.

Required correction: call the qualified control function, compare the exact
captured identity consistently, and check captured owned groups even after
supervisor exit. Preserve start-time/session/group matching before signaling.
A focused dead-child/record cleanup check is sufficient for the field-access
correction; production timeouts need no adjustment. Actual successful shutdown
evidence must remain separate from untested forced-cleanup behavior.

The corrected fixture qualifies the control function, iterates each captured
record as `item.pid`/`item.identity`, and always checks captured owned groups,
even after supervisor exit. It adds a stale start-time snapshot of the current
test process: cleanup must ignore that record without signaling. This safely
exercises the formerly broken field-access path. Inspected fixture SHA-256:
`2bbdf3aa765fd4349e68b8a67f8d7e624eb5d9eeb53eb684c6aa106f7f60a2f3`.

## Contract checks

- The codec maps the same 14 operation IDs and exact scalar POD kinds as Rust.
  It enforces arity, known enums, finite request Float/Double values, unsigned
  serial/counter bit representation, optional observations and causal result
  distinctions. Active property results require the necessary Running/nonempty/
  matching-generation conditions; the wire cannot establish baseline advancement.
- Borrowed request preflight bounds strings, property records, dimensions and
  exact 16 KiB envelope size before building variable-size PODs. Property count
  is 1–42; parameter descriptors remain F32_LE with positive dimensions and a
  512 MiB checked extent. Codec encoding does not open artifact files. Reply
  parsing first uses the bounded common envelope, then exact owner detail schemas.
- Discovery uses an explicit private absolute remote, actual owner and marker
  NodeInfo, exact protocol/profile/PID/instance/serial checks and zero ports.
  A maximum of 32 verified controller records is decoded. The client waits until
  its actual full identity occurs in the owner's capability; no automatic retry
  substitutes for that barrier. Same-user private-core identity is correlation,
  not an authentication guarantee against another same-user process.
- Initial completion/rejection records and capabilities are bootstrap data. Each
  query uses a new token above all observed accepted tokens and requires a
  matching endpoint/controller/token/operation reply. Exactly one set_param!
  submits each request; collision/Busy/timeout does not trigger replay or rebind.
- One absolute local deadline covers validation, submission and observation.
  A submitted request with no valid timely matching observation becomes unknown
  and disables the client. A reply observed before ordinary owner retirement
  remains resolved, and later requests fail. No remote rollback or hard bound on
  arbitrary native cleanup calls is inferred.
- RunnerCommands retains bounded CLI parsing and dictionary rendering only at
  the compatibility presentation boundary. Live requests and replies use native
  PODs. Rendering JSON-compatible dictionaries is not itself JSON transport.

## Verification and disposition

The reviewer inspected the source and these logs under
`/home/dgamroth/.cache/rtc-live-controls-20261005`:

| Replay | Result and exact binary |
| --- | --- |
| Initial `native-runner-client-tests-scope-fixed.log` | 38 observation + 58 actual endpoint checks; binary `92117f75ca8eeab78cc07d380b12c0fa9b69ddcf34e28ab73448dbcca192c48e` |
| Expanded current-client `native-runner-client-tests-final-source.log` | 46 observation + 58 actual endpoint checks; binary `6904b1cdd41842d28f9a047468913bfc137350882360326c7bcafb5d011dc372` |
| Initial sealed endpoint replay `native-runner-client-sealed.log` | 46 observation checks pass; integration stops after three checks because runner startup times out synchronizing the second link before binding. Binary `71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`; cause unresolved. |
| Same-settings serial replay `native-runner-client-sealed-serial.log` | 46 observation + 58 actual endpoint checks pass with the same sealed binary `71549afe3ca2f235c1264dafc0f18602936de861ad5e549cbc1b70c7c330fb4d`. Evidence: `native-runner-client-2016340796032916`. |

The failure is recorded in
`native-runner-client-2016206033480904/client-runner.log`. It is observed
startup failure, not evidence establishing a client correlation defect or a
particular scheduling cause. The primary agent reports other CPU-14 fixtures
and a full Julia run overlapped the failed attempt; the serial replay used no
changed production timeout/options and passed. This association does not prove
the timeout cause. The client source at the listed final hash includes
the inspected rejection of zero/UInt32-maximum owner global IDs.

The actual fixture uses two client connections, checks exact owner selection,
fresh queries, lifecycle Start/Stop, native errors, nested callbacks, explicit
expiry/client retirement, marker removal and normal Quit/owner exit. Four tiny
external ndarray nodes provide readiness without source submissions or sink
arming. This is software protocol qualification, not scientific validation.

No additional confirmed blocker was found for the codec/client modules after
the recorded corrections. The subsequent production caller review found
NRC-004 and NRC-005 above; their source corrections and 39 focused pass-after
assertions are verified. The sealed-binary client passes its same-settings
serial replay; the earlier startup failure remains recorded with unknown cause.
The actual supervisor fixture uses production Deployment.run, the sealed runner
binary and a private core, with an owned toy child supplying four tiny ndarray
endpoints. The worker reports 41 successful checks in
`native-runner-deployment-2016562221025804`; the reviewer inspected its
`summary.json` and `state.json`: native endpoint identity, successful Ready/Start
records, final stopped/not-admitted state and no error are retained. Its source
checks invalid command followed by fresh status, Stop/Reset/Start/Quit, normal
owned-process exit and runtime removal. The independent primary-agent replay passes 41/41 checks in 24.8 seconds in
`native-runner-deployment-sealed.log`, with evidence in
`native-runner-deployment-2016880146419963`. The reviewer verified that log and
its summary against the same sealed binary and unchanged production/fixture
source hashes. Forced live-descendant cleanup is not implied by the
stale-identity check or normal cleanup. The fixture runs the no-source-owner supervisor branch;
source pause/resume ordering is source-reviewed, with the existing typed-mock
revocation tests separate from this actual launcher case.

The final Julia regression in `native-runner-julia-sealed-regression.log`
passes 1,791 assertions across 69 test sets; the reviewer independently summed
the recorded pass/total rows.

The existing tests do not qualify hard
real-time cleanup, blocked artifact I/O, removal atomicity during an effect or
the remaining calibration/HEART/public-caller migrations.
