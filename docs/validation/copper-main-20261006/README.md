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
process cleanup. The original rejected completion was not retained.

### Completion evidence and Capture diagnosis

Commit `ca85db3` adds opt-in cold Rust client diagnostics: decoded
`CalibrationCompletion` records are retained before coordinator validation and
written after acquisition. The qualifier preserves the final owner report
before removing its private instance. Live controls remain native SPA PODs.
The default calibration path and its restoration rules are unchanged.
The [independent diagnostic review](CALIBRATION_DIAGNOSTIC_REVIEW.md) accepts
these semantics. Its resource finding CCE-001 is closed by `8167bbe`: nested
JSON objects and exposure construction use conservative charges under a bounded
accounting budget, explicitly separate from measured RSS/allocator heap limits.
Five focused Rust tests and strict Clippy pass; qualifier tests pass 193 asserts.

The [unchanged Collect repeat](classic-collect-diagnostic-v4.json) establishes
that serial 4 (first Collect) returns `valid=false`, 376 finite measurements,
and 16 consecutive exposure records (sequences 2–17). Restoration and release
complete. The owner counts 17 invalid exposures out of 18 including settling
and restoration; this aggregate does not identify each exposure's validity.
There are zero ADC upper-rail pixels. The rejected scientific batch remains a
failed Collect gate even though transport and safe restoration worked.

The subsequent [existing Capture operation](classic-capture-v1.json) passes
its full functional gate: two raw/flux/slopes/validity captures, restoration,
release, explicit unsupported Reset rejection, shutdown and tracked cleanup.
Both frames contain selected ROIs with positive flux below the sealed 1000
flux threshold (952.8125–993.8125). Those ROIs have intrinsic validity false,
as required by both Rust and Julia centroid algorithms. The frozen pixel
threshold is 20 and the active mask remains 184 of 188. No threshold, noise,
illumination or mask was changed to obtain either diagnostic result.

### Declared illumination fixture and Collect/Capture results

The frozen prototype's plant uses `source_magnitude=2.0`. The original run82
recipe specifies lamp magnitude 0.5; `--illumination lamp` removes atmospheric
input but does not apply that brightness. A fresh development fixture applies
the existing recipe's 0.5 magnitude and retains the prototype's detector seed 0.
It does not reproduce the earlier seed82 acquisition or seed98 HEART transfer.
The helper uses the existing model-setting and deployment APIs, verifies all
580 seals, and keeps 578 protected files byte-identical. Thresholds, active mask,
noise, exposure, probes, matrices, owner code and algorithms are unchanged.
The destination-specific unsealed systemd unit is regenerated by the installer.
The independent preparation review is in
[the diagnostic review](CALIBRATION_DIAGNOSTIC_REVIEW.md#independent-classic-lamp-fixture-preparation-review).

The [fresh Collect receipt](classic-lamp-collect-v1.json) passes the existing
installed functional gate: four valid finite 376-value batches with 16
consecutive exposures each, 69 total exposures including settling/restoration,
zero quality-invalid exposures, zero ADC upper-rail pixels, and maximum ADC 1691
of 4095. Restoration, release, unsupported Reset rejection with unchanged facts,
native shutdown and owned-process cleanup all pass. The previous dim fixture's
failed Collect remains preserved. These controlled results support the
illumination diagnosis; no native serialization or scheduling defect was shown.

The [separate fresh Capture receipt](classic-lamp-capture-v1.json) also passes
the existing installed functional gate. Both captured frames have 184 valid
selected ROIs, exactly matching the unchanged active mask. Minimum selected
flux is 4918.5 and 4986.0625 against the sealed 1000 threshold. All four exposures
including settling/restoration are quality-valid with no ADC upper-rail events;
maximum ADC is 1659 of 4095. Capture payload and metadata hashes/counts,
restoration, release, Reset rejection, native shutdown and tracked cleanup pass.

The completion journal in this run uses the frozen `ca85db3` client, before the
`8167bbe` accounting correction. Its 32 records are far below the accounting
budget; the receipt preserves the actual executable hash and source boundary.
No inverse, interaction-matrix acceptance, three-way numerical equivalence,
allocation, maximum-rate or latency claim follows from this small functional
run. Other selected consumers remain open.
