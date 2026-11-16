# RTC 0.7.20 and HIL 0.5.8 release candidate

The candidate combines RTC `44d2f2a` and HIL `1c10499` with registered
AdaptiveOpticsSim 0.3.25, FilterGraphAlgorithms 0.12.5, FilterGraphs 0.10.3,
FilterGraphPipeWire 0.5.6, PipeWireAO 0.9.2, and PipeWireAO_jll 4.0.2.
The candidate environment used local sources for RTC and HIL. CUDA 6.5.1,
AMDGPU 2.11.0 and KernelAbstractions 0.10.7 resolved together. The cohort
loaded and ran a KernelAbstractions kernel on each GPU. The integrated Radeon
used the workstation's existing `HSA_OVERRIDE_GFX_VERSION=10.3.0` override.

The RTC core suite passed. The standalone simulator export selector passed
all 18 checks. The HIL package test requires building its synchronous command
receiver first with `Pkg.build("AdaptiveOpticsSimPipeWireHIL")`. After building,
the main HIL testset passed 1,534 checks, the model-time test passed 22, and
the private-core node publication test passed 374.

The remaining HIL receiver checks were intermittent. One full candidate run
passed the 36 receiver checks and then measured 272 bytes in the zero-allocation
camera staging test. A focused staging run passed without changes. A separate
default-thread full run measured 992 bytes in the receiver polling allocation
test. The cause of the allocation measurements is unconfirmed.

The candidate also crashed in the native `do_trigger_driver` callback in
the synchronous optical command receiver test. The full registered HIL 0.5.7
baseline suite passed once. The same focused receiver test against HIL 0.5.7
then passed twice and exited with SIGSEGV once, with the same native callback
on its stack. Both environments used PipeWireAO_jll 4.0.2, and the receiver
implementation and test are identical in the two HIL source trees. This
establishes that the crash predates the release candidate. The lifetime or
scheduling condition that causes it remains unconfirmed.

Release and registry publication are pending receiver verification. No SPIDERS
timing was collected on this candidate.

## Teardown and allocation fixes

A repeated receiver selector reproduced SIGSEGV with PipeWireAO_jll 4.0.2.
GDB stopped in `do_trigger_driver+0x22` at the call through the node
callbacks. The queued invocation outlived the callback table, which native
node destruction clears. PipeWireAO 4.0.3 drains the stream's data-loop queue
after marking it as disconnecting and before destroying the node. The same
receiver selector passed 12 consecutive runs with the patched library. This
comparison isolated the crash by omitting allocation assertions.

The first packaged-artifact HIL run reached named calibration teardown and
hung with PipeWireAO.jl 0.9.2. GDB showed the closing Julia thread in
`pw_stream_destroy → stream_disconnect → loop_invoke → eventfd read`. The
callback thread had entered Julia inference and was waiting for that caller in
`jl_gc_wait_for_the_world`. PipeWireAO.jl 0.9.3 marks both stream teardown
calls GC-safe. HIL marks its command receiver's native destroy call GC-safe at
its own FFI boundary. PipeWireAO.jl 0.9.3 rejects a loaded 4.0.2 library.

The old allocation assertions counted process-wide Julia heap traffic during
concurrent PipeWire activity. Full sampling reported zero allocations on the
calling Julia task for warmed command polling, stream health polling, idle
triggering and mixed camera staging. The revised HIL tests assert that
per-task budget. The checks cover those operations on the calling task.

The candidate with both teardown fixes passed the full HIL suite, including
3,714 checks and the live receiver and named calibration selectors on
disposable cores. The standalone export selector passed 18 checks, and the
lockstep startup cache selector passed 16. The PipeWireAO.jl suite passed with
a registered 4.0.3+0 artifact, including rejection of a 4.0.2 SDK override.
All five published JLL archives matched the generated download hashes.

| Component | Change |
| --- | --- |
| PipeWireAO 4.0.3 | [Drain the stream loop before disconnect](https://github.com/DarrylGamroth/PipeWireAO/commit/2b40ac4bb) |
| PipeWireAO_jll 4.0.3+0 | [Linux artifacts](https://github.com/DarrylGamroth/PipeWireAO_jll.jl/releases/tag/PipeWireAO-v4.0.3%2B0) |
| PipeWireAO.jl 0.9.3 | [GC-safe stream teardown](https://github.com/DarrylGamroth/PipeWireAO.jl/releases/tag/v0.9.3) |
| AdaptiveOpticsSimPipeWireHIL 0.5.8 | [Task allocation checks, GC-safe receiver retirement and lockstep caching](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/releases/tag/v0.5.8) |
