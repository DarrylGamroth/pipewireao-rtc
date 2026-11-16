# RTC 0.7.20 and HIL 0.5.8 verification

## Initial candidate

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

Release and registry publication were held pending receiver verification. No SPIDERS
timing was collected on the initial candidate.

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

## Registered verification

The RTC core suite passed against registered PipeWireAO.jl 0.9.3 and
PipeWireAO_jll 4.0.3+0. The RTC source release includes that development
Manifest. The registry also published 4.0.4+0, which contains the stream fix
and changes the progressive ndarray filter-chain validator. The final
cohort used 4.0.4+0 from the same registry. [RTC 0.7.20](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.20), [RTC registration](https://github.com/DarrylGamroth/PackageRegistry/commit/1fed0ba), [HIL registration](https://github.com/DarrylGamroth/PackageRegistry/commit/72667bc), [PipeWireAO 4.0.4](https://github.com/DarrylGamroth/PipeWireAO/releases/tag/v4.0.4)

Julia 1.13.3 resolved the cohort in a new project using General and
DarrylGamrothRegistry at `3f2d0d0`. The writable depot reused package,
artifact and precompile caches. The project had no source or artifact
overrides. The resolved RTC, HIL and PipeWireAO.jl trees matched their
release tags. Each GPU executed a KernelAbstractions kernel with scalar
indexing disabled. The integrated Radeon used
`HSA_OVERRIDE_GFX_VERSION=10.3.0`.

| Package | Version | Git tree |
| --- | --- | --- |
| AMDGPU | 2.11.0 | `339be76666103bf8a2c7b2dd638a80336e9b1fda` |
| AdaptiveOpticsCalibration | 0.17.4 | `3091300ace8597034aab04f9bb9e2063079a5d0a` |
| AdaptiveOpticsSim | 0.3.25 | `c70375cef34067b30e8710bca1ab3ee15bccedb7` |
| AdaptiveOpticsSimPipeWireHIL | 0.5.8 | `14915e51f11fdf1b07bb8e8688d515d2085e52b0` |
| CUDA | 6.5.1 | `c82345f5d7e0d902793b4ad5ddf61c2a8b6aac75` |
| FilterGraphAlgorithms | 0.12.5 | `9cfb5cda70fe7ccfe8c0632ce00cdc475ca256dd` |
| FilterGraphPipeWire | 0.5.6 | `e623c4a71756cc298d03a116391d5a2d42831ada` |
| FilterGraphs | 0.10.3 | `1e07f87c5ef74a4c747c81415d494aed4647298b` |
| KernelAbstractions | 0.10.7 | `08b081d7d69e3cc989babee2c74c1d16c0f6baa1` |
| PipeWireAO | 0.9.3 | `d7878497e9a7a5d1a141307721a0f39542f5758d` |
| PipeWireAORTC | 0.7.20 | `6ac8e8bc9d2c287f8c176c863390c587d21fe3cd` |
| PipeWireAO_jll | 4.0.4+0 | `d9fe9c1a8b854c019e1f6d3143f0de0ac015cd75` |

The first registry-installed HIL 4.0.3+0 suite timed out waiting for the
second command in the synchronous receiver selector. Sixty isolated runs
of that selector passed on the same package and artifact with the
allocation assertions enabled, 30 with debug logging and 30 without. The
full 4.0.3+0 suite passed on retry. The final full 4.0.4+0 run passed all
3,714 HIL assertions, including the private-core teardown selectors. The
cause of the earlier command delivery timeout remains unconfirmed.
