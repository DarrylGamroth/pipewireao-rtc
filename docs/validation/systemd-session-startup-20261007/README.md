# Ordinary systemd session startup checks

Executed 2026-10-07–08 on rtc-devel, Julia 1.12.7 and systemd 257.13.
Baseline `6c16609`; isolated implementation branch/worktree and exact source
hashes are in [the receipt](receipt.json). No scientific source was changed.
The existing GUI/HIL service retained MainPID 1632744 throughout these checks.

## Observed results

| Check | Result |
| --- | --- |
| Complete Julia SDK suite | 2,629 assertions, 89 test sets; exit 0 |
| Actual user-manager arguments/environment and failed target member | 16 assertions pass |
| Same check with spaces, Unicode and `%` in working paths | 16 assertions pass |
| Interrupted unit removal/reload recovery and replacement-file fence | 11 assertions pass |
| Copper CPU FGN with CUDA AOS | Native Ready, stopped/running gain requests, stopped reconstructor request, reset/resume, correlated Quit and empty cleanup pass |
| Copper CPU JFG with CUDA AOS | Same selected lifecycle/control checks pass |

Each real session used a fresh private core, generated ordinary owner service
files and target, and the existing native placement/admission hook. Gain and
reconstructor requests use each graph's existing endpoint names. The short
sessions ran the existing 10 Hz wall-paced, 2 ms model configuration. Scientific
artifact hashes were checked unchanged while refreshing the sealed operational
SDK. Native command success is recorded; these checks do not measure every
parameter's frame-boundary adoption or allocations.

Normal shutdown requires the existing correlated Quit→Offline acknowledgement.
Both final receipts show `cleanup_complete=true`, `unit_files_removed=true`, no
pending cohort start jobs and empty owner cgroups. Generated runtime fragments
and links were removed; diagnostic launch records remain.

The SDK log includes expected negative-input YAML diagnostics and git-provenance
probes from non-repository test exports. All assertions passed. No Rust or
WirePlumber production source changed, so no rebuild of those projects was needed.

## Failures and remediation

The initial actual-unit probe rejected quoted `WorkingDirectory=` values.
[The failed receipt](unit-probe-initial-failure.log) is retained. Path directives
now use a literal single-line value with escaped percent specifiers; both final
round-trip checks pass.

[Independent review](REVIEW.md) confirmed SSD-001: fragment deletion followed by
reload failure prevented later cleanup from converging. The recovery experiment
uses the actual installed pre-fix launcher, injects a reload failure after file
deletion, and observes its subsequent retry fail. The fixed implementation saves
the removal phase first, converges on retry, and rejects a changed replacement
file. The final recovery log records 11 passing assertions.

Early integration harness attempts used the calibration-only `ready` helper with
a retained correction-source package, then used JFG gain/parameter names for FGN.
Those requests were rejected and the affected cohorts were cleaned up. The final
harness uses native session Status and each existing graph's correct endpoint
names. These were harness corrections, not changes to scientific controls.

## Scope

These are deployment software/integration checks. They do not establish new
numerical equivalence, zero-allocation, exact frame delivery, deadline or tail
latency results. Existing broader qualification limits remain. HEART's necessary
controller-PID stage was preserved and independently source-reviewed; HEART,
Classic, row-block and physical-device deployment were not rerun here.

Logs: [SDK](sdk-tests.log), [unit probe](unit-probe.log),
[working paths](unit-paths.log), [removal recovery](removal-recovery.log),
[FGN session](fgn-session.log), [JFG session](jfg-session.log).
