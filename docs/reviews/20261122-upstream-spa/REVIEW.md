# Upstream PipeWire, AO plugin boundaries and runtime logging

## Upstream integration

The native integration branch `integrate/upstream-20261122` replays the
PipeWireAO 4.0.7 fork at `e717a434d` on PipeWire upstream `master` at
`ae1213417`. The old common ancestor was `d80b80602`. The replay reuses
the reviewed October port and row-return resolutions and incorporates the
later AO first-parent changes. The original fork branch remains available.
[Upstream revision](https://gitlab.freedesktop.org/pipewire/pipewire/-/commit/ae1213417f67065ab3ed991dcaa423efd51259fb)

Upstream's refcounted tee holds a buffer until each reader that received it
releases it. Its bookkeeping is allocated during negotiation. The rebased
fork pins the effective tee mode while Links or negotiated buffers own that
storage. It resolves row transport to the reliable single-slot return path,
preserves the explicit poll lease, and honours a legacy port reliability
setting over an inherited node setting. The native regressions exercise
release, property updates, teardown and renegotiation. Removing a reader
without first quiescing an asynchronous remote consumer is outside these
proofs. Use the existing explicit lease for that ownership contract.

The source SDK is version 4.0.8. Upstream introduced
`pw_thread_loop_set_thread_utils` and `PW_STREAM_FLAG_REPORT_BUFFERED`.
PipeWireAO.jl 0.9.6 at `978f2ea` regenerates its binding and requires
that SDK. A C layout probe, a callable-symbol check, byte-identical binding
regeneration and rejection of the old SDK cover the binding change.
The registered RTC environment still resolves PipeWireAO.jl 0.9.5 and SDK
4.0.7. The 0.9.6/4.0.8 results below use a source installation.

## Where to implement a component

Choose the interface by what the component owns. Choose its hosting process
separately, according to device access, failure isolation and restart needs.

| Responsibility | Interface | Existing example and decision |
| --- | --- | --- |
| Acquire or submit buffers for one device, file or external protocol | SPA Node or Device factory, exported through `spa_handle_factory_enum` | eGrabber exposes camera discovery, device and source factories. ALPAO's sink owns SDK submission and electronics-specific dither. The HEART UDP and ImageStreamIO bridges already present their external protocols as SPA endpoints. Keep hardware and wire details here. |
| Create and manage PipeWire objects that share a lifetime in one Context | PipeWire module, loaded through `pipewire__module_init` | The queue module creates two streams with separate buffer pools and owns the policy when its bounded queue fills. The NDArray filter-chain module exposes one multi-port filter and hosts an FGN graph. Both need access to PipeWire objects. |
| Compute on arrays, parameters or frame metadata within one graph | Transport-neutral Algorithm with an FGN or FilterGraphPipeWire adapter | Native FGN libraries export `spa_filter_graph_ndarray_plugin_get_interface`. The host loads descriptors, prepares the graph and calls it from the filter process callback. Keep scientific operators independently array-testable. ALPAO's vendor-independent command normalization already uses this boundary. |
| Admit instrument owners, create declared Links and handle lifecycle | MediaSession client | The RTC has the instrument declaration and the evidence for admitting a particular owner. Keep exact Link endpoints, incarnation checks and loss handling together there. Use systemd for process lifetime. |
| Serialize a shared format or provide a client-side buffer primitive | SPA utility API or native PipeWireAO client library | The NDArray writer is a shared SPA function. An application that owns a filter can already use the native NDArray filter helper without introducing a factory. |

The RTC's FGN launcher loads the filter-chain module in a **client context**
with `core.daemon=false`. Moving a component into a module neither selects
the daemon as its host nor removes a scheduler handoff by itself. A device
requiring isolation can likewise run its SPA plugin in a separately supervised
host. [FGN host export](../../../src/deployment/session_launch.jl)
· [SPA plugins](https://docs.pipewire.org/page_spa_plugins.html)
· [PipeWire modules](https://docs.pipewire.org/page_modules.html)
· [Graph scheduling](https://docs.pipewire.org/page_scheduling.html)

[Camera factories](https://github.com/DarrylGamroth/pipewireao-spa-plugin-egrabber/blob/d72d94d901b34310c3ce7b3128615e77a3fe3882/spa/plugins/egrabber/plugin.cpp)
· [ALPAO ownership](https://github.com/DarrylGamroth/pipewireao-spa-plugin-alpao/blob/b27f585204db2628fc3c1a9fd05c49a872b8408d/README.md)
· [HEART endpoints](https://github.com/DarrylGamroth/pipewireao-spa-plugin-heart/blob/2544a6c097898d99effe0f83bcf42005f291797e/README.md)
· [ImageStreamIO endpoints](https://github.com/DarrylGamroth/pipewireao-spa-plugin-imagestreamio/blob/3e667a0081df4d28387b722acaad5742f186384e/spa/plugins/imagestreamio/plugin.c)
· [Queue semantics](https://github.com/DarrylGamroth/pipewireao-spa-plugins-core/blob/01df204f30f463308add6a2bc3f7ad649bd66382/docs/queue.md)

## Consequences for the instruments

Keep GPI2's frame graph together through its three command outputs. The CPU
probe measured 3.873 ms p99 in the warmed controller callback and 4.929 ms
p99 from detector publication to the last command receipt against a 500 µs
period. Reading its dense reconstruction matrix once per frame at 2 kHz
requires about 134 GB/s of coefficient traffic. Moving the same operation to
a different plugin interface leaves that demand in place. Compare a different
matrix implementation or accelerator with the same arrivals, output commands,
tail latency and missed deadlines before changing the process boundary.
[CPU trace and GPU measurement scope](../../validation/gpi2-data-thread-20261109/README.md)

CAL2 has two separately controlled optical loops with distinct physical-offset
returns. SPIDERS combines two sensor inputs in a shared DM controller and has
a separately operated SCC difference graph. Preserve those boundaries and
keep optional, fresh-image displays behind their bounded observer handoff.
A passive Link alone gives a slow reader neither storage nor a drop policy.
[Instrument declarations and checks](../../validation/session-orchestration-20261121/README.md)
· [Observer and buffer lifetimes](../20261121-pipewireao-julia/REVIEW.md#pipewire-session-design-for-ao)

The module host and the client NDArray filter both reject empty chunks.
A shared predicate and common wire-behavior tests could remove that small
duplication. Their parameter handoffs differ in retry and failure reporting.
Moving the entire client filter into the module would require changing those
contracts. The larger orchestration saving remains retirement of RTC's
field-by-field info cache once the binding can deliver the raw event and its
merged value together for every admitted object type.

## Logging and the data loop

| Event | Where it is recorded | What the operator learns |
| --- | --- | --- |
| Startup and a completed control request | Startup messages in the service journal and correlated native command completions | Which preparation phase ran and what happened to the specific request. |
| A required owner or Link disappears, even with no command pending | The MediaSession owner logs once after compensation reaches `HeldFault`. Emergency disconnect has its own terminal error. | Session instance, wire lifecycle, original cause, cleanup failure if present, and uncertainty about an interrupted effect. |
| A slow reader exhausts a refcounted output pool | The data loop increments a per-port integer and recycles the producer buffer. Port destruction reports a nonzero aggregate after removal from the data loop. | Total losses over that port's lifetime. This is a teardown diagnostic. A running observer that needs an immediate loss indication can inspect frame sequence gaps. |
| An FGN feedback output is incomplete | The filter-chain callback retains the failure for its existing main-loop event. The main loop writes the error and publishes the filter error. | Feedback-specific cause and native error code. |

The default native log level is WARN. The normal build compiles
`pw_log_trace_fp` out. Ordinary `pw_log_trace` calls still exist on paths
such as filter buffer return. Enabling those topics through `PIPEWIREAO_DEBUG`
or the core's `log.level` setting can format a message on that thread. The
support logger can write synchronously. Even its optional buffered TRACE
path formats the line and signals the consumer. Keep ordinary TRACE out of
deadline measurements unless measuring the cost of that logger.

For frame-level investigation, a build with `PW_ENABLE_DIAGNOSTIC_TRACE`
can record binary fields into bounded, prefaulted storage. Set the relevant
trace directory for the filter, NDArray ingress, port handoff, node readiness
or FGN processing. Records beyond capacity count as omissions, and teardown
writes the CSV. Account for timestamping, memory traffic and omitted samples
when interpreting those captures.
[Worked GPI2 trace](../../validation/gpi2-data-thread-20261109/README.md)

A counting Julia logger accepted debug messages during a 20,000-frame probe
of the warmed correction-supervision observer. Across those callbacks the
measured Julia allocations totalled 0 bytes, with 0 logger decisions and 0
writes. The same logger intercepted a control message before the probe.
This covers the tested four-element Float32 observer on Julia 1.13.4.
Native allocator use, plugin-specific log paths and 500 µs deadline
performance require separate measurements.
[Observer allocation selector](../../../test/test_correction_supervision_observer.jl)

In the native two-buffer regression a reader retains buffer 0 while the
producer offers buffer 1 three times. All three offers recycle without a
WARN. Returning the reader's buffer resumes delivery. Teardown emits one
warning naming the port and reporting three drops. GDB breakpoints on
`malloc`, `calloc`, `realloc`, `aligned_alloc`, `posix_memalign` and `free`
recorded zero calls from first publication through recovery. The same probe
recorded 24 calls to `free` during teardown. This measurement covers the
local synthetic source and reader. The feedback regression supplies a real
FGN with incomplete output and checks that the main-loop event retains
the feedback message and `ENODATA`. Both logging regressions failed on the
preceding implementation.

## Verification

The local native branch ends at `2080cba77` and the local Julia branch
`refactor/upstream-sdk-408-20261122` ends at `978f2ea`. Of the paths
modified since the old common ancestor, 194 were touched only by AO, 186
only by upstream and 33 by both. All 186 upstream-only paths match the upstream tree. The differences on
AO-only paths are the adapted native tests and the feedback error deferral.

The RTC application changes are based on `23f0a04`. Commit `b5e5487` adds
the operator diagnostic. The optional host selector at `0c27f73` explicitly
binds its command endpoint and drives shutdown to the public completion
fence before injecting failure or expiry. Its earlier fixture waited for
an endpoint that MediaSession only binds on demand. Once that wait was
fixed, an old step count injected the failure at control removal. The
observer regression at `7f30ca3` checks logging and allocation together on
both steady and rearm frames.

The candidate tests used Julia 1.13.4 on x86-64, the source-built SDK and
a local JLL shim that resolves the client library, support plugin, daemon,
modules and SPA libraries from that installation. The recorded profile
checks used the GPI2, CAL2 and SPIDERS declarations at `1b1b302`.
Building and registering deployable SDK and wrapper releases is pending.

| Software check | Passing result |
| --- | ---: |
| Native Meson suite on 4.0.8 | 82 tests, zero skips |
| PipeWireAO.jl 0.9.6 with the 4.0.8 SDK | 2,942 assertions plus 174 private-core assertions |
| Full RTC on the registered 0.9.5 / 4.0.7 environment | 10,583 assertions |
| Full RTC on the candidate 0.9.6 / 4.0.8 environment | 10,572 assertions |
| MediaSession private-core and host terminal selectors on the candidate | 78 and 46 assertions |
| GPI2, CAL2 and SPIDERS declaration selector on the candidate | 26 assertions |

The concurrent snapshot test sampled 82 times on the registered environment
and 71 times on the candidate, accounting for the difference in RTC totals.
The wrapper's blocking private-core metadata fixture requires at least two
default Julia threads and an interactive thread. An initial invocation at the
default thread count stopped at its fixture precondition. The complete
wrapper run above used three default threads and one interactive thread.

Run the native suite with Meson tests enabled. Run the wrapper and RTC
suites in their corresponding Julia environments with `PIPEWIREAO_PREFIX`
pointing to the same SDK as the client libraries. From the RTC tree, run
the two host selectors on one default thread and no interactive thread.

```sh
meson test -C "$native_build" --print-errorlogs
julia --startup-file=no --threads=3,1 --project="$wrapper_env" "$wrapper_source/test/runtests.jl"
julia --startup-file=no --threads=3,1 --project="$wrapper_env" "$wrapper_source/test/ndarray_exchange_private_core.jl"
julia --startup-file=no --threads=3,1 --project="$wrapper_env" "$wrapper_source/test/metadata_records_private_core.jl"
julia --startup-file=no --project="$rtc_env" test/runtests.jl
julia --startup-file=no --threads=1,0 --project="$rtc_env" test/media_session_private_core.jl
julia --startup-file=no --threads=1,0 --project="$rtc_env" test/media_session_host.jl
julia --startup-file=no --project="$rtc_env" docs/validation/session-orchestration-20261121/profiles.jl "$instruments"
```
