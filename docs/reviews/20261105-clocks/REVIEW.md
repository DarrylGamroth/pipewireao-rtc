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
