# Signed control-clock migrations — 2026-11-05

Source baseline: `b8d8ebc`, branch `codex/julia-session-policy-20261104`, worktree
`pipewireao-rtc-cleanup`; initially clean. The original checkout is preserved.
The migration inventory in `docs/SESSION_POLICY_MIGRATION.md` defines the slices;
the roadmap owns current delivery status. Julia 1.13 and the repository's
JuliaFormatter 2.14.8 BlueStyle configuration are used for these checks.

## CLK-06: physical-offset host chronology

Host receipt and silence fields now retain signed `Int64` nanoseconds. Native
receivers accept `Clocks.AbstractNanoClock`; a poll samples once before draining
receipts, and the graph receiver samples once at the beginning of each loop.
All receipts in that cycle use its sample. Model PTS, exposure duration, identity,
generation and sequence representations remain their existing contracts.

The receiver retains a host-clock watermark across model reset/rearm. A host
regression withdraws every branch sharing that clock, with reason
`:monotonic_clock`. Silence comparisons widen subtraction, preserving strict
expiry after the limit and retaining an observation exactly at the limit.

Observed verification:

- Core physical-offset selector: 127 assertions; optional CPU input selector:
  30; native HIL receiver: 32. The latter drains two receipts with one clock read
  and verifies shared signed arrival ticks, silence and reset chronology.
- A discriminating regression test fails on the baseline: after host ticks
  100 → 200 → 150 the old receiver remains armed. The migrated receiver withdraws.
- Repository formatting is idempotent, with parsed syntax/literal equality;
  `git diff --check` passes. Primary review inspected all seven changed files.

The graph private-core selector is **not qualified**. It fails before the first
frame with `pw_core: alloc buffers: Operation not supported (-95)`. An archive of
the exact baseline reproduces this failure with the same optional dependency and
native SDK cohort. Its cause is unconfirmed; no production workaround was added.
The optional environment is `/tmp/pipewireao-rtc-optical-types-env`, using the
local PipeWireAO/JuliaFilterGraph command-endpoint sources and
`/tmp/pipewire-command-endpoint-native4-sdk-20261104`. The source environment's
Project/Manifest hashes were unchanged. No live service or device was changed.

Local run logs: `/tmp/rtc-clk06-root-final-20261105.log`,
`/tmp/rtc-physical-host-clocks-cpu-20261105.log`,
`/tmp/rtc-physical-host-clocks-input-freeze-20261105.log`,
`/tmp/rtc-physical-host-regression-before-valid-20261105.log`,
`/tmp/rtc-physical-host-clocks-graph-private-20261105.log`, and
`/tmp/rtc-physical-host-clocks-graph-baseline-20261105.log`.

These are software functional checks. They do not establish cadence, allocation
bounds for the graph, real-time deadlines, physical timing or hardware behavior.

## CLK-01/03: native client receipts and decisions

ControlClient stores signed nanosecond receipts/failure watermarks and consumes
signed deadlines directly. Existing `Float64` seconds arguments convert once at
public entries. Session, bootstrap, acquisition lifecycle and calibration client
constructors forward their injected `AbstractNanoClock`; calibration default
deadlines use that bound clock. MediaSession no longer converts receipts or
deadlines through seconds. The existing public `monotonic()` seconds helper
remains a compatibility boundary, reading Clocks directly.

Polling samples once at the beginning of each decision iteration. Callback
receipts retain their producer sample, and each native submission checks its
fresh clock after local encoding and again under the loop lock. Widened remaining
budget arithmetic preserves native `Int64` duration saturation. A retained timely
reply stays resolved after later consumption/retirement; clock regression is
fatal. The timer callback uses an atomic flag across possible Julia threads.

Observed checks: client contracts 60, session selection 18, MediaSession controls
186; native ordinary bootstrap 51, calibration owner 47 and acquisition lifecycle
74. New checks include negative/zero origins, adjacent ticks above 2⁵³, exact
receipt boundaries, duplicate publication, queued known replies, callback
retirement, one sample per polling iteration and fresh submission refusal.
The signed receipt test fails on the baseline's Float64-only observation API.
Independent review found and verified fixes for the timer flag and a calibration
default deadline that originally read SystemNanoClock instead of its bound clock.

The first lifecycle run had 73 passes and one idle allocation assertion failure
(16,784 bytes). Native startup callbacks could invalidate its idle precondition
or allocate during the global allocation counter interval, before any client was
created. Four fresh runtimes each measured 32 locked idle samples at zero bytes,
then observed a native wake after unlock. The test now holds the documented
recursive ThreadLoop lock across its existing warmups and idle assertions. Its
zero-byte budget and production behavior are unchanged; the selector passes 74.
The precise contribution of polling versus concurrent callback allocations to
the original byte count is unconfirmed.

Local logs: `/tmp/rtc-clk03-client-final-20261105.log`,
`/tmp/rtc-clk03-bootstrap-final-20261105.log`,
`/tmp/rtc-control-clock-native-calibration-20261105.log`,
`/tmp/rtc-control-clock-before-20261105.log`,
`/tmp/rtc-control-clock-native-lifecycle-20261105.log`,
`/tmp/rtc-lifecycle-idle-probe-20261105.log`, and
`/tmp/rtc-lifecycle-idle-lock-20261105.log`. These private-core tests use the
explicit PipeWireAO artifact prefix from the package environment. No live daemon,
device or deadline qualification is implied. Server tickets/endpoints are the
next CLK-03 slice; this client commit does not claim their migration.

## CLK-04: calibration preparation and acquisition

Preparation requests/confirmations and acquisition procedure deadlines/completion
events now store signed nanoseconds directly and require AbstractNanoClock.
Each active event retains one decision sample. Completion events separately retain
their producer receipt, accepting queued timely receipts while rejecting future
receipts and regressing decision clocks. Deadline overflow faults before another
command or serial is issued. Terminal preparation events do not sample the clock.

The synchronous driver owns a CachedNanoClock. Its prepared exchange samples the
source at entry and retains a separate receipt on return. The action budget still
starts after cold method/JIT preparation, matching the previous behavior. Native
action clients receive nanoseconds directly. Existing server compatibility
entries and saved reference-report fields still have explicit seconds conversions.
Run/serial, model time, cursors and scientific settling/exposure values are intact.

Observed checks: preparation 239, pure acquisition procedure 219 and driver 268;
optional CPU reference/pyramid 107 and reference cleanup 13. Warmed allocation
checks pass 17, with zero bytes over each of four 1,000-cycle paths (loop,
recovery, coupled recovery and ready preparation). Independent review found no
material issue and verified the known/unknown outcome distinction, one restoration
and release attempt, resumption admission and report units. Primary review also
inspected source changes. These checks do not qualify transport latency or devices.

Local logs: `/tmp/rtc-clk04-procedures-final.log`,
`/tmp/rtc-clk04-driver-freeze.log`, `/tmp/rtc-clk04-allocations-final.log`,
`/tmp/rtc-clk04-reference-cpu.log`, and
`/tmp/rtc-clk04-reference-cleanup.log`. An aggregate rerun initially encountered
an unfinished deployment-source edit before package loading; no calibration test
executed in that attempt. After the edit was finished, the primary's aggregate
rerun passed all 726 calibration assertions
(`/tmp/rtc-clk04-root-final-20261105.log`). Formatting is idempotent with parsed
syntax/literal equality, and whitespace checks pass.
