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
| AAR-01 | Immutable registered dependency closure and small application | Fresh resolve/instantiate, relocate, no copied source/path dependencies/raw artifacts | Passed for 0.1.3; repeat after report fix |
| AAR-02/04 | Package JFG owner and FITS startup | Type/axis/shape/duplicate rejection, cancellation, parameters before capture/publication | Software checks pass; live checks in progress |
| AAR-03/04 | Package AOS owner and explicit geometry | Exact Classic grid/order comparison, GPU preparation, held startup and frame/command association | Geometry/backend checks pass; reset report fix in progress |
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

The third attempt exposed a separate installed-policy mismatch: `/opt` retained
the five-minute preparation cap although the migration baseline already selects
WirePlumber `d20cd203` with an explicit maximum of one hour. The separate prefix
now copies the installed policy assets and replaces only `lib/ao-owner.lua` with
that clean baseline. Its SHA-256 is
`5fbedea5a2b6aa44bb911e864e8f66871bdcfe96303c29391d1ba404300333ec`.
The deployment's 900-second allowance is unchanged. Independent Lua checks
reproduce rejection by the old policy and acceptance by the selected baseline;
invalid and excessive budgets still reject. `/opt` and the immutable JLL artifact
are unchanged.

Registered 0.1.3 then reached native Ready and Running on the RTX 3080 and passed
the same-value scalar transaction. Attempt 004 exposed an incorrect argument
order in the integration driver before any parameter mutation; its exact Quit
and cleanup succeeded. The driver now uses the existing F32_LE command surface
and requires each parameter's requested generation to advance beyond its own
pre-submission baseline. An old active generation cannot satisfy the check.

## Ordinary-source report compatibility

The generic AOS owner must preserve the existing source-control-v1 saved-report
contract, including the empty prepared/reset report and final cleanup report.
This is an operational cursor receipt, not scientific recording or an archiver.
Its location is derived from the private invocation remote:
`dirname(remote)/simulator-wfs-report.json` for the selected Classic source.
No executable or generated raw artifact is added to the application.

The initial report must exist before source snapshot Props become visible.
Successful stopped reset and finite completion must save the new generation and
last adopted sequence before advancing the mailbox's report cursor or issuing a
successful acknowledgement. Final reporting follows transport/optical cleanup;
report failures prevent successful bootstrap termination. The source instance,
bootstrap instance and PID bind the record to the actual owner. The report has
runtime-limited retention; tests copy selected receipts into their evidence
stage. There is no durable instrument-state or science-recording claim.
