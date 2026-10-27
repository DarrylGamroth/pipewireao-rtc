# Protective correction recovery — 2026-10-27

Status: source and CPU software validation in progress. Existing live GPI2,
Classic and GUI services have not been changed by this increment.

## Scope and source

Requirements RTC-DEV-032–036 select explicitly configured simulated complete-frame
CPU graph owners. Recovery is distinct from ordinary nonzero hold/resume. A
successful reference observation proves the conditioned command, not physical
settling. No physical-device authority, GPU controller, automatic reclose or
application-specific intervention threshold is qualified here.

Work started from RTC `06fa9ea` and JFG `4e578f4` in dedicated worktrees. RTC
commits `f040fc6`, `7543327`, `68c30eb`, `ef3747d` and `17b2250` add supervision,
Hsm sequencing, the retained native client and admission. Scientific history
recovery is JFG `c1674bb` (equivalent to `95e25a7`); owner controls are `f392f00`
and `8744e41`, with review remediation in `35009b1` and `d656769`.

## Verification

Julia 1.13.3, CPU, one Julia worker thread unless an isolated native harness says
otherwise. Native tests use upstream libwireplumber 0.5.18 built against
PipeWireAO, the unchanged SDK
`/home/dgamroth/.local/opt/pipewireao-loop-controls-20261026`, and a task-owned
Meson build. No user systemd units are started or stopped.

Focused RTC command:

```sh
julia --startup-file=no --threads=1,0 --project=. -e 'using PipeWireAORTC; for name in ("correction_loops", "correction_timers", "correction_recovery", "correction_recovery_client", "correction_supervision", "graph_owner"); Base.include(Module(gensym(:RecoveryTests)), "test/test_"*name*".jl"); end'
```

The coordinator has 152 passing assertions, the native scripted client 106,
supervision 268 and graph-owner argument/FITS selectors 78. Existing ordinary
loop/timer selectors pass. Scientific `recover!` has 871 assertions, including
saturated commands, nonzero reference/current, Float32/Float64, finite slew,
unequal update rates, preserved quantization/RNG continuity and warmed zero
allocation. These scientific assertions were independently rerun during review.
Native Meson tests pass all 12 programs, including recovery request/release,
closure inhibition and guarded unmixed first-close admission.

The first broad RTC invocation omitted the documented `PIPEWIREAO_PREFIX` and
failed in the pre-existing schema/configuration tests. That is environment setup,
not behavioral evidence; the configured invocation is recorded separately on
completion. The first broad FGPW run overlapped a source/test update and also
exposed cold compilation exceeding the default five-second test witness budget.
Non-expiry behavior tests now use a bounded 60-second budget; deterministic
expiry tests retain exact injected age boundaries. A final stable-source run is
required before promotion.

The configured full RTC suite at `17b2250` passed **5,298 assertions in 198
testsets** with `PIPEWIREAO_PREFIX` set to that SDK. Exit status was zero; no
unexpected warnings or test failures were reported. The Git object-missing
message is exercised by the configuration-store rejection tests. Logs are
retained alongside this record.

## Final stable-source CPU gates

At JFG `b82f1bd`, the complete FilterGraphPipeWire package suite passed **1,803
assertions in 82 testsets**. The separate scientific recovery selector passed
**871 assertions**. This includes rejected/in-flight frames, release expiry,
reset, mixed close, callback-time reference loss and unchanged ordinary
hold/resume after the first validated close. Independent final source review
found no outstanding actionable issue at that revision.

After merging current RTC main into the recovery branch, RTC `ad9887c` passed
its full configured suite: **5,446 assertions in 206 testsets**, exit zero. The
unchanged native source at `17b2250` passes all 12 Meson programs. The broad CPU
commands are:

```sh
PIPEWIREAO_PREFIX=/home/dgamroth/.local/opt/pipewireao-loop-controls-20261026 julia --startup-file=no --threads=1,0 --project=. test/runtests.jl
# In the JFG integration checkout, with its task-local resolved test Manifest:
julia --startup-file=no --threads=1,0 --project=test -e 'using Pkg; Pkg.test("FilterGraphPipeWire"; allow_reresolve=true)'
julia --startup-file=no --threads=1,0 --project=test julia/FilterGraphAlgorithms/test/recovery.jl
```

Cold preparation of the actual Classic source graph (11 nodes) and deployed GPI2
graph (30 nodes) also accepts their declared recovery scopes and exact delayed
feedback bridge. Classic selects `pdm-command`; GPI2 selects `modal-filter`,
`tiptilt-filter`, `tiptilt-command`, `woofer-command`, `tweeter-command`. The GPI2
path requires a zero-feedback witness only from the selected unquantized
`tiptilt-command` constraint-feedback Port. Demanded output is not substituted
for feedback even when their schemas match. Quantized feedback cascades and
filters downstream of feedback/static bias are conservatively refused.
The retained harness and log establish topology admission with neutral
calibration builders; they do not establish calibrated closed-loop performance,
FITS adoption, physical operation or a live deployment.

## Independent review and disposition

| ID | Severity / evidence | Finding and disposition |
| --- | --- | --- |
| GR-01 | P1, deterministic CPU reproduction | Omitted causal temporal history could falsely claim the reference. Scope admission now requires causal histories and qualifies supported reference composition; ambiguous paths are rejected before effects. |
| GR-02 | P1, deterministic CPU reproduction | Reset could consume a release then invalidate the reached reference while leaving closure unlocked. Reset now invalidates proof before consuming pending controls; the first-close guard remains authoritative. |
| GR-03 | P1, deterministic CPU reproduction | An in-flight frame during pending release could leave cached positive proof. Successful frames refresh pending-release proof and adoption checks the current serialized state. |
| GR-04 | P2, deterministic CPU reproduction | Released status stopped refreshing successful-frame sequence/time, preventing fresh post-release validation. Released frames now refresh the witness. |
| CR-01 | P1, deterministic coordinator reproduction | Legitimate same-false recovery-open requested/active generation mismatch faulted the coordinator. Staging binds that exact expected generation and tolerates only its pending/adopted open readback. |
| CR-02 | P1, deterministic coordinator reproduction | A newer negative reference during Releasing did not fence an older positive release. It now advances the watermark and latches failed prerequisites. |
| CR-03 | P1, scripted native fail-before/pass-after | A slow successful readiness reply could exhaust a phase but still issue its effect. Native exchanges are clamped to the phase budget and checked again before writes; old code issued a late open/close, current code issues neither. |
| CG-01 | P1, callback-boundary tests | Reference could change after release and before close adoption. A guarded first close rechecks current proof at adoption; lost proof leaves the controller open and re-inhibits recovery. |
| CG-02 | P1, source review and focused regression | Control-thread staging read processing-owned scientific arrays. Staging now uses atomic snapshots/seqlock proof only; direct current-state checks are confined to serialized adoption. |
| CG-03 | P1, source review and focused regression | A mixed first close/reference edit could bypass validation of the new reference. Both RTC admission and graph staging require the guarded first close to be unmixed. |

Reviewers assessed different implementation ownership: the scientific implementer
reviewed graph/native-client controls, and the graph implementer independently
reviewed scientific recurrence and the coordinator/supervisor. Root inspected
interfaces and integrated the findings. All remaining qualification gaps must be
kept explicit; passing software checks do not establish hardware correctness.

## Unselected behavior

`CorrectionSupervision` is an optional recommendation evaluator with explicit
thresholds and a monitor-only default. Automatic stream binding, numerical trip
thresholds and deployment intervention are not selected. The GUI's existing
Open/Hold operation retains correction; it is not silently changed into
protective recovery. No live application has been opted into the new operation.
