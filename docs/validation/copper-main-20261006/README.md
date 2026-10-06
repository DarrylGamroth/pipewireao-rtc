# Installed Copper qualification, 2026-10-06

The installed CUDA AOS / CPU JFG Copper cohort passes the selected functional
observer and simulator Julia heap gates after refreshing RTC main `ef8ead2`
and PipeWireAO SDK `1417b69` (0.6.17). The preparation helper verifies source
seals, refreshes runtime dependencies through Pkg, installs a fresh package,
and verifies every protected scientific file unchanged. Original packages and
failed trials remain separate.

## Observed results

| Gate | Result | Scope |
| --- | --- | --- |
| Baseline, unattended observation, observer death/replacement | Six complete 256-exchange trajectories, before/after reset, have identical detector and DM bytes | Actual native client identities and offscreen production ViewPanel; no visible desktop qualification |
| Observer stall | Science advances during the owned observer's 0.5 s SIGSTOP; its complete 256-exchange trajectory matches baseline | One stall case; no latency or rate claim |
| Simulator allocation | Two 512-exchange runs each measure 496 completed exchanges after prefix 16, with zero Julia heap allocation and zero GC counters | Entire simulator process; excludes separate JFG process, native/CUDA allocation and final serialization |
| Cleanup | All five cases exit normally and remove owned units/processes | Unrelated user processes preserved |

Model rate is 500 Hz. Wall pacing is 10 Hz for full trajectories and 100 Hz for
allocation. These are functional/resource checks, not qualified maximum rates.
Optical truth diagnostics were disabled: `truth_evaluated=false`,
`truth_equal=null`. The old v1 comparator incorrectly labeled equality of empty
disabled truth records as truth equivalence; CIG-001 is corrected by GUI main
`59cb087`, with 108 focused cold assertions and the regenerated v2 comparison.
The detector/command hashes are unchanged; no science rerun was needed.

The [receipt](receipt.json) binds installed descriptors, preparation proofs,
executables, reports, trajectory hashes, service exits and resource cleanup.
The [independent review](INDEPENDENT_REVIEW.md) independently decoded the full
trajectories, rehashed protected files and checked process absence. It accepts
only the bounds above. Original detailed reports remain at the receipt paths.

## Reproduction boundary

The RTC development helper is
`scripts/refresh_qualification_runtime.jl`; its accepted Copper invocation is
preserved at commit `5bcbdd0`. The GUI's existing
`scripts/check_native_hil_gui.jl` runs the installed `trajectory-baseline`,
`trajectory-unattended`, `render-death`, `render` and `baseline` scenarios in
systemd mode. Each run uses fresh runtime/evidence directories; the receipt
identifies the exact installed package and executable. The cold
`compare-trajectories` command uses baseline, unattended and death reports.
Full trajectory prefixes equal the total; allocation uses prefix 16 of 512.
Do not reuse the slow wall pacing or zero measured post-prefix trajectory
counters as performance evidence.

## Calibration startup finding

The following separate Classic native-calibration diagnostic did not complete
Collect and is not a Copper scientific acceptance result. Two RTC-owned Julia
calls supplied a bare `timeout_ns` argument without the keyword semicolon to
`PipeWireHILConfiguration`, producing a positional UInt64 `MethodError`.
Commit `310257f` adds the semicolon in ordinary and HEART calibration wrappers;
HEART vendor code, science parameters and adapter APIs are unchanged.
The exact old expressions fail, and the focused real-constructor checks pass
18 assertions. The fresh installed trial then reaches `Running` but aborts
Collect with `InvalidEvidence`, confirms restoration and completes tracked
process cleanup. The rejected completion was not retained, so its validation
branch and physical cause remain unconfirmed. This failure stays open; further
Collect/Capture profiles and scientific matrix acceptance are not implied.
