# Classic registered-package deployment

## Baseline and scope

Approved by the user on 2026-10-19: complete a configuration/FITS-only Classic
application with current JFG, CUDA AOS on the RTX 3080, integration checks, then
launch the headless session and attach the GUI.

Starting revisions: RTC `fdc2c55`, JFG `71585ee`, AOS `23b9dc19`, HIL `3c3de5b`.
RTC and JFG changes use dedicated `codex/classic-*20261019` worktrees. The
original REVOLTRTC working tree has four pre-existing changes; they are preserved.
The old `revolt-classic-pipewireao/deployments/baseline-001` is preserved.

The governing contracts are RTC-ARCH-024/025, RTC-DEV-003/004/006/009/013/021/022/030
and [the registered migration contract](REGISTERED_RTC_MIGRATION.md).
This delivery claims only non-actuating Classic CPU JFG with CUDA AOS. Physical
devices, other instrument profiles and real-time/scientific qualification are
outside this increment. Hsm and Agent remain deferred.

## Ownership

The application contains Project/Manifest, graph/session/simulation configuration,
FITS artifacts, provenance and GUI bindings. Registered Julia packages contain
all executable implementations. Installed native PipeWireAO/WirePlumber assets
remain external dependencies; the installer generates only operational wrappers
and an exact systemd unit outside the scientist's source application.

WirePlumber retains sole admission, links and lifecycle authority. systemd owns
process lifetime. Scientific owner extensions publish Preparing before loading
optional science, prepare validated owned arrays, then follow existing connect,
source-first control and teardown order. No new coordinator or frame scheduler
is introduced. Native live parameter encoding remains unchanged.

## Delivery and coverage

| Allocation | Work | Acceptance | State |
|---|---|---|---|
| AAR-01 | Immutable registered dependency closure and small application | Fresh resolve/instantiate, relocate, no copied source/path dependencies/raw artifacts | Planned |
| AAR-02/04 | Package JFG owner and FITS startup | Type/axis/shape/duplicate rejection, cancellation, parameters before capture/publication | Planned |
| AAR-03/04 | Package AOS owner and explicit geometry | Exact Classic grid/order comparison, GPU preparation, held startup and frame/command association | Planned |
| RTC-DEV-003/004/009/013/021/022/030 | Registered application installer, native controls | Ready/start/stop/reset, parameter submission, cancellation and exact cleanup on owned sessions | Planned |
| RTC-DEV-006 | Shared GUI profile and optional observation | SHWFS, DM and focal image available; GUI closure does not stop RTC | Planned |

Implementation proceeds through package APIs, application construction, software
checks, isolated session integration, independent review, immutable registration,
then the retained GUI session. Preparation and precompilation happen before live
startup; startup budgets are not silently increased to mask failures. Evidence
records failures and limitations separately from successful checks.

## Validation record

Software preparation gates pass on Julia 1.13.2: the RTC suite reports 1,968
assertions in 59 testsets; FilterGraphIsland reports 99; the optional JFG owner
integration reports 18. HIL 0.1.3 reports 1,678 including private-core transport.
[AOS preparation](validation/classic-registered-20261019/AOS_PREPARATION.md)
records exact Classic geometry and same-backend frame/OPD parity on CPU and
the RTX 3080. All 16 RTC startup FITS parameters prepare against current JFG.

The [independent Astra review](reviews/20261019/CLASSIC_DEPLOYMENT_REVIEW.md)
identified incomplete environment validation; sealed environment hashes and
dependency closure/identity validation now reject that case. Legacy source
exports now include optional extensions; the initial broad test run exposed a
relocation failure, and the updated closure plus complete stable rerun pass.

The old Classic graph's `slew_mode=independent` construction field is obsolete
in FGA 0.7 and is removed only in the new application. Its `slew_limit=null`
remains unchanged, so no slew limiter is enabled. All other science settings
and the original 16 FITS files are preserved. Simulation remains 500 Hz model
time, 1,896,000 ns exposure, initially 10 Hz wall pacing. The inherited 900,000 ms
cold startup allowance is retained, not increased.

Native `/opt/pipewireao` is 1.7.0 and lacks the acquisition-v3 trigger symbol
required by registered PipeWireAO 0.6.18. The selected external native prefix
combines the registered PipeWireAO_jll 1.7.1+0 artifact
`3c63168ffd94740be1e2ea34c1eaf12a9468622a` with installed WirePlumber 0.5.18;
`/opt` is preserved. Final immutable registry-only application, relocation,
live session controls/cleanup and GUI attachment remain pending.

The first actual registered session exposed two distinct prerequisites. The
JLL runtime does not include the separately installed queue/SPA plugins, so
the external native prefix must compose them as well. That failed startup's
exact cleanup was confirmed. The next attempt exposed CL-R02: RTC 0.1.2's
AOS default loader resolved weak dependencies in the package rather than the
application. The three default loaders now resolve in Main, retaining early
Preparing and cancellation order. Actual-default-loader regressions fail on
immutable 0.1.2 and pass in the corrected source (CPU 22, CUDA 21 assertions),
independently verified by Astra. RTC 0.1.3 supersedes 0.1.2 for this application;
the earlier immutable release is preserved. No failed attempt admitted ingress.
