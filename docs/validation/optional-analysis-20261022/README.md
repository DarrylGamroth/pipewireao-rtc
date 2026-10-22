# Optional WFS analysis process — 2026-10-22

This gate moves Classic's WFS summary out of its required JFG controller. It
preserves `org.calculon.ao.shack-hartmann-summary/1`, its eight fields, and the
ordinary ndarray GUI sources. It does not introduce an instrument-specific GUI
handler or a discovery/proxy daemon.

## Ownership and transport

`deployment.analysis` declares optional graph processes. Each has its own Julia
runtime and ordinary systemd service, outside required owner admission, native
control connections and the required cohort. The first Classic process uses
CPUs 6/7 (one physical core outside the required owners' physical cores). Its
client loads no realtime module; systemd denies realtime scheduling. `Requisite`
and `PartOf` depend on the RTC in one direction, without starting or restarting
it. Startup checks native readiness and exact invocation under the lifecycle
lock. There is no ordering edge that could delay required stop while optional
teardown completes. A failed analysis process is recreated by a new RTC deployment;
manual replacement of the retained service incarnation is fenced during cleanup.

Existing capacity-one copy/drop-oldest queues supply slopes, flux and validity.
The analysis graph has independent input arrivals, one copied slot per input,
and no wait in its callback. Its output has an exclusive observation queue on
the observer loop. Deployment validation rejects direct control inputs,
required playback consumers, secondary output writers and queue overrides that
would introduce retention or backpressure. This validation is deliberately
narrow; it is not a general-purpose queue or process topology API.

The join requires the same acquisition domain, generation, sequence and Header
PTS on all contributors. A newer generation resets only the analysis graph;
late generations and same-generation rewinds are dropped. Domain replacement
latches admission closed until reconstruction. Incomplete or incoherent windows
produce no diagnostic packet. Algorithms retain numerical validity policy,
including legitimate NaNs in invalid WFS rows.

Links use the standard SDK link factory and copied registry metadata. The
analysis node must match the process's actual published ID. Endpoint serials
are checked before creation, after negotiation and during operation; LinkInfo
must match the selected endpoints. Factory creation itself does not atomically
fence serials. The sealed core queue modules remain stable for the invocation;
manual module/node replacement within that core is outside this deployment.
Core loss destroys the private remote and the ordinary links do not linger.

## Evidence

Local runtime: Julia 1.13.2, single-threaded BLAS/FFTW, CPU simulator. Package
changes are JuliaFilterGraph 0.4.1, FilterGraphPipeWire 0.1.6 and PipeWireAORTC
0.2.5; all other application pins and scientific calibration assets are held.

Raw local receipts and logs:
`/home/dgamroth/workspaces/codex/worktrees/optional-wfs-analysis-20261022`.
The initial candidate is an immutable package snapshot, not a registry version
published before testing. Final registration and live receipts are recorded
below after validation.

- Focused strict synchronization: 220 checks; all 17 measured warmed arrival,
  reset and rejection paths allocate zero bytes.
- Adapter: 782 checks, including an actual strict row-major matrix callback
  and exact output acquisition identity/PTS.
- RTC configuration/lifetime policy: 97 checks, plus 157 adjacent systemd,
  registered-environment, SPA-JSON and graceful-stop checks.
- Extension ownership/readiness regression: 13 checks, including readiness
  publication while the owner thread is in a native wait.
- Actual systemd reverse-stop ordering: 6 checks, before and after removal of
  the optional `After` edge (`ordering-final/ordering-result.json`).
- Offline sealed Classic preparation: 74 checks on the initial candidate.
- [Independent review](../../reviews/20261022-optional-analysis/REVIEW.md)
  includes the cleanup ordering fail-before/pass-after proof. Optional receipt
  failure cannot prevent verified required-owner teardown.

The native fault/replay candidate uses RTC tree
`fc59c6c6a1c60ae816ada147476b7c4c012aa15a`. Final production code differs
only by removal of the optional `After` edge, covered by the separate manager
ordering test. Test/documentation updates are recorded in git.

Live CPU fault/replay and final deployment validation are in progress. The
maintained executable gate is
[`classic_optional_analysis.jl`](../../../test/integration/classic_optional_analysis.jl).
It uses the retained native FFT execution witness for exact detector replay,
an independent controller replay against the graph before the WFS diagnostic
was added, an independent eight-field summary oracle, and exact sample
identity/PTS checks.

## Limits

Process separation isolates Julia GC, compilation, scheduling and process
failure domains. It does not remove shared CPU-cache, memory-bandwidth or kernel
contention. Finite CPU replay and fault tests do not qualify a wall-rate,
latency SLO, arbitrary overload, hardware, GPU or other instruments. Mean slopes
remain detector-pixel measurements, not calibrated physical tip/tilt/focus.
More algorithms can share this analysis graph; further optional processes can
use distinct names and exclusive output queues when isolation is useful.
