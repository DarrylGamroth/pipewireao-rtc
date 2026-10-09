# Independent terminal shutdown review — 2026-10-09

Status: completed independent source review and retained cold-test evidence review.
TSH-001 was confirmed and remediated; no unresolved source defect remains in this scope.

## Scope and source state

Read-only review of the in-progress ordinary shutdown changes. No production
source, services, daemon state, science, GPU workload or protocol IDs were changed
by this reviewer. Preferred Sol is `gpt-6.1-sol`; the parent requested an independent
Astra review. Existing global instructions and each applicable AGENTS.md were read.

| Worktree | Branch | Starting HEAD |
| --- | --- | --- |
| `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-package` | `codex/julia-package-root-20261008` | `ae540e31700ccb026c999d23241f2a1b1275ae0d` |
| `/home/dgamroth/workspaces/codex/pipewire/wireplumber-core-endpoints` | `codex/core-owned-endpoints-20261008` | `d532f8918d76ed843a7bf39d2b3beebc93292310` |
| `/home/dgamroth/workspaces/codex/pipewire/REVOLTRTC.jl` | `codex/revolt-package-split-20261008` | `2c91e04f73fe39c2d2ab8499fc08656e489418c5` |

All three worktrees had the task's uncommitted changes when inspected. Other agents
own those edits. Shared changes initially affected native endpoint/runtime and
bootstrap tests, including new `test/native_owner_terminal.jl`. WirePlumber changes
affected `session.lua`, `ao-owner.lua`, Meson test registration and a new owner Lua
test. REVOLT changes initially affected `heart_owner.jl`; a HEART cold test appeared
while the review was in progress.

## TSH-001 — A new request aborts terminal endpoint retention

Severity: P1. Confidence: high. Classification: derived directly from source state
transitions; initial disposition: confirmed design/implementation defect, remediation
requested from primary.

Affected code: shared `src/native_control_endpoint.jl`, `admission`, `stage!`,
`complete!`, `terminal_release`; bootstrap and HEART terminal callers.

Evidence and analysis:

1. Successful Quit/shutdown calls `complete!`, which clears `pending` and preserves
   the successful terminal reply. The owner then waits in `wait_terminal_release!`.
2. `admission` checks identity, tokens and the pending slot, but has no terminal
   retention gate. A new higher-token request from the retained controller is
   accepted; `stage!` fills `pending` and updates the accepted token.
3. `terminal_release` requires `pending === nothing`. Its next pass throws
   `native terminal request has not completed`, and the owner's failure path ends
   retention before controller removal or the original deadline.
4. Therefore even a status request can destroy the interval in which a delayed
   reader must be able to enumerate the successful terminal completion. New
   mutation requests are accepted into a slot that the now-stopping owner cannot
   service.

Proposed remediation: establish an explicit terminal-retention admission state
atomically with successful terminal publication. Reject new work in this state;
preserve exact duplicate replay if supported. Do not infer terminal shutdown merely
from `terminal_request`, which holds every completed request, or from general
controller retention, which also applies throughout connected science.

Required validation: after successful terminal publication, send a higher-token
status/mutation and an exact terminal replay. Verify new requests are rejected,
`pending` remains empty, the original completion and original deadline remain,
the endpoint stays readable, and exact-controller removal still ends the wait.
Use the same check before and after the fix where practical.

## Reviewed invariants

- **Observed source:** positive bootstrap completion requires `facts.finished` and
  no main cleanup error. HEART completes only after `stop` and a child-not-alive
  check. Scientific cleanup precedes the new retention interval.
- **Observed source:** `retain_controller!` and successful `complete!` both check
  the applying ticket and live exact controller under the thread-loop lock.
  Pre-publication authority loss cannot enter the positive terminal wait.
- **Observed source:** proof revocation before removal sets `retired`; the removal
  callback preserves the prior classification by setting `removed` only when it
  was not already retired. Core/endpoint failures are checked before release.
- **Observed source:** the terminal wait uses `ticket.deadline`, without a fresh
  grace budget. The 5 ms sleep is a bounded polling interval, not proof of delivery.
  Deadline expiry permits resource release and does not prove peer consumption.
- **Observed source:** Lua preserves source hold, graph hold, link withdrawal,
  source bootstrap Quit, remaining declared controls, session Offline publication,
  and controller disconnect. Every owner operation receives the same operation
  deadline. Existing sequence/guarded callbacks retain operation epoch and session
  authority checks.
- **Observed source:** `connections.withdraw` clears captured registry objects
  before invoking the shutdown continuation. Expected removal of scientific source
  nodes therefore does not trigger the normal captured-object loss fault. Each
  remaining `owner.request` still checks its retained endpoint incarnation.
- **Observed source:** missing source bootstrap is supported: `shutdown_order`
  preserves the remaining declared controls, including an empty list. It does not
  manufacture a source owner. Exact declaration clients are retained from startup.
- **Observed diff:** normal shutdown alone gained terminal owner operations. The
  emergency `fault` function was not changed. No native v1 numeric IDs changed.

## Evidence and limits

Reviewed existing `/home/dgamroth/.cache/rtc-julia-package-20261008/terminal-before-20261009.log`
and `terminal-after-20261009.log`: the baseline closed before delayed enumeration
and failed; the initial retained version reports 27/27 passing assertions across
bootstrap release/expiry/proof scenarios. These are another agent's retained test
outputs, not an independently executed test by this reviewer. The test deliberately
disables subscription, waits 100 ms and explicitly enumerates Props, which directly
exercises the original publication-versus-read race.

The initial Lua test uses real PODs with a request double. It checks terminal
payload validation, operation IDs, ordering helper and no-source compatibility;
it does not itself exercise the complete session effect chain or native polling.
The initial bootstrap test models scientific cleanup with `science_closed = true`;
it tests transport retention, not actual scientific resources or retained buffers.

Separate installed validation: actual session orchestration coverage. Live FGN/JFG/unchanged HEART,
retained-buffer teardown, hardware timing and empty cgroup/job qualification are
outside this review and must not be inferred from cold software checks.

## Remediation review update

TSH-001 source remediation independently reviewed after implementation:
`Endpoint.terminal` is distinct from prior completed-ticket and connected-controller
state. `complete!(...; terminal=true)` requires a zero-result completion and closes
admission in the same native-lock transaction as publication. Publication failure
still sets the endpoint's operational failure, preventing work on a partly committed
state. Bootstrap only opts in for successful Quit; HEART opts in only when stopping.
`admission` preserves exact replay before rejecting fresh tokens with -108. The
wait additionally verifies admission is closed. No new deadline or lifecycle/ID
reinterpretation is introduced. Source disposition: resolved; regression results
were running when this paragraph was written.

The HEART cold test now runs its real `consume_native!` loop before client connection.
The earlier admission timeout came from starting the test's owner loop after the
blocking connect; this was a test setup defect, not a production failure. The test
uses no HEART child and so verifies the wrapper's cold control path only.

Reviewed the WirePlumber implementation evidence and Meson log: 57/57 tests pass.
The scope remains actual POD validation and helper behavior plus source review of
session sequencing. Full installed sequencing is the primary agent's separate gate.


## Final disposition and evidence

TSH-001: resolved. Re-read final gate/callsites and reviewed the updated real
private-core regression code and logs. Bootstrap `terminal-after-20261009.log`
reports 35/35 assertions; HEART `heart-terminal-after-20261009.log` reports 30/30.
They now check new status and terminal requests are rejected during retention,
keep the original terminal ticket and empty pending slot, retain the endpoint for
a delayed reader, and finish on exact removal or original deadline. Proof mutation
continues to fail. The bootstrap baseline log supplies fail-before evidence for
the original early-close race. The TSH-001 narrower admission race was established
from source and has pass-after rejection coverage; no separate pre-fix execution
of that additional assertion is claimed.

Reviewer ran `git diff --check` in all three worktrees: pass. Reviewer performed no
production edits or service operations and did not independently rerun the cold
suites. Logs are attributable to the implementation agent. No further confirmed
source defect was found. Installed live session/child/scientific cleanup and
retained-buffer behavior remain with the primary agent's separate qualification.

Final reviewed SHA-256 hashes (paths relative to the corresponding worktree):

| Worktree/file | SHA-256 |
| --- | --- |
| Shared `src/native_control_endpoint.jl` | `8787006a2dec134e5de7dd6e4cea0b1b73bbea461d89fbd17ed3cf073638ec58` |
| Shared `src/native_owner_bootstrap_runtime.jl` | `a87d188a95db44b6788a3bf9dcfba64c5061fac63a8e203fa8ecb2f8da057d3c` |
| Shared `test/native_owner_terminal.jl` | `f91e22b47f98d567b1534618cbb7ce4a8d3cb9125f6c6555c06cd3854c722a48` |
| REVOLT `src/heart_owner.jl` | `8cb0c5ec3ab43cdddcb857b8466af9f9bdb5c319dfed13cb1572dd6cdac7414b` |
| REVOLT `test/native_heart_terminal.jl` | `373242bb3476bfbeb3f2fedeb6c9dabf2efd599bf9c3a8a347d2a03d52235007` |
| WP `src/scripts/ao/session.lua` | `de0ba4765cdec06916dd035f41be348bb6ed167386fa0517e4276e197148e407` |
| WP `src/scripts/lib/ao-owner.lua` | `14b1edf9bb55c19a6be160478fe9c6e6dbb1923a9dcce58693801b8433752e67` |
