# WirePlumber realization qualification — 2026-10-07

## Scope and baseline

RTC baseline `8886d6ac35c41f71b532f610a15c36f4f63c40be`, isolated
worktree `/tmp/rtc-wireplumber-realization-20261007`, branch
`work/wireplumber-realization-20261007`. Initial probes used unmodified
WirePlumber 0.5.18 built against PipeWireAO; selected deployment now uses the
narrow POD-filter capacity correction described below. The WirePlumber patch
is isolated on `fix/spa-pod-filter-capacity-20261007` at
`/tmp/WirePlumberAO-pod-filter-20261007`, baseline
`bdc17eb2c419cbe41dbb248cf20cbe93370ee2f7`, with the narrow patch saved as
local commit `4c2648fa`. Qualified binaries were built before that commit from
the same source patch; their hashes remain in the receipts. No upstream push
or desktop installation was performed. Private non-actuating cores exclude
CPU0/1. Neither HEART
nor the desktop session was changed. Scientific readiness and source authority
stay in RTC. See [the design](../../WIREPLUMBER_REALIZATION_DESIGN.md) and
[independent review](REVIEW.md).

## Observed primitive results

| Check | Result | Scope |
| --- | --- | --- |
| Inactive no-port Filter Props updates and remote destruction | 10 assertions pass | Same publisher, two incarnations, reused global ID/new serial. No Links. |
| Canonical Rust intent encoding | 6 tests pass | Exact native tags, monotonic phase payload, capacities, duplicate rejection, full-width serials. |
| Cold policy callback ordering | Pass | Withdrawal, delayed callback, state repetition, discovery order, mutation, owner/removal/failure/deadline branches. Mock Pods do not qualify native decoding. |
| Public native Links and acknowledged withdrawal | [33 assertions pass](native-current/receipt.json) | Exact manager/client/endpoints/passive/path/negotiated ndarray Format; two generations; first-observed Withdraw; malformed phase tag; external Link removal. |
| Delayed native activation completion | [12 assertions pass](native-pending/receipt.json) | Actual public Link with a test-only 500 ms delay before dispatching its completion to policy. Withdraw remains unacknowledged until dispatch, then explicit deactivation/Core sync/marker removal/zero Links; no READY. |

The delayed-callback experiment does not establish hardware or server worst-case
activation cancellation. No deadline, tail-latency, physical-loop or broad
multiple-endpoint qualification follows from these checks.

## Preserved failures and correction

[Attempt 5](native-attempt-5/receipt.json) and
[attempt 6](native-attempt-6/receipt.json) preserve external Link removal that
left the marker alive and acknowledgement absent beyond the ten-second probe
bound. Upstream creator proxy `removed` only traces; `pw-proxy-destroyed` alone
was insufficient. The policy now monitors Link registry removal as well as
creator proxy destruction. The same native external-removal case now passes.

Those attempts also rejected requested passive=true. This was a probe-core
configuration error: standard link-factory strips that property unless
`allow.link.passive=true`. Existing deployment templates already enable it;
the isolated helper now has an opt-in keyword with its previous default
preserved. Both passive values pass with that setting. No Lua Boolean
conversion patch or upstream source change was needed.

## First deployed startup failure

The [first deployed FGN attempt](deployed-startup-failure/receipt.json) did not
reach admission. AOS reported connected and held at sequence zero; the runner
then exceeded its link-realization synchronization deadline. There were no
policy recognition messages in the captured log. That does not distinguish
policy recognition from buffered output. The later native capacity experiments below establish the startup rejection
mechanism. The separately corrected fixed-Choice Format decoder gap was not
the cause of this startup failure.

The qualification coordinator also exceeded its fallback interrupt wait and
killed its launcher. The final tracked-group map was empty, so that receipt
cannot prove complete cohort cleanup. A subsequent process inspection found no
processes bearing this experiment's package/runtime paths. This is not a
successful deployed or cleanup gate.

The [cold diagnostic deployment](deployed-type-rejection/receipt.json) confirms
that Lua loaded and received the marker, then rejected `pod:filter(expected)`.
No Link creation followed. The nominal type-validation message conflates native
type compatibility and filter capacity. The public WirePlumber implementation
uses a 1024-byte output builder, while the selected three-link projection is
1160 bytes. One- and two-row Rust projections pass native discovery. The same 1160-byte
three-row input fails before and passes after the public dynamic-builder fix.
Actual three-Link creation/Formats/passive/withdrawal checks pass 25/25 after
that correction; see WPR-13 in the review.
The diagnostic package contains test-only cold prints; production Lua is
unchanged. Its supervisor exited during the normal cleanup grace without an
interrupt, but this pre-admission coordinator still lacks complete tracked-group
identities, so its cleanup receipt remains unknown.

## Observed deployed clean results

Copper CPU [FGN](fgn-clean/receipt.json) and [JFG](jfg-clean/receipt.json)
with CUDA AOS each pass two 512-command runs using
WirePlumber-owned required Links. The actual cohort, native held reset,
stop/reset/resume and per-engine accepted 256-frame pixel and command prefixes
are preserved. Simulator measured tails report zero heap allocation and GC.
Owned process groups and private runtime cleanup complete. This is functional,
allocation and numerical-preservation evidence, not a new cadence or latency
qualification.

## Same-process adapter retry

The [FGN](fgn-held-retry/receipt.json) and
[JFG](jfg-held-retry/receipt.json) held retry checks each pass two Load/Unload
cycles in one Rust adapter/runner process. Runtime Client identity stays fixed;
marker identity and generation change. Each unload confirms marker removal and
zero correlated Links before the next admission. The sealed simulator remains
paused at sequence zero. This development-only libtest wrapper exposes no native
runner endpoint, so the outer deployment deliberately fails with
`required rtc exited with status 0`, then completely cleans its captured groups.
It does not claim native caller reload or acquisition within this adapter test.

## Deployed required-loss results

All eight selected fault/cleanup cases pass. Each injects loss during witnessed
live acquisition, latches failed/not-admitted state and observes complete cleanup
of the captured process groups and private runtime. The independent review
checks the injection identity and corresponding trace, beyond a generic nonzero
exit. These are whole-cohort failure checks, not successful runner Unload.

| Required loss | FGN | JFG |
| --- | --- | --- |
| Link | [Pass](fgn-loss-required-link/receipt.json) | [Pass](jfg-loss-required-link/receipt.json) |
| Selected WirePlumber process | [Pass](fgn-loss-manager/receipt.json) | [Pass](jfg-loss-manager/receipt.json) |
| RTC process | [Pass](fgn-loss-runtime/receipt.json) | [Pass](jfg-loss-runtime/receipt.json) |
| PipeWire Core | [Pass](fgn-loss-core/receipt.json) | [Pass](jfg-loss-core/receipt.json) |

## Fresh admission and accepted scope

[FGN](fgn-readmission/receipt.json) and [JFG](jfg-readmission/receipt.json)
each pass a new deployment after the complete loss series, with two further
512-command runs, exact per-engine retained prefixes, zero simulator-tail heap
allocation/GC and complete captured-cohort cleanup. This is fresh admission on
new private cores, not same-process recovery after an unknown withdrawal.

The selected opt-in Copper complete-frame CPU FGN/JFG + CUDA AOS link-ownership
increment is accepted for these functional, numerical-preservation and
simulator-allocation checks. Default direct RTC ownership remains available.
Native caller reload, general multi-endpoint/mixed-rate AOS, other profiles,
latest/hold, deadline/latency and physical-device qualification retain their
separate gates. The next increment is systemd user-service supervision.
Redundant supervision/link code is retained until its respective replacement
passes parity; these results do not qualify process-supervision transfer.
Receipts and exact policy snapshots are evidence, not live authority or an
operational configuration format. `primitive-provenance.json` records source
hashes for the initial primitive set; each native directory retains its own
policy/test snapshot and log.

## WirePlumber dependency correction

The [exact patch](wp-capacity/patch.diff) replaces only the fixed POD-filter
output builder with the existing public SPA dynamic builder, preserving owned
copy and cleanup semantics. Five added cases plus the nine existing POD cases
pass. The [full-suite comparison](wp-capacity/full-suite-summary.md) records
45 passes and the same 12 failures on both baseline and patched AO-enabled
builds; it does not claim full upstream compatibility. The inherited SPA
allocation-failure limitation remains WPR-14, without a graceful-OOM claim.

The [final native marker-loss gate](rust-marker-loss/receipt.json) passes
13 fixture checks and one Rust test: unexplained marker removal cannot supply
a withdrawal acknowledgement; unknown withdrawal retains the session and
fences another realization until the exact manager Client is revoked and its
correlated Links are gone. This uses a test-only delayed callback.

## Source-loss acknowledgement boundary

Injected required-link and owner loss gates check a latched failed deployment,
no admitted replacement and complete removal of the captured process cohort.
They do not require successful runner Unload or a fresh source Pause ACK after
the required transport is destroyed. Unknown withdrawal/source coordination
diagnostics remain preserved as faults. A final cached source status is not
proof of source revocation; process cleanup and any separately written failed
source report have their own observations.

Injected owner termination uses an exact-identity pidfd SIGKILL helper.
Existing Julia launcher diagnostics may print `exited with status 0` because
they format `Process.exitcode` without its signal field; that does not mean
graceful or successful shutdown. The explicit injection and failed deployment
remain the evidence. JFG loss logs also retain buffer-removal/broken-pipe errors
during fault propagation. No normal acquisition or successful scientific
teardown claim follows from those loss runs.

## Software checks

Final [Rust tests](checks/rtc-realization-final-rust-tests-20261007.log),
[strict Clippy](checks/rtc-realization-final-rust-clippy-20261007.log) and
formatting pass. The [focused Julia SDK checks](checks/julia-focused.json) pass
321 assertions; native opt-in suites have their separate receipts above. The
pre-existing Rust dependency future-compatibility notice for `proc-macro-error2`
is retained. Archived receipts/logs are small; bulk scientific recordings and
staged packages are not committed.

Raw logs and the exact dependency patch retain their original whitespace and
bytes under scoped Git attributes. Repeated identical Lua snapshots are stored
once, with relative symlink aliases and hashes in `snapshots/aliases.json`;
archival paths and byte checksums remain valid.
