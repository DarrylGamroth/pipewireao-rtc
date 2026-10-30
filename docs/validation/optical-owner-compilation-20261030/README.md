# Optical owner cold compilation — 2026-10-30

Baseline RTC `86dbc7e`; Julia 1.13.3, CPU, AOS `34bb05c1` and the
SPIDERS source-validation environment. No GPU or hardware qualification.

The failed managed SPIDERS startup reached Connect, then timed out before the
array-owner callback entered. Its termination stack shows LLVM machine-code
compilation at HIL `with_array_streams`' callback invocation, while native callback
threads wait for JIT locks. This establishes compilation during Connect; it does
not establish that compilation is the only remaining startup cost.

The control loop now avoids specializing on cold runtime/transport handles and
precompiles during Preparing, with cancellation checks on both sides. Science
graph types remain specialized. No ports open and no model samples execute during
this precompile; Connect retains its original ticket and deadline.

A fresh no-core probe of the actual SPIDERS model measured 81.4565 s preparation
and 61.9679 s control-loop precompile (100% compilation), returning true with
source graph sequence still zero. The focused selector
`test/external_pupil_owner_preparation.jl` passes 54/54, including no-core
compilation, unchanged exposure state and cancellation. These are source tests;
remaining concrete transport/warmup compilation and warmed-loop dispatch cost
still require the fresh managed-session trial. No live-startup pass is claimed.

## Managed trial r4 — failed

Simulator incarnation `0799a1bf01b7477fa200688270835a81` still expires the native
owner request after the precompile change. The top-level bootstrap error loses
the inner origin. The no-core precompile proves only the entry compilation;
remaining concrete dynamic callees were not qualified. Retained phase timestamps
and the original error backtrace are enabled for the next discriminating trial.
No deadline increase or further production behavior change follows this failure.

## Managed trial r5 — remaining warmup failure

Instrumentation on simulator `731e1c6caf9c400a86353b53438a06fd` measured 59.229 s
control-entry precompile in Preparing. After Connect, the callback entered at
6.401 s and streams were ready at 7.200 s. Numerical warmup began at 7.201 s;
the original caught stack identifies `warmup_clocked_source!` when its check
observes the expired ticket. The precompile change therefore passed the prior
barrier but did not complete startup.

Numerical warmup now runs once during Preparing, with the same unpublished
emitter used by live acquisition. It retains Float32/finite conversion and
sequence/trigger checks. Existing warmup finally blocks reset model clocks,
exposures and detector RNG; owned transport buffers are cleared in a finally
block too. No transport owner is present and publication is disabled. Connect
warms only concrete transport code without staging a synthetic frame.

The no-core selector passes 63/63, including a noisy seeded InGaAs response
whose first frame is identical before/after warmup and after mid-warmup
cancellation. A fresh no-core SPIDERS probe passes: model preparation 82.1845 s,
execution preparation 123.5602 s (41.76% compilation), with phase intervals
74.6930 s for numerical warmup and 33.2471 s for entry precompile. These cold
phase times include compilation and are not warmed throughput measurements.
The probe confirms publication disabled, no transport owner, source graph
sequence zero, reset exposures, zero source command and cleared transport buffers.
A fresh managed-session trial remains pending.
