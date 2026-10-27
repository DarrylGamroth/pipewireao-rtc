# Protective correction recovery — 2026-10-27

Status: selected CPU software scope validated. Existing live GPI2,
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

The configured full RTC suite at `17b2250` passed **5,376 assertions in 199
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
its full configured suite: **5,556 assertions in 207 testsets**, exit zero. The
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
| NP-01 | P1, actual private-core failure and deterministic callback/cache reproduction | Cached native reference evidence stopped advancing while successful frames continued. JFG `b673c05` publishes advancing proof at bounded intervals, without restamping old evidence. The same callback/cache regression failed three assertions before the fix and passes afterward. |
| NF-01 | P1, source review and native regressions | A cached positive reference could outlive its owner timeout. RTC `45913bb` checks the owner monotonic timestamp before release or guarded close. Stale and future witnesses are refused before effects. |
| CA-01 | P1, source review and scripted fail-before/pass-after | A preliminary ordinary hold admitted a competing close before scoped recovery inhibition. RTC `4c975e1` issues the existing scoped request first, then observes its forced-open and recovery generations. The legal competing-client regression fails 8 of 9 assertions against the previous client and passes all 9 after the fix. |

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

## Native publication and private-core validation

JFG `b673c05` passes the full adapter suite: **1,827 assertions in 84 testsets**,
exit zero (`graph-publication-full.log`). Recovery proof notifications use the
existing coalesced Props publication path at intervals bounded by the smaller of
100 ms and one quarter of the active reference timeout. Callback-side due checks
retain zero Julia allocation. RTC `45913bb` passes all **12 native test programs**
including monotonic-age admission (`native-freshness.log`).

Private run013 used a real isolated PipeWire core, production RTC Lua, declared
bootstrap owner, native client and CPU graph. It passed 17 checks over 42 frames:
the command saturated at 0.8, recovery reached the nonzero 0.2 reference subject
to a 0.1/frame slew limit, ordinary close was refused while inhibited, and six
frames after explicit resume remained at 0.2. Controller/filter/delayed feedback
histories were zero at Holding. This run precedes CA-01 remediation and therefore
does not prove safe initial admission against a competing client.

The preceding run012 safely refused resume because cached witness sequence/time
did not advance, despite continuing reference-valued output. These failed and
passing receipts, exact harness sources, hashes, configurations and unfiltered
logs remain at
`/home/dgamroth/.cache/pipewireao/protective-recovery-20261027/e2e/`.
No existing live services or GPU processes were modified. Owned run013 processes
were reaped and independently checked absent.

The forced private RTC SIGTERM after the passing phase logged session-control
publication failure, NULL `wp_properties_get` assertions and uncertain source
hold. These teardown messages are retained. Full application Quit/terminal
source-removal qualification is not established by this recovery check. Finite
cold functional budgets are not latency or real-time evidence.

The atomic-first client revision `4c975e1` passes **154 coordinator and 123 client
assertions** (`admission-gap-after.log`). The scripted counterexample explicitly
adopts the old ordinary-open generation before the competing close, so the
native control slot is free and retained correction can legally return on the
old path. The new first request installs inhibition while still pending. Tests
also cover the native scientific generation remaining unchanged until adoption
and a first readback that already shows application. Independent review found
no remaining actionable issue in this sequence. This is a scripted concurrency
regression, separate from the actual private-core functional proof.

Run014 then repeated the actual native sequence on committed RTC `4c975e1` and
clean canonical JFG main `b673c05`: **17/17 checks passed over 41 frames**. The
command reached 0.8 saturation, recovered to the 0.2 reference by frame 16,
refused ordinary close while inhibited, and explicitly resumed by frame 35.
All six subsequent frames remained at 0.2; no old saturated correction returned.
The coordinator ended Closed. Native owner/bootstrap and the scientific history
checks passed. Only documentation/evidence edits were uncommitted during this
run; production file hashes are in [the receipt](native-run014/receipt.json).
The exact harness, graph source and unfiltered logs are retained beside it.

Run014 used the same cold functional budgets and synthetic CPU composition as
run013. The existing SIGTERM teardown limitation remains visible in its RTC log.
Owned PIDs 1523497 and 1524030 were reaped and independently checked absent.
These checks establish software recovery behavior, not physical settling,
automatic supervisor integration or an enabled live GUI operation.

The run014 invocation was:

```sh
/home/dgamroth/.cache/pipewireao/protective-recovery-20261027/e2e/with_environment.sh julia --startup-file=no --threads=4,0 --project=/home/dgamroth/.cache/pipewireao/protective-recovery-20261027/e2e/environment /home/dgamroth/.cache/pipewireao/protective-recovery-20261027/e2e/harness.jl /home/dgamroth/.cache/pipewireao/protective-recovery-20261027/e2e/run014
```

Reproduction needs a new output directory, the recorded SDK/native build and
source revisions. The retained harness has explicit local checkout paths; after
worktree cleanup, point its RTC path and Julia environment at the canonical
checkout containing `4c975e1` before running. The four JFG packages already point
at canonical JFG main. No harness command installs or replaces a live session.

The final full RTC suite at `4c975e1` passed **5,575 assertions in 210 testsets**,
exit zero (`rtc-final-full.log`). There were no unexpected warnings or failures;
the Git missing-object message is the existing catalog rejection check. Historical
RTC totals above were corrected by summing all retained testset summaries; the
earlier manual counts had omitted testsets. No behavior changed in that recount.
