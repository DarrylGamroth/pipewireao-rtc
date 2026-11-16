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
