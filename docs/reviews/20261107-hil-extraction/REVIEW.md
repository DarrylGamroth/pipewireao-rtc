# Prepared optical execution ownership

Date: 2026-11-07. This implements the requested external-pupil and clocked-optical
runner extraction. It preserves the preceding RTC cleanup.

## Sources and scope

| Repository | Baseline | Dedicated branch | Development version |
| --- | --- | --- | --- |
| pipewireao-rtc | `4ebd761` | `codex/hil-optical-extraction-20261107` | 0.7.2 |
| AdaptiveOpticsSimPipeWireHIL.jl | `91dc670` | `codex/optical-runner-20261107` | 0.5.1 |
| AdaptiveOpticsSim.jl | `06482bc8` | `codex/prepared-input-copy-20261107` | 0.3.22 |

Work used separate worktrees named `pipewireao-rtc-hil-extraction`,
`AdaptiveOpticsSimPipeWireHIL-optical-runner` and `AdaptiveOpticsSim-input-copy`.
Their baselines were clean. Original worktrees, unrelated processes and installed
applications were preserved. These development versions are not registered
releases; the published RTC 0.7.1 cohort remains available unchanged.

The HIL package is active, not a retired implementation. Its former description
as a narrow lockstep adapter did not describe this new execution responsibility.
Its README and agent guidance now distinguish lockstep exchange from prepared
external-pupil and clocked optical execution. The latter supports independent
camera exposure windows and does not impose lockstep frame/command exchange.

| Responsibility | Owner after extraction |
| --- | --- |
| Models, numerical graph execution, physical planes, exposure integration and model time | AdaptiveOpticsSim and its scientific dependencies |
| Prepared simulation execution, warmup, generation/sequence, reset, pacing, command hold/draining and completed-exposure publication | HIL's `ExternalPupil` module |
| Native streams, buffers, formats, metadata and transport lifetime primitives | PipeWireAO |
| Authored configuration/assets, preparing AOS values, native admission and source controls, session links and deployment | RTC |

RTC's `ext/aos/clocked_optical_source.jl` is removed. The remaining
`external_pupil_owner.jl` shrinks from 874 to 506 lines: together this removes
518 runtime lines from RTC. The 129-line publication selector moves to HIL.
The larger RTC configuration compiler is outside this extraction; this record
does not claim that all simulation-related configuration has moved.

## Interfaces and preserved behavior

HIL accepts prepared AOS graphs, pupil/sensor contracts and values. It imports
neither RTC nor its configuration/bootstrap implementation. No graph parser,
numerical engine, RTC scheduler or second session authority is added.

`ExternalPupil.prepare`, `warmup!` and `prepare_transport!` prepare execution before
admission. `run!` invokes the caller's control function at each serialized duty
boundary. The caller returns `Run(deadline)`, `Hold()` or `Stop()`; handlers use
dispatch. `snapshot` returns the immutable scientific cursor and `reset!` owns
model/transport reset. RTC's private callable `Control` adapts the existing
native source controls and mirrors that cursor for reports. It does not step
the models. Stream lifetime and admission remain with the caller.

Signed Clocks.jl nanoseconds are sampled once at the beginning of each duty.
A clocked source also samples actual step completion to preserve the existing
completion-relative pacing policy. External-pupil model time remains the input
receipt's time. The runner rejects clock regression.

The moved implementation preserves pupil planes and y/x mapping, acquisition
identity and duration, independent optical/electrical classification, camera
exposure rates, coincident/unequal/zero exposure handling and command bounds.
It triggers transport once after a completed source step. Nonthrowing staging
rejection retries a retained sample; partial staging failure requires teardown.
Quiet warmup resets model history, RNG and owned buffers without publishing
synthetic camera frames. Science remains outside PipeWire processing callbacks.

Concrete quiet/live emitter types replace the former `Ref{Any}` publication
cell. Preparation compiles the actual live emitter and control specializations
without running a model step or publishing a sample.

An independent source review found one integration defect in the initial
extraction: HIL reached into AOS's prepared graph context and private device
execution helper. AOS now provides qualified-public
`AlgorithmGraphs.copyto_graph_input!(graph, name::Symbol, source::AbstractArray)`.
It validates graph state, exact shape and element type, copies under the
prepared device context, and marks the graph failed after a copy failure.
HIL uses that API. Independent re-review closed the finding; HIL no longer
depends on the graph's context representation.

| Identifier | Authority and meaning |
| --- | --- |
| `ExternalPupil` | Existing AOS external-pupil boundary and RTC module terminology; the HIL namespace for its execution |
| `Execution`, `prepare`, `run!`, `reset!`, `snapshot` | Prepared execution and serialized control interface within that namespace |
| `Run`, `Hold`, `Stop` | Caller decisions controlling one execution duty, without transferring scientific state ownership |
| `copyto_graph_input!` | AOS `graph_input` interface and Julia's mutating `copyto!` convention; writes an already-prepared named input |

## Verification

Julia 1.13.3 was used. The source cohort is RTC 0.7.2 / HIL 0.5.1 / AOS 0.3.22
with registered FilterGraphs 0.10.0, FilterGraphAlgorithms 0.12.0,
FilterGraphPipeWire 0.5.2, PipeWireAO 0.9.2, JLL 4.0.2+0,
AdaptiveOpticsCalibration 0.17.3 and Proper 0.4.1. The daemon prefix is explicitly
selected from the loaded JLL artifact, not from client preferences.

| Gate | Passing assertions |
| --- | ---: |
| Full RTC core suite | 11,046 across 514 summaries |
| Full HIL suite, including private-core exchange and calibration transport | 3,575 across 11 summaries |
| Moved publication and prepared-runner checks | 124, plus Aqua |
| RTC stream format and timing contracts | 172 |
| RTC quiet owner warmup | 29 |
| RTC real external-pupil preparation | 100 |
| RTC chopped calibration | 58 |
| RTC CPU captured optical preparation | 298 |
| RTC clocked pupil-source science | 56 |
| RTC external optical preparation | 45 |
| RTC private-core external-pupil controls and frame delivery | 17 |
| AOS prepared input copy, CPU | 35 |
| AOS supported API allowlist | 45 |
| AOS prepared input copy, CUDA including captured execution | 42 |
| RTC package API and cold install/relocation selectors after version update | 54 |
| Documentation links, structure and requirement-ID preservation | 716 |

All listed selectors exit 0. The RTC concurrent snapshot test has a variable
assertion count; the summary count is unchanged. The expected missing-Git-object
rejection diagnostic remains in the core log. The full suites ran before the
metadata-only RTC version bump and syntax-preserving HIL formatting. The 124
focused HIL checks plus Aqua were rerun after formatting, and package/export
checks passed after the version bump. Formatting is idempotent and normalized
parsed code is unchanged. The initial formatting checker rejected source-line
nodes attached to macros; it wrote no files. The corrected checker normalizes
those nodes before comparing expressions.

### Corrected existing test contracts

The stream-format selector expected a retired
`pipewireao.header.pts.absolute-conversion` property. The published RTC 0.7.1 /
HIL 0.5.0 cohort reproduced the same eight lookup errors. The selector now checks
the public `reference_clock` contract while retaining model-PTS, exposure-rate,
schema and required metadata checks. The migrated selector passes 172 checks.

The private-core selector initially timed out on its first camera frame. The
published cohort reproduced that failure. Instrumentation showed the pupil
packet was accepted and the scientific sequence advanced, but native camera
links failed buffer allocation with `Invalid argument`. Test camera peers
requested two buffers while the declared camera source pool contained three.
Matching peers to the declared source pool, with no rate or deadline changes,
passed all 17 checks. The normal selector then passed with its original
20-second frame deadline. This fix is committed separately as `ae254f4`.

Cold/live specialization and changing the camera rate did not resolve that
failure. Compilation delay was an initial hypothesis, not the established
cause. Original failures and diagnostic experiments are retained with the
passing result.

### Reproduction and evidence

The [compressed verification archive](verification.log.gz) retains generated
cohort Projects/Manifests, setup/selector scripts, original logs, failed gates
and diagnostic experiments. It includes the final source revisions and exact
commands for the main gates. Optional checks use the generated science
environment; the core suite uses RTC's package environment. Private-core tests
create and close their own cores and do not connect to an installed session.

The AOS public copy is committed as `ef40639`. HIL's extraction and public-API
integration are `05fce75` and `b222e87`; profile documentation and verified
formatting are `061d5a6`. RTC's functional extraction is `b1c19a5`.

These checks establish software behavior, including one CPU native transport
integration and a CUDA prepared-input contract. They do not establish physical
device behavior, target-host deadlines, tail latency, full-instrument closed-loop
performance or deployed accelerator qualification. No installed application or
live RTC was changed.
