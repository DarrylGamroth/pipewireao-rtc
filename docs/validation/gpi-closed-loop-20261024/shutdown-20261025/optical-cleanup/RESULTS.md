# Optical cleanup compilation preparation

The two-line change in `ext/PipeWireAORTCAOSExt.jl` checks
`precompile(OpticalObservation.close!, (typeof(observation), typeof(pipewire)))`
after optical warming and before admission. It executes no cleanup and changes
neither cleanup order nor deadlines. Trial 005 directly measured 1334.6 ms
compiling this entry during successful shutdown; the original timeout's cause
remains unconfirmed.

The corrected fresh private-core CUDA check passes **41/41 checks**, exits 0,
and confirms retirement of its private core. It uses the original registered GPI
science configuration and packages, with only the RTC source overridden. The
script exercises the actual science, observation and HIL preparation interfaces;
it starts no RTC session or bootstrap authority.

With observation enabled, compilation takes 1.547 s and a repeated request
reports no compilation. The worker and native resources survive preparation;
the worker publishes another product (completion count 1 to 2). Actual close
joins the worker, closes snapshots and transport, and leaves the private core
responsive to a fresh public roundtrip. The concrete optical cleanup entry does
not compile again at close. Lower-level HIL compilation remains: 0.640 s within
0.673 s actual close time. This does not establish compilation-free shutdown or
a full-session wall-time improvement.

With observation disabled (`nothing`), preparation takes 0.113 s; actual close
takes 0.010 s with no compilation. Transport closure and a subsequent public
core roundtrip pass. The source hash remains unchanged throughout both cases.

The initial harness run failed: 40 passed, one errored, process exit 1. Its
post-close assertion lacked an explicit import of the public, unexported
`try_snapshot_graph_output!`. Its internal receipt boolean was written before
the outer test aggregate and must not be treated as a passing result. The
[first-attempt summary](first-attempt-summary.json) records this distinction.
The corrected script imports the function and saves the outer aggregate result.
No production change was made between attempts.

The [summary](validation-summary.json), [receipt](receipt-v2.json),
[script](smoke-v2.jl) and [compressed log](run-v2.log.gz) retain the checks and
identities. The scratch [runner](run-v2.sh) records the exact environment and
command; its absolute paths refer to the preserved investigation directory.

Independent final review inspected the source hash, assertions and log and
found no blocker. This is software/resource verification, not hardware,
real-time, tail-latency or registered-release qualification. Trial 005's native
Quit result precedes this cleanup patch; no full session was rerun afterward.
The live deployment remains unchanged.
