# Optical observation clock keyword forwarding — 2026-11-02

RTC source baseline `c5a1b010f3ac2f42616056be269e7ca62547185b`, branch
`codex/rtc39-optical-clock`, clean before this focused repair. This record covers
[RTC issue #39](https://github.com/DarrylGamroth/pipewireao-rtc/issues/39).

## Observed defect and repair

The real optional CPU selector reached `OpticalObservation.source_options` and
failed with `MethodError: no method matching PipeWireImageSourceOptions(::PipeWireAO.AbsoluteClock; ...)`.
The HIL 0.4.0 convenience constructor accepts keyword arguments only. Julia
interprets bare `absolute_clock` in these calls before an explicit semicolon as
a positional argument, despite preceding named arguments.

The repair explicitly passes `absolute_clock=absolute_clock` to all three
constructors: focal image, residual wavefront and wavefront RMS. Optical
calculations, gains, metadata contracts and lifecycle behavior are unchanged.

## Environment and command

Julia 1.13.3; registered AOS 0.3.18, HIL 0.4.0, PipeWireAO 0.8.0 and native
PipeWireAO_jll 3.0.0. The input environment was the generated
`adaptive-optics-simulations/build/metadata-3/revolt-classic-cpu` environment.
Its Project and Manifest were copied to a private test directory, then the
supported `Pkg.develop(path=...)` API selected this RTC worktree only. The source
application environment and generated manifests were not edited by hand.

Private test environment:
`/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env`.
This source override is test-only; it does not establish a deployable registered
application cohort.

Run from this RTC worktree:

```sh
julia --project=/home/dgamroth/.local/state/pipewireao/independent-integration-20261102/rtc39/env test/test_session_configuration_integration.jl
```

## Results and limits

Before the source repair, the maintained selector passed its first JFG boundary
testset (10 assertions) and failed at the actual optical source constructor in
the CPU Shack-Hartmann test. This is a dispatch failure with real optional
packages, independent of a PipeWire core or service.

The same selector is extended to check default and explicitly selected REALTIME
clock preservation across all three source options for both small CPU
Shack-Hartmann and Pyramid graphs. The optional nondefault TAI check uses the
shared constructor with a 37-second TAI−UTC offset; it is skipped with a reason
when that constructor cannot verify the host clock. No shared clock validation
is bypassed.

The first pass-after run passed 43 checks, including all optical product/clock assertions, and
skipped the TAI check because the shared constructor rejected this host's offset.
It then failed the selector's existing assertion that `GPUCompiler` must not be
loaded. A fresh-process load-chain check identifies AOS → KernelAbstractions
0.10.4 → GPUCompiler as the CPU dependency path; neither CUDA nor AMDGPU is
loaded, and the existing CUDA/AMD GPU-runtime library assertion passes. This
failed gate is separate from the repaired constructor dispatch.

The selector assertion now rejects CUDA/AMDGPU modules while allowing the
documented CPU dependency on GPUCompiler; the GPU-runtime library check is
unchanged. With this test-only correction, the complete selector passes **86
assertions**, with **one TAI check skipped** (exit status 0): JFG boundary 10,
CPU observation products/clocks 44, named Pyramid contracts 5, command diagnostics
12 and science imaging 15. `git diff --check` and the changed local evidence
link also pass inspection.

No core, service, device or GPU execution is used. Managed application startup,
TAI qualification, hardware, physical-loop behavior and timing qualification
require separate evidence.

The [upstream 0.4.1 merge revalidation](../analysis-construction-20261102/README.md#upstream-041-merge)
reruns this selector on source RTC 0.4.1 and registered HIL 0.4.1: the same
86 assertions pass and one host-verified TAI check is skipped. The original
0.4.0 cohort receipt above remains separately scoped.
