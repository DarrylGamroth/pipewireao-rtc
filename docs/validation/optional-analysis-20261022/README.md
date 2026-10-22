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
Test candidates were immutable package snapshots, not registry versions
published before testing. Final local registration uses RTC commit
`aa6ca4f9c9a9d797060683572bf14c0f0e73413e`, tree
`0289467179b49448e4323354a496896b858a38bb` (0.2.5). JFG 0.4.1 and adapter
0.1.6 are subpackages of commit
`5a8dc2fdb0f5ae58e7f7dc3b108448ea2a1d1b48`, with trees
`8e9db0cebdc4dfdef47993e871343e320a7d2fdc` and
`22f2b21f721a7d9f0453dbff3045a2c08dcdc9f5`. These versions are in the private
review registry under `~/.local/share/classic-review-20261020/`.
Classic application commit `d81e3de9bfe6a3bf2d9ccc1604d55fd97f0aef96` pins
only these three updated packages, with no checkout or repository overrides.
The scientific calibration identity is unchanged.

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
- Final sealed Classic preparation: 74 checks (`offline-final.log`). All 47
  assets are sealed; no GPU modules/libraries or live services are used.
- [Independent review](../../reviews/20261022-optional-analysis/REVIEW.md)
  includes the cleanup ordering fail-before/pass-after proof. Optional receipt
  failure cannot prevent verified required-owner teardown.

The native fault/replay candidate uses RTC tree
`fc59c6c6a1c60ae816ada147476b7c4c012aa15a`. Final production code differs
only by removal of the optional `After` edge, covered by the separate manager
ordering test. Test/documentation updates are recorded in git.

The CPU fault/replay gate passes 3,944 assertions (`integration-final3.log`):
2,999 normal/suspended/resumed, 473 crashed-analysis, and 472 failed-analysis
preparation checks. Five 32-frame generations run in three private sessions at
2 Hz wall pacing with the 500 Hz physical model. Each completes detector,
command, slope, flux and validity observation streams with exact identities. The
original controller outputs match bitwise replay in all five generations;
detector replay matches in the first three. Normal and resumed summary packets
match the independent eight-field oracle with exact identity and PTS.
All three sessions pass Stop/Quit and exact cleanup; Reset passes in the
first two sessions. The first is torn down while analysis is suspended. `fault-final3/optional-analysis-result.json`
retains scoped results and test/manifest digests. The maintained executable gate is
[`classic_optional_analysis.jl`](../../../test/integration/classic_optional_analysis.jl).
It uses the retained native FFT execution witness for exact detector replay,
an independent controller replay against the graph before the WFS diagnostic
was added, an independent eight-field summary oracle, and exact sample
identity/PTS checks.

An earlier attempt (`fault-final2`) lost five observation samples because its
fault callback blocked the observer's polling loop for three seconds. The
source timing witness nevertheless recorded all 32 control exchanges. The
maintained test schedules the delayed fault asynchronously and waits for that
task before teardown; the unchanged production runtime passes with all 32
observations. This was a test-harness defect, not evidence of control backpressure.

## Live deployment

Classic is left Running on CPU with the software-rendered GUI and optional
analysis process. The live copy is under
`~/.local/state/pipewireao/classic-cpu-analysis-live-20261022`; the saved
application's CUDA default is unchanged. The live physical model remains 500 Hz
with 10 Hz wall pacing. The GUI binary is unchanged (`44c9190`, Glow), SHA-256
`6c595f54ca06d4a6d0d8096244a3b4e224adc663a77194700744e2419d2483bb`.

- RTC: `pipewireao-session@0506e9722c2a.service`, invocation
  `f8ad08134fc64d559886e352924e316e`.
- GUI: `pipewireao-classic-cpu-analysis-gui-20261022.service`.
- Analysis: `pipewireao-owner-f8ad08134fc64d559886e352924e316e-analysis-wfs.service`.
- `live-wfs-check.json`: 32 samples from each of detector, slopes, flux,
  validity and summary; 31 matched cohorts have identical acquisition identity
  and PTS and bitwise-exact independent summary results. The RTC remains Running
  before and after capture, with the original calibration identity.
- The GUI has an active summary subscription and a slope subscription. Hidden
  detector/flux/validity views were not required to subscribe; this is not a new
  manual rendered-UI validation. The GUI binary and interfaces are unchanged.
- `live-analysis-policy.json`: four active analysis links, analysis outside the
  required owners, affinity 6/7, Nice 10, realtime denied, `Requisite`/`PartOf`
  pointing to the RTC, no reverse-stop ordering edge, and no required RTC
  `Requires`/`Wants` dependency on analysis.
- `live-gpu-audit.json`: core, RTC, controller, parameter owner, simulator,
  analysis and GUI have no GPU runtime mappings or GPU device handles.

The three fault stages retain both `final-launch.json` and
`retained-analysis.json` cleanup receipts, with empty optional errors. Their
phase-timing records were also copied out of `/run` for durable local evidence.
No GitHub-hosted checks, native rebuild or GUI rebuild was needed for this
change. Source/runtime updates are merged into the local main checkouts; the
registered RTC source tree remains immutable while later commits record these
results.

## Limits

Process separation isolates Julia GC, compilation, scheduling and process
failure domains. It does not remove shared CPU-cache, memory-bandwidth or kernel
contention. Finite CPU replay and fault tests do not qualify a wall-rate,
latency SLO, arbitrary overload, hardware, GPU or other instruments. Mean slopes
remain detector-pixel measurements, not calibrated physical tip/tilt/focus.
More algorithms can share this analysis graph; further optional processes can
use distinct names and exclusive output queues when isolation is useful.
