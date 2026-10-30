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
