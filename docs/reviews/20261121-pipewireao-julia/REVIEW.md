# PipeWireAO.jl and native PipeWireAO ownership

On PipeWireAO.jl 0.9.3 the binding rejected a fixed format accepted by SPA
and accepted duplicate metadata requirements when given a vector. Both fixes
and the RTC consumer changes are recorded in the
[verification below](#format-and-metadata-fix-verification).

## Scope

The RTC Manifest at the review baseline selected PipeWireAO.jl **0.9.3** (`46f32308`) and
PipeWireAO_jll **4.0.4+0**. The JLL records native source `d20e7669`.
I compared the binding's public surface and handwritten source with that
source, checked symbols in both installed shared libraries, and traced callers
in the RTC, FilterGraphPipeWire and the HIL adapter. The native diff through
**4.0.6** changes poll-driver video buffer ownership and FGN startup/feedback
metadata. The format, metadata, introspection, loop and NDArray filter APIs
discussed here have the same source in both releases. Runtime checks used
4.0.4 on x86-64 Linux. The source baseline for this RTC review was `0a4344f`
on a dedicated worktree based on the controller admission refactor.
[Julia release](https://github.com/DarrylGamroth/PipeWireAO.jl/tree/v0.9.3)
· [JLL source receipt](https://github.com/DarrylGamroth/PipeWireAO_jll.jl/blob/PipeWireAO-v4.0.4%2B0/README.md)
· [Native release diff](https://github.com/DarrylGamroth/PipeWireAO/compare/v4.0.4...v4.0.6)

## Findings

**PWJL-01 · NDArray format parsing · High priority, reproduced.**
I built an offer with U8 as the default and I8 as an alternative. Native SPA
fixation leaves a Choice containing the selected value. On the same bytes,
`spa_format_ndarray_parse` returned success and reported U8 with shape (3,).
Julia's `NdArrayFormat` expected a bare ID and threw `ArgumentError`. The
Julia schema reader also requires a fixed Choice to have exactly one child.
MediaSession and ParameterSource each unpack selected values before invoking
the binding. Bind the native sized parser and schema-string reader. Preserve
Julia's representable array-size checks and the public ownership of returned
values. Successful native parsing is only one condition for RTC admission.
Preserve the current bounds on POD size, property count, scalar widths, schema
text and complete Choice children where each caller requires them. Test both
valid fixation and invalid encodings before removing either workaround. The
RTC still compares the selected shape, layout, rate and schema with its declaration. The native format builder supports choices but has no schema
argument. Preserve that property when migrating the writer.
[Julia parser](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/spa.jl#L1564)
· [Native NDArray helpers](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/spa/include/spa/param/ndarray-utils.h#L143)
· [RTC Link validation](../../../src/media_session/objects.jl)
· [RTC ParameterSource](../../../src/control/parameter_source.jl)

**PWJL-02 · Metadata validation · High priority, reproduced.**
A tuple containing the same optical metadata requirement twice returns
`false`. A vector containing the same two entries returns `true`. The tuple
method submits the whole list. The vector method calls C once per entry, so
the native duplicate-type check never sees the pair. Pass the complete list
in both overloads and keep the single-entry behavior and allocation contracts.
The SDK already owns record layout validation, lookup, initialization,
transport-owned type classification and copy. Julia should own the lifetime
of retained snapshots and the bounds on borrowed views. Its `metadata_fits`
capacity check also serves a distinct purpose from performing the native copy.
[Julia overloads](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/metadata_records.jl#L481)
· [Native validation](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/spa/include/spa/buffer/meta.h#L449)

**PWJL-03 · Object snapshots and listener removal · Confirmed duplication.**
The Julia `InfoTracker` reconstructs Node, Port, Device and Link snapshots by
change mask, including parameter flag-change bookkeeping. Native
`pw_*_info_merge(current, update, false)` already owns those rules. Delegate
at the listener callback while the C update pointer is valid, copy the result
to an owned Julia value, and free the tracker's native storage at teardown.
Preserve raw delta callbacks and the lifetime of snapshots returned earlier.
MediaSession has another merge implementation spanning Node, Port, Client,
Factory and Link. It also validates observations in arrival order. Native
merges assume one object stream and retain fields such as initial Port
direction and Link endpoints. The RTC must still see the raw event when an
identity change or a bad Link followed by a good Link can invalidate admission.
A latest-snapshot poll cannot establish that history.
[Julia merge](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/objects.jl#L118)
· [Native merge](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/pipewire/introspect.c#L164)
· [RTC object and Link handling](../../../src/media_session/objects.jl)

Julia also edits both neighbors of a native SPA linked-list hook and calls
its removal callback. The installed `libspa-ao` exports `spa_hook_remove`.
Use that native operation and retain Julia's single-close guard, cleared
handle, loop locking and callback roots. The existing singleton-list test
protects a case that previously required a fix in the Julia pointer code.
[Julia hook removal](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/listeners.jl#L73)
· [Native hook removal](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/spa/include/spa/utils/hook.h#L457)

**PWJL-04 · Run/reset serialization and SPA PODs · Confirmed duplication.**
The allocating run/reset builders encode property names, version and state in
Julia. The prepared `!` builders call the four native `pw_ao_*_build_*`
functions, and the parsers already call C. Use the native builders for both
entry points. Keep the allocating result owned and the prepared result
borrowed. Existing tests cover matching POD bytes and zero warmed allocations
for the prepared path. MediaSession uses the allocating requests. Command
admission, token correlation, deadlines and interpretation of completion
belong to the endpoint owner and the RTC.
[Julia builders](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/run_control.jl#L52)
· [Native codecs](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/pipewire/run-control.c#L59)
· [RTC control operations](../../../src/media_session/controls.jl)

The broader Julia POD reader/writer also implements alignment, scalar and
Choice encodings, typed format construction and decoding. The JLL
ships the corresponding builder/parser primitives and raw audio/video format
helpers in **libspa-ao**. The current generator primarily targets
**libpipewire-ao**. Generate bindings to the correct product before adding
new C entry points. Keep Julia's owned values, checked conversions and
caller-provided storage. `PropsBuffer` adds a distinct contract for an exact
set of named scalar fields with a preallocated destination updated only after
all fields validate. Generic SPA parsing alone does not provide that guarantee.
Julia can retain the typed tuple and its storage. If this exact-schema
contract is to be shared across languages, native PipeWireAO should own
the bounded validator. Each endpoint should still declare its own fields
and interpret their values.
[Binding generator](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/gen/generator.jl)
· [Native SPA shared library](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/spa/lib/lib.c)
· [Julia prepared Props](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/props_buffer.jl#L124)

**PWJL-05 · Prepared NDArray exchange · Confirmed Julia protocol.**
`NdArraySource` and `NdArraySink` build on ordinary `pw_stream`. They copy
through one privately owned slot per endpoint, support selected packed element
types, and impose an arm/submit/wait protocol. A source token acknowledges
queueing the output buffer. A sink receipt requires a separately armed match
on Header sequence or AcquisitionIdentity and optional exposure duration.
Retries, deadlines and failure on unexpected input are observable parts of
this protocol. Within RTC I found callers in test fixtures and no references in the production source or extensions. Its production calibration
stream uses a different completion condition, and the HIL adapter has its own
gap and drop accounting. Keep the one-shot protocol with exchange clients or
shared test support under the thin-binding rule. If multiple languages need
that *same* contract, implement it once in native PipeWireAO and bind it.
Deprecate the exported helpers only after migrating callers. This finding
does not imply any change to the continuous detector handoff.
[Julia exchange](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/ndarray_exchange.jl#L56)
· [Native stream API](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/pipewire/stream.h)
· [RTC exchange fixture](../../../test/media_session_private_core.jl)
· [RTC calibration stream](../../../ext/calibration_transport.jl)

**PWJL-06 · Julia task and loop bridges · Confirmed Julia behavior.**
`command_endpoint` obtains the native filter loop and signals a native event.
A Julia Channel supplies the capacity, full/closed responses, bounded drain
and discard-on-close. `LoopChannel` instead gives its Julia caller blocking
back pressure. These are in-process task bridges. For the current calibration
case, the graph host is the natural home for a Julia adapter and the RTC
owns the `StopGraph` command, acknowledgement and cleanup. A shared native
mailbox would be warranted if another language needs the same semantics.
Preserve the existing command endpoint's shutdown and exception behavior
through any move. Its current public location is recorded in the
[calibration worker decision](../20261104-calibration-worker/REVIEW.md). The related `iterate!` simply bounds calls to
`pw_loop_iterate(loop, 0)` on the creating thread. Its argument bounds native
iterations. One iteration may dispatch several callbacks. That belongs in the binding.
[Julia command endpoint](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/command_endpoint.jl#L40)
· [Julia LoopChannel](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/loop_channel.jl)
· [PipeWire loop API](https://docs.pipewire.org/group__pw__loop.html)
· [Calibration worker](../../../ext/calibration_worker.jl)

## Other public interfaces

| Interface | Observed behavior and ownership |
| --- | --- |
| `NdArrayFilter` | Native code already owns negotiation, loan/recycle, latest or FIFO scheduling, independent inputs, and parameter workers. Julia converts port declarations, roots callbacks, contains exceptions, and lends typed array views. Keep the managed binding and the native execution path. FGN and FilterGraphs own scientific graph execution. [Julia adapter](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/ndarray_filter.jl#L573) · [Native filter](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/pipewire/ndarray-filter.c#L1181) |
| Stream, Filter and buffer memory | Queue, dequeue, trigger and normal mapped-buffer operation use native PipeWire. Explicit `map_data` separately calls Linux `mmap`/`munmap` on an fd-backed plane. `allocate_buffer!` supplies Julia-owned MemPtr storage. Keep Julia storage roots and lease-scoped views. Prefer native negotiated mapping when available. A common explicit fd-mapping API would belong in native PipeWireAO if multiple clients need it. DMA-BUF device synchronization remains a caller/device contract. [Julia mapping](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/stream.jl#L1514) · [Native mapping](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/pipewire/stream.c#L805) |
| Core, proxies, registry and callbacks | `Registry` caches global add/remove events and returns owned, filtered snapshots. `roundtrip` composes `pw_core_sync`, its sequence-matched done event, and loop dispatch. These are client conveniences. The C tooling uses the same roundtrip pattern. Keep C-string and object lifetimes, GC roots, exception containment and Julia callback restrictions in the binding. Keep readiness, exact serial/PID/admission checks and bounded operation deadlines in RTC. [Julia core](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.9.3/src/core.jl#L983) · [Native client example](https://github.com/DarrylGamroth/PipeWireAO/blob/v4.0.4/src/tools/pw-container.c#L97) · [RTC deadline-aware barrier](../../../src/media_session/transport.jl) |

## Verification and migration

The [comparison script](compare.jl) reproduces the NDArray and metadata
differences and looks up representative symbols in both installed libraries.
Run the comparison script with the RTC Manifest from commit `5242c5a`.
It asserts the historical 0.9.3 behavior. The package's selected tests also passed. Seven selectors covering
the tracker, hook removal, run control, Props, metadata, filter and exchange
reported 977 assertions in named testsets. The command endpoint, registry
tracking and private-core exchange selectors reported 210. The private cores
used the matching JLL prefix. These checks characterize behavior and
interoperability on a CPU host. Latency and hardware qualification were outside the review.

```sh
julia --startup-file=no --project=. docs/reviews/20261121-pipewireao-julia/compare.jl
julia --startup-file=no --threads=2 --project=. -e '
using PipeWireAO
ENV["PIPEWIREAO_EXCHANGE_TEST_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
for name in ARGS
    include(joinpath(pkgdir(PipeWireAO), "test", name * ".jl"))
end' current_info hook_removal run_control props_buffer metadata_records ndarray_filter ndarray_exchange command_endpoint registry_tracking ndarray_exchange_private_core
```

For the tracker, verify sparse updates, retained snapshots and
raw bad-then-good event ordering before changing the RTC consumer. Relocating
the exchange or task bridges affects exported APIs and requires a caller
migration.

## Format and metadata fix verification

**PWJL-01 and PWJL-02 are fixed in the PipeWireAO.jl 0.9.4 candidate.**
The binding calls `spa_format_ndarray_ext_parse` for the representation and
`spa_format_ndarray_parse_string` for the optional schema. It checks the
POD and selected child extents before passing pointers to SPA and copies the
schema into a Julia string. Reading a schema from an offer works before its
element type is fixed. Tuple and vector requirements now reach
`spa_meta_records_validate` as a complete list. The warmed tuple and vector
validation paths measured zero Julia heap bytes in the allocation tests.

MediaSession still rejects oversize PODs, excess or duplicate properties,
invalid schema text and mismatches with the declared element type, shape,
layout, rate or schema. ParameterSource still requires all top-level Choices
to be fixed and accepts a negotiated rate when its declaration omits one.
Both supply the declared rank before the binding constructs a Julia shape tuple.

The initial RTC check used the tree from PipeWireAO.jl commit `63fd75b`. A
temporary local registry supplied the unreleased 0.9.4 entry for the install
check. Pkg also brought the existing Hsm 0.3.3 and RTC 0.7.27 declarations
into sync with the Manifest. Fresh external installations need the binding
release in their registry.

| Software verification on Julia 1.13.4, x86-64 Linux | Result |
| --- | --- |
| Released binding 0.9.3, JLL 4.0.4+0 | The same fixed offer passed in C and failed in Julia. Duplicate requirements failed as a tuple and passed as a vector. |
| Candidate binding, JLL 4.0.4+0 | Full suite passed 2,369 assertions. The private-core exchange passed 136 assertions and the private-core metadata callback passed 18. |
| Candidate binding, JLL 4.0.6+0 | SPA and metadata selectors passed 636 assertions. |
| RTC consumer, JLL 4.0.4+0 | The object, sparse parameter preload and MediaSession private-core selectors passed 210 assertions, including 31 direct format and admission checks. |
| RTC core suite with the registry-installed candidate | Stopped at calibration materialization with 110 passes and 12 failures. All twelve matched the baseline test locations and expressions for invalid nested hashes and paths. [Earlier baseline](../../validation/session-orchestration-20261121/README.md) |

Run the focused RTC checks from the package directory with its resolved
binding and the matching JLL prefix.

```sh
julia --startup-file=no --project=. -e '
using PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
for file in ARGS
    Base.include(Module(gensym(:AdmissionTests)), abspath(file))
end' test/media_session_objects.jl test/test_parameter_fits.jl test/media_session_private_core.jl
```

## RTC integration of PipeWireAO.jl 0.9.4

The RTC Manifest and the local registry select the same tree,
`5b2b8556a2ec065ec228a645ee54933bbedf4bf3`, from PipeWireAO.jl
commit `728d065`. The integration checks verified the installed source tree
and used its PipeWireAO_jll 4.0.4+0 prefix on Julia 1.13.4. The four
allocating run/reset constructors use native builders and own their POD
storage. Listener close calls native `spa_hook_remove` once for a linked hook.

The three RTC selectors above passed all 210 assertions, including 31 direct
format and admission checks. They also exercised native discovery, exact Link
ownership, withdrawal and close on private cores. The instrument profile
selector passed 26 assertions across CAL2, SPIDERS and GPI2 with instrument
declarations at `1b1b302`. [Profile selector](../../validation/session-orchestration-20261121/profiles.jl)

The full RTC suite reported 10,554 passes and 15 failures. Twelve failures
concerned nested calibration artifact hashes and paths. Three concerned
external optical references and declarations. Rerunning both affected files
on pre-merge RTC `987296b` with PipeWireAO.jl 0.9.3 and the same native JLL
reproduced all 15 at the same assertions with the same outcomes. The
baseline selectors reported 289 passes and 15 failures.

To run every core selector even when an earlier testset fails, use an outer
testset from the RTC package directory.

```sh
julia --startup-file=no --project=. -e '
using Test, PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
@testset "RTC core" begin
    include("test/runtests.jl")
end'
```
