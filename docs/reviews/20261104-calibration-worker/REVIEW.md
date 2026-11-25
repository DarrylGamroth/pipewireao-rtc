# Calibration worker command ownership — 2026-11-04

## Scope and source cohort

The user authorized the upstream public command endpoint and the calibration
worker migration. They subsequently clarified that scientific graph execution
must remain on a PipeWire data thread; the Hsm owns lifecycle state on a separate
control thread. RTC-ARCH-024/026 and RTC-DEV-029/030 remain authoritative. No
session authority, data scheduler or production process boundary was added.

RTC work continues in `pipewireao-rtc-cleanup`, branch
`codex/package-cleanup-20261104`, based at
`4658e7f676c538df01c919b4902c9df25a63a105`. Earlier cleanup and optical edits
were preserved. Upstream work uses separate sibling worktrees:

| Component | Worktree | Source base / local changes |
| --- | --- | --- |
| Native PipeWireAO | `pipewire-command-endpoint-native4` | `9ae604802866515a3df884b96b8878f37b70f7c3`, matching the native 4 artifact; accessor and native tests |
| PipeWireAO.jl | `PipeWireAO-command-endpoint` | `26955ff70d5666411f6008921530b1f746ecb70e`; local commit `a7b46ae` plus typed receiver roots |
| FilterGraphPipeWire | `JuliaFilterGraph-command-endpoint` | `ad3217b337daccce25a296716da9cd9d4bab55c2`; public adapter, optional Parameter Ports and tests |

Source package versions are PipeWireAO 0.9.1 and FilterGraphPipeWire 0.4.1.
The calibration feature requires these versions and Julia 1.13. The unchanged
core APIs retain PipeWireAO 0.9.0 compatibility and their registered manifest;
FilterGraphPipeWire 0.4.1 requires PipeWireAO 0.9.1 when the optional feature is
installed. Optional validation selects both upstream sources in an isolated
environment. Development path overrides were removed from the RTC project
through `Pkg.free`. No package, artifact or source was published, and no
installed RTC, instrument, service, priority or CPU affinity was changed.

## Endpoint and ownership

| Finding | Classification / confidence | Disposition and evidence |
| --- | --- | --- |
| CMD-01 — Shared node and readiness/error Refs | Accepted design improvement; source-confirmed | Replaced by private lifecycle/Hsm and bounded commands/receipts |
| CMD-02 — Two status callers can wait on one receipt | Confirmed migration defect; high confidence; liveness impact | Locked readiness/drain transaction; identical 12-assertion reproduction leaves one blocked caller before, none after |
| CMD-03 — Duplicate stop under controller-task contention | Derived race; high confidence; liveness impact | Stop admission rechecked inside the queue transaction; deterministic contention/full/closed tests |
| CMD-04 — Completed task does not imply successful resource release | Accepted lifetime hardening; source and synthetic-fault evidence | Explicit release flag gates reclamation; native destruction failures remain unqualified |
| CMD-05 — Registered artifact does not provide the new accessor | Confirmed delivery boundary; high confidence | Explicit rebuilt SDK and source environment; artifact publication remains separate |

Accepted improvement; implemented. The native public
`pw_ndarray_filter_get_loop` accessor returns a borrowed owner loop. It requires
owner-thread source construction/destruction and does not expose native layouts
or change the frame-processing path. Generated Julia bindings were regenerated
from that header; their diff adds only the accessor wrapper and documentation.

PipeWireAO exposes `command_endpoint`, `commands`, `try_send!` and
`check_command_error`. The receiver and callback remain rooted by the owner-side
filter. A shareable `CommandSender{T}` contains only a bounded typed queue and
synchronized native wake state; it contains no filter, graph, Hsm or callback.
Submission returns accepted/full/closed without waiting for queue capacity or a
reply. A native wake error seals the sender and reports an error. Accepted means
enqueued, not executed.

The native main-loop callback drains at most the configured capacity and never
waits for a message. Callback errors are contained at the C boundary, seal the
sender, stop the loop and propagate from `run!`. Source removal and signaling
share the wake transport lock, preventing a signal from using a destroyed
source. Receiver closure is owner-thread-only after `run!` returns; closing a
filter with open receivers is rejected. Synchronization belongs to transport,
not to shared application state.

| Context | Private state | Communication |
| --- | --- | --- |
| RTC controller thread | Worker handle, received status/error, stop admission | One cold stop or native sender; readiness/completion receipts |
| Worker control thread | Node lifecycle, command receiver, Hsm | Native loop receives StopGraph; publishes owned lifecycle receipts |
| PipeWire data thread | Active prepared graph execution and buffers | Existing native frame transport and lifecycle barriers |

The prepared graph is lent exclusively until cleanup acknowledgement and task
completion. The controller retains a reclamation handle but does not inspect or
mutate the running graph. Measurement count and the active selection are
captured before lending. Live sparse Parameter Ports and their update callback
are disabled for these cold-bound calibration nodes. Graph parameter
declarations, bound arrays and FITS provenance remain intact. The public upstream
default continues to expose live Parameter Ports.

## Lifecycle and shutdown

`CalibrationWorkers.Lifecycle` uses Hsm.jl. Constructed, Prepared and Connected
share Cold under Active; Running is also Active. Cold cancellation uses the
shared Active handler. Running handles stop by requesting native loop quit on
its own control thread. Stopping absorbs remaining startup events and duplicate
stops; the root Finish handler closes the receiver and node, then publishes the
completion receipt. Scientific setup stays in event handlers, outside entry and
exit behaviors.

The Run handler schedules the native loop as an effect. Execution begins only
after Hsm dispatch returns, allowing native command callbacks to dispatch events
without recursive Hsm handling. No extra AgentRunner wraps the blocking call:
the native loop itself services the bounded control endpoint.

Each worker has a one-slot preparation queue, one-slot native command queue and
two lifecycle receipt slots. A shared queue transaction serializes publication
of the native sender with cold stop admission. Thus a controller either submits
to the cold queue or observes the sender; it cannot miss both routes between
readiness and run entry. Stop admission is rechecked inside that transaction so
two tasks on the controller thread cannot submit duplicates under contention.
Unexpected full/closed cold queues fail promptly. Repeated stop is idempotent.
Status drains hold their receipt-channel lock across readiness and consumption.
Without that transaction, two tasks could observe one receipt and leave the
second waiting indefinitely. A bounded identical reproduction demonstrated one
blocked caller before the fix and none after, with 12 assertions passing.

Completion records failure and a separate `released` flag. A stopped task does
not by itself release storage. Native execution failure can release storage if
receiver/node closure succeeds; closure failure clears the flag and preserves
the error. Both normal and partial-preparation cleanup require a completed,
nonfailed task and an explicit release receipt before closing scientific graphs.
Failures are consumed by the controller rather than read from shared Refs.

The synthetic close-failure test establishes this reclamation guard. It does
not qualify continued callback rooting after an actual failed native destruction;
that exceptional case requires process cleanup. Native source/filter destruction
returns void in the selected SDK. A release receipt proves native lifetime ended,
not that an ignored native deactivation error could not have occurred.

## Verification and investigation

The selected SDK is `/tmp/pipewire-command-endpoint-native4-sdk-20261104`.
Its library SHA-256 is
`18b71ce62a869e139b7fec65db16362ab072ed6f5dc4b7929ad6ac27876be297`.
All 246 installed headers match the existing native 4 artifact except the
intended accessor declaration. Build recipe and logs are under
`/tmp/pipewire-command-endpoint-native4-build-20261104`.
The full SDK build retains two warnings in unchanged `conf.c` and SPA hook
sources; the accessor and its tests introduce no build warnings.

The first attempted native checkout contained older metadata. Binding generation
detected the mismatch before endpoint integration. That SDK was rejected and
rebuilt from exact artifact provenance; no generated binding was edited by hand.
An early RTC selector also demonstrated that setting a daemon prefix alone does
not select the client library: the temporary validation environment now declares
the JLL directly, records its path preferences and checks the loaded accessor.

An optional main-loop co-location experiment passed the affinity assertion for
preparation/process/command callbacks. Its data-thread negative control failed
only that assertion. The Classic probe-adoption pilot timed out under co-location;
its cause was not established. Following the user's explicit scheduling decision,
the experiment and its public option were removed. Logs remain under `/tmp` and
are not evidence for the delivered data-thread profile.

Two test-boundary corrections preserve the actual contracts. Relocation staging
now resolves development dependency paths relative to the source manifest before
generating the temporary validation manifest; copying relative paths unchanged
caused four reproduced SDK-load failures. The Classic pilot checks its resolved
production detector, including scientific defaults, instead of requiring those
defaults to be repeated in authored component overrides. Numerical assertions
remain unchanged. Named transport explicitly checks the broken-pipe error from
its deliberately removed feedback link, which older teardown discarded.

All final selectors completed with exit status zero:

| Check | Passing result |
| --- | ---: |
| Native accessor, admission, metadata, publication and run control | 7 selectors |
| Final complete PipeWireAO.jl suite, including endpoint and Aqua | 2,198 assertions / 72 summaries |
| Focused endpoint / Aqua / typed-root and doc checks | 61 / 11 / 3 assertions |
| FGPW parameter-port graphs and compositions | 48 assertions |
| Final RTC core suite | 9,514 assertions / 426 testsets |
| Package/source relocation after restoring registered core dependencies | 417 assertions |
| Worker lifecycle, queue contention, startup/run cancellation and failed cleanup | 97 assertions |
| Identical old/new status-contention reproduction | 12 assertions |
| Scalar / named private transport | 33 / 24 assertions |
| Registry readiness with exact notifications | 62 assertions |
| Final Classic CPU pilot, including restoration/release and controller loss | 106 assertions |

The worker and named selectors each also execute 99 existing projection checks;
these repetitions are excluded from their table counts. The FGPW selector's
final native-flag assertions ran with `--compile=min`; it makes no compilation,
allocation or timing claim. Core assertion count varies with the existing
concurrent snapshot test: it ran 77 checks here versus 90 in the optical cohort;
the package closure gained two checks. No testset or assertion was removed.
The full core run used the source 0.9.1 client; focused package checks passed
again with the restored registered 0.9.0 core client. Optional graph checks use
the final 0.9.1/0.4.1 sources and rebuilt SDK.

Independent review of native/Julia lifetimes, queue lock ordering, graph lending,
Hsm dispatch and test changes found no unresolved confirmed source defect.
CMD-02 was reproduced and corrected during that review; its final worker and
Classic selectors passed after the repair.

Detailed receipts include `/tmp/pipewireao-command-endpoint-suite-final-20261104.log`,
`/tmp/pipewireao-command-endpoint-final-rt-20261104.log`,
`/tmp/fgpw-parameter-ports-20261104.log` and `/tmp/rtc-command-*.log`.
The contention reproduction and old source are retained in
`/tmp/calibration_graph_status_contention_20261104.{jl,log}` and
`/tmp/calibration_graph_status_before_20261104.jl`.

Focused commands use Julia 1.13.3 and the optional environment
`/tmp/pipewireao-rtc-optical-types-env`, which directly declares the scientific
packages, Hsm, Proper and PipeWireAO_jll. JLL path preferences select the rebuilt
client library; verify them in a fresh process before running selectors.

```sh
export PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104
export OPENBLAS_NUM_THREADS=1
julia --startup-file=no --threads=4,1 --project=/tmp/pipewireao-rtc-optical-types-env test/calibration_worker.jl
julia --startup-file=no --threads=3,1 --project=/tmp/pipewireao-rtc-optical-types-env test/calibration_transport.jl
julia --startup-file=no --threads=4,1 --project=/tmp/pipewireao-rtc-optical-types-env test/calibration_named_transport.jl
julia --startup-file=no --threads=4,1 --project=/tmp/pipewireao-rtc-optical-types-env test/calibration_readiness.jl
```

The Classic selector uses four default plus one interactive thread and
`PIPEWIREAORTC_CALIBRATION_APPLICATION` pointing to the existing read-only built
Classic CPU application. It verifies the application hashes remain unchanged.
The full core command remains the repository-prescribed package-environment
command with its artifact prefix. No application installation is performed.

## Deployment and performance boundary

The registered native artifact lacks the new accessor. Endpoint use requires the
selected rebuilt SDK until a corresponding artifact is released. The temporary
source environment and explicit native prefix are validation inputs, not an
installed application upgrade.

PipeWire supports per-data-loop `thread.affinity` and `loop.rt-prio`, with RT
permission handled through module-rt and OS policy. Those settings apply to the
graph-hosting client's loop; pinning Julia-managed threads does not establish the
affinity of a PipeWire-created data thread. This increment changes neither.
Allocation, GC, first-use/JIT cost, cadence and tail latency remain separate
qualification obligations. Functional tests do not establish a strict RT bound.
See the [PipeWire configuration reference](https://docs.pipewire.org/page_man_pipewire_conf_5.html),
[module-rt](https://docs.pipewire.org/page_module_rt.html) and
[ThreadPinning API](https://carstenbauer.github.io/ThreadPinning.jl/stable/refs/api_pinning/).
