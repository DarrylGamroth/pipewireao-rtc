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

## CLK-05: correction, recovery and supervision

Correction loops, recovery and supervision retain signed host timestamps and
durations directly, without Common/callable adapters. Each observer/driver cycle
samples its source first and updates its owned CachedNanoClock. Snapshot queries
are staged for the next decision cycle so receipts produced during a query are
compared with that cycle's later sample. Producer timestamps, tokens, generations
and sequence widths remain separate. Native session transports use the bound
client's clock rather than assuming the system clock domain.

Elapsed/freshness comparisons widen arithmetic. Regression and deadline overflow
fail closed without retry. An overflowing standalone correction request latches
Unknown before transition/timer setup; a late readback cannot revive it. Signed
zero/negative samples use explicit presence rather than positive-time sentinels.
The existing expiry-before-adoption rule and published field names are preserved;
decimal host-time readers now accept signed values.

The primary aggregate passes 1,750 assertions across 99 testsets; an additional
two assertions verify native transport clock-domain propagation. The final bound
client selector passes after that addition. Optional graph observer checks pass
46 and private-core timers 56. Source review caught and resolved the standalone
overflow transition and native transport clock-domain seams. Formatting preserves
parsed syntax/literals and is idempotent; whitespace checks pass.

The first primary aggregate selected an optional graph observer without its
science environment and stopped at a missing FilterGraphAlgorithms import. It
was rerun with only core selectors; the separate optional selector uses the
science environment. This was a harness/environment error, not a package failure.

Local logs: `/tmp/rtc-clk05-root-final-20261105.log`,
`/tmp/rtc-clk05-bound-client-final-20261105.log`,
`/tmp/rtc-clk05-recovery-final-20261105.log`,
`/tmp/rtc-clk05-native-final-20261105.log`, and
`/tmp/rtc-clk05-standalone-overflow-20261105.log`. These checks do not qualify
physical recovery, deadlines or hardware. Existing warmed Hsm allocation checks
are recorded under CLK-04.

## CLK-03: server admission and capture closure

ControlEndpoint tickets use signed nanosecond deadlines anchored to a producer
receipt taken before decoding. Endpoint clocks are injected directly; fresh
admission/effect checks run under the native loop lock. Checked receipt-plus-budget
overflow produces a known rejection before staging. Clock regression fences the
endpoint. Bootstrap Monitor retains one source sample per Agent cycle and uses
signed cached cleanup deadlines. Lifecycle/bootstrap publication fences, calibration
waits and parameter-owner timers consume these signed values; only Timer/sleep
receive seconds. Public Float64 deadlines normalize at entry.

InitialCalibration, reference preparation, native action clients, capture waits
and capture-file guards now share the same supplied clock and nanosecond deadline,
without internal seconds round trips. Saved reference reports retain their
seconds fields, and recording epoch/reference timestamps retain their native
clock and metadata representation. Capture wait samples once at the beginning of
the locked decision after owner supervision; native/I/O boundaries independently
guard their fresh clocks. Capture-file guards also retain regression watermarks.

Independent review found two capture issues and verified their resolution:

- **R01, confirmed pre-existing gap:** preflight header encoding separated its
  check from storage reservation. A fresh check now precedes byte reservation,
  run/serial mutation and directory creation. The same regression test fails four
  assertions with only that guard removed in an isolated method override; with
  the guard, expiry leaves budget, identity and directory untouched.
- **R02, confirmed migration regression:** sampling before a slow supervision hook
  could consume a complete capture after exact expiry. Sampling once inside the
  locked decision after supervision restores refusal. The same probe originally
  returned success/Idle, then throws deadline failure and retains Complete after
  the fix. Ten permanent checks cover negative and >2⁵³ origins.

Observed checks: 512 pure server/protocol checks; native endpoint 110, faults 149,
lifecycle 74, bootstrap 51, action retirement 17, calibration effects 47 and sealed
terminal release 66; optional CPU reference/pyramid/cleanup 120. Native selectors
include repeated client checks, so these counts are not an independent aggregate.
Capture files pass 249; native-buffer-backed CPU capture waits pass 152. Formatting
is idempotent with parsed syntax/literal equality and whitespace checks pass.

The first optional reference run encountered an in-progress optical extension
import error and precompile fallback; a later fresh run explicitly asserts both
extensions loaded and passes cleanly. Earlier interrupted source-loading attempts
are not qualification evidence. Actual parameter-owner loop execution and a real
scientific InitialCalibration run remain unverified; private-core effect tests
do not qualify hardware, sustained cadence or deadlines.

Local logs include `/tmp/rtc-clk03-server-pure-bounds.log`,
`/tmp/rtc-clk03-server-native-sealed.log`,
`/tmp/rtc-clk03-server-reference-final.log`,
`/tmp/rtc-clk03-capture-files-final-20261105.log`,
`/tmp/rtc-clk03-capture-reservation-before-20261105.log`,
`/tmp/rtc-root-capture-review-probe-20261105.log`,
`/tmp/rtc-root-capture-review-probe-after-20261105.log`, and
`/tmp/rtc-root-capture-review-after-20261105.log`. Native tests use explicitly
selected private cores/artifact SDKs and change no existing services or devices.

## CLK-08: deployment waits and optional analysis lifecycle

SystemdOwners, its unit-file helpers, SessionRuntime/Launch and SessionCLI now
forward AbstractNanoClock and signed deadlines through their caller chains.
Each owned polling loop samples once at its beginning and reuses that decision
tick for expiry/sleep. Native clients and subprocess submissions retain separate
fresh guards. Duration conversion/addition/subtraction is checked; regression is
refused. Grace/timeout keywords and subprocess/sleep budgets retain seconds.
Existing public seconds inputs normalize at the SystemdOwners entry boundary;
its compatibility `monotonic()` helper reads Clocks directly.

Analysis lifecycle-lock/start/cleanup and simulator replacement now forward the
same clock and signed deadline, including optional service operations and recovery
receipts. The Analysis lock samples once per locked-attempt decision and releases
flock in `finally`. Simulator callers of the removed Runtime seconds helper were
found during primary caller review and migrated before integration. No new
supervisor, authority, fallback or shared clock wrapper was introduced.

Observed verification: the primary aggregate passes 597 assertions across 39
testsets (systemd, runtime, configuration, stop, Analysis and simulator).
The worker's focused run passes 370 and final runtime rerun 87. These overlap and
are not additive. New deterministic clock coverage includes 82 worker assertions
plus 13 Analysis lock assertions: negative origins, >2⁵³ adjacent ticks, exact
expiry, regression, overflow, subprocess refusal, cleanup order and lock release.
The first Analysis run used the wrong expected error family for an invalid
deadline; the assertion now uses the existing SystemdOwners.OwnerError contract.
Source-copy test modules import Clocks and forward the new keywords. Formatting
is idempotent with parsed syntax/literal equality; whitespace checks pass.

Local logs: `/tmp/rtc-clk08-focused-20261105.log`,
`/tmp/rtc-clk08-runtime-final-20261105.log`,
`/tmp/rtc-clk08-root-final-20261105.log`, and
`/tmp/rtc-clk08-simulator-20261105.log`. Verification uses temporary files,
fake process-manager observations and local process checks. It performs no live
systemd, affinity, priority, device, deployment or hardware changes. Actual
manager behavior and target-host timing remain separate qualification.

## CLK-02: retire shared clock adapters

After source search confirmed no remaining runtime/extension consumers, Common's
clock constant, signed/unsigned nanosecond adapters and unit-dependent callable
fallbacks were removed. Owners use Clocks directly. Tests for the retired adapter
contract were removed; no replacement wrappers or tests of Clocks internals were
added. The remaining Common utility selector passes 70 assertions, both alone
and in the primary deployment aggregate. Formatting preserves parsed syntax and
literals and is idempotent. Local log:
`/tmp/rtc-clk02-common-final-20261105.log`.

ControlClient/SystemdOwners retain their existing public seconds compatibility
helpers, implemented directly with Clocks; maintained runtime callers use signed
deadlines. Epoch/reference timestamps and scientific/model chronology remain
outside this removal.

## CLK-07: optical pacing and diagnostic throttle

OwnerState, SourceControl and AOS/pupil/external-pupil callers use signed host
ticks and bounded signed pacing periods. Each owner loop samples once for its
cycle decisions; separate completion measurements preserve the existing overrun
policy. AOS/pupil owners skip elapsed host periods without skipping scientific
steps; clocked external-pupil processing waits one period after step completion.
Zero pacing stays immediate. Host regression and checked deadline overflow refuse
further timed work. The host watermark survives model reset. Offset observations
share the owner cycle's sample, and publisher workers receive the injected clock.

Optical diagnostic throttling retains post-exchange time. Publisher trigger/status
throttles retain their relative wait after actual I/O completion. Independent
review caught and resolved an intermediate migration that anchored these waits to
cycle start: with 3 ms trigger work and a 2 ms period, or 150 ms status work and a
100 ms period, the same test produced four/three effects instead of one before
the fix. Separate checked completion measurements restore the full relative wait.

Model/exposure durations, fixed scientific steps, generations/sequences and public
HIL timing fields retain their representations. Saved PhaseTiming rows remain the
existing UInt64 tuple ABI; signed owner values convert explicitly and reject
negative values when optional timing capture is enabled. Ordinary negative-origin
pacing works with that capture disabled. No timestamp reinterpretation/clamping
was added at that saved-data boundary.

Observed gates total 495 assertions: core source-control/declaration 263, external
cold configuration 43, native-free preparation 42, timing/throttle/worker 72,
idle allocation 8, native Pause/Run continuity 11 and CPU chronology/export 56.
Idle checks retain zero bytes over 1/100/1,000 polls; timing checks include a
zero-byte 1,000-cycle path. Primary and independent source reviews found no
remaining material issue after the pacing fixes. Final repository formatting uses
JuliaFormatter 2.14.8, preserves parsed syntax/literals and is idempotent.

Two pre-existing integration defects were confirmed and narrowly corrected:
PupilOutput passed `reference_clock` positionally to an all-keyword upstream
constructor; its explicit keyword now permits real CPU preparation. A final
constructor-only test input lacked the declared exposure records and represented
ordinary sensors as chopped; it now declares 2 ms exposures and empty chopping,
retaining its existing schema/storage/metadata assertions. Scientific production
configuration and algorithms were not changed by that test correction.

Interrupted concurrent extension compilation exposed cache-lock waits and missing
build-ID warnings. Final selectors ran sequentially. A compile-min allocation
probe, missing prefix/FITSIO setup attempts and the original failures remain in
local logs; they are not promoted as runtime or allocation evidence. The native
continuity run passed with precompile warnings; a clean released dependency
cohort and graph cadence/GPU/hardware/deadline qualification remain separate.
The three cold 30-second warmup/worker waits are the next slice.

Local logs: `/tmp/rtc-clk07-core-final.log`,
`/tmp/rtc-clk07-external-config.log`,
`/tmp/rtc-clk07-preparation-stack.log`,
`/tmp/rtc-clk07-timing-reviewed.log`, `/tmp/rtc-clk07-idle-final.log`,
`/tmp/rtc-clk07-pupil-private-first.log`,
`/tmp/rtc-clk07-pupil-cpu-complete.log`,
`/tmp/rtc-clk07-regression-before.log`, and
`/tmp/rtc-clk07-worker-relative-before.log`.

## CLK-09: identity seeds and elapsed report measurements

The final non-deadline reads now use Clocks directly. Controller instance seeding
explicitly converts the signed tick's bit pattern to the existing unsigned seed
range before the original locked positive/nonreuse sequence. This is an identity
boundary, not unsigned deadline arithmetic. Client checks pass 62, including the
two identity range/nonreuse assertions.

Pyramid modal validation accepts AbstractNanoClock for its host measurement.
It samples at step start and separately at completion, widens elapsed subtraction,
refuses regression and converts only the result to the existing `step_ms` report
unit. Scientific model steps, outputs and report fields are unchanged. A fresh
optional Calibration extension load passes three checks with this method present;
a full scientific modal-validation run was not repeated. Formatting is idempotent
and preserves parsed syntax/literals. Logs:
`/tmp/rtc-clk09-client-final-20261105.log` and
`/tmp/rtc-cold-calibration-extension-load.log`.

`Base.gc_time_ns()` remains a cumulative diagnostic counter. Native recording
epoch/reference clocks, wire identities and model/exposure chronology keep their
own contracts; a host-clock source scan does not justify retyping them.

## CLK-07/08: cold optical preparation waits

The remaining three 30-second waits now use injected AbstractNanoClock values,
checked signed deadlines and one source sample at the beginning of each iteration.
Clock propagation reaches optical owner preparation/run, observation warm/reset,
and publisher start/drain/reset. Startup diagnostic `at_ns` fields use direct
signed Clocks readings while retaining their names and nanosecond units.

These cold waits preserve the existing readiness-first contract: an available
owned acknowledgement/snapshot succeeds before temporal refusal, including at
expiry or a regressed clock. Pending waits reject regression/exact expiry.
Overflow refuses the wait; each budget still begins after the same existing
setup effects. Pupil warmup always restores its first model phase in `finally`.
Native effect admission remains a separate fresh-clock boundary. No replacement
clock wrapper, scientific time change or frame scheduler was introduced.

Final checks pass 153 assertions: 94 deterministic cold waits, 56 real CPU
preparation/chronology/export checks (including a negative CachedNanoClock on
real preparation), and three fresh Calibration extension-load checks. Formatting
uses JuliaFormatter 2.14.8, preserves syntax/literals and is idempotent. Primary
review inspected all seven changed files and their caller chains.

Initial test attempts reused a busy test snapshot and called a function through
the wrong test namespace; fresh owned records and the correct public binding
resolved these harness errors. No production timing failure was inferred from
them. This slice performs no live core/affinity/device/GUI/GPU actions; native
cold-owner runtime, scientific modal validation and real-time deadlines remain
unqualified. Logs: `/tmp/rtc-cold-optical-waits-final.log`,
`/tmp/rtc-cold-optical-pupil-cpu.log`,
`/tmp/rtc-cold-calibration-extension-load.log`, and
`/tmp/rtc-cold-optical-format.log`.

## Core integration

The official core selector, with the explicit PipeWireAO artifact prefix, reached
`test_calibration_action_client.jl` and exposed a test double lacking the client's
new bound clock. Its helper now owns a CachedNanoClock with a negative origin;
the selector passes all 64 existing assertions. Its request-mutation test also
uses method dispatch rather than a type branch. No production fallback was added.
The failed selector and all remaining original selectors pass in an isolated
continuation of the original test list. The successful unchanged prefix is
retained rather than duplicated. Together the logs report 11,331 passing
assertions in 515 passing summaries, including subprocess selectors; this is
completion in two segments, not an uninterrupted green full-suite invocation.
The initial missing-clock error remains recorded. The later client clock-source
change also has its separate 62-check fresh-process gate.

Local logs: `/tmp/rtc-clock-core-suite-20261105.log`,
`/tmp/rtc-clock-action-fake-final-20261105.log`, and
`/tmp/rtc-clock-core-remainder-20261105.log`.

Final source search finds no direct `time_ns()` reads, Common clock adapters or
`isa` branches in maintained `src/` and `ext/`. The remaining
`Base.gc_time_ns()` is a cumulative measurement counter. Changed local Markdown
targets and final newlines pass; the roadmap retains its pre-existing historical
link to the retired `tests/calibration.rs`, also present at the baseline. No
generated files or historical evidence were rewritten. Qualification limits
under the individual slices still apply.
