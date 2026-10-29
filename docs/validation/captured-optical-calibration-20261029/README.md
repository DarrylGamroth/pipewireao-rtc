# Captured optical calibration source validation — 2026-10-29

Base: merged RTC 0.2.50, `1ef5b1bed647e3b34c20d868eae635f51b11cd6f`.
The dedicated `fix/captured-cuda-optical-calibration-20261029` worktree started
clean. No package metadata, instrument declarations or selected calibrations
changed. RTC retains its existing graph preparation and device contexts; AOS
owns execution and capture. The physical mirror now applies the same RTC
accelerator policy as the optical graphs. Mirror command and pupil uploads and
output readback enter each graph's retained context.

## Environment and selectors

Julia 1.13.3; registered AOS 0.3.16, HIL 0.2.11, Proper 0.4.1, AOC 0.17.3,
CUDA 6.4.2 and KernelAbstractions 0.9.45. A separate validation environment
copied the registered consumer Project/Manifest, then developed only this RTC
worktree. No registered environment was changed. CUDA uses the shared RTX 3080;
these checks measure correctness rather than isolated timing. Scalar indexing
is disabled. No PipeWire core or service is opened.

```sh
PIPEWIREAORTC_TEST_BACKEND=cpu julia --project="$SCIENCE_ENV" test/captured_optical_calibration.jl
PIPEWIREAORTC_TEST_BACKEND=cuda julia --project="$SCIENCE_ENV" test/captured_optical_calibration.jl
julia --project="$SCIENCE_ENV" test/calibration_chopped.jl
julia --project="$SCIENCE_ENV" test/calibration_optical.jl
```

The new selector authors a 4×4 grid-Gaussian mirror in declared physical command
order, 8×8 Proper fringed/unfringed optical trains, and the existing four-node
CPU chopped measurement prefix. Both Float64 and Float32 optical inputs are
explicitly authored. The two-role optical graph uses different uniform amplitude
factors and a short defocused propagation; it exercises calibration mechanics
and does not represent physical SCC mask geometry. It checks capture policy/counts,
changed commands, exact flat return, invalid pupil rejection followed by successful reuse, full/half
two-mode interaction calibration and held-out mixtures. The unchanged upstream
reference target guard still rejects CUDA reference acquisition.

## Evidence

Before the production change, this same real Float64 setup prepared on CPU,
then rejected CUDA at `optical_callbacks` with “optical calibration supports
explicit host or AMDGPU targets”. After the change, mirror, F and U each retain
one captured node on CUDA for both precisions. CPU retains stream execution and
zero captured nodes.

Final standalone runs exit successfully: CPU has 47/47 summarized assertions
plus two import guards; CUDA has 49/49 plus two import guards. Both include
Float64/Float32, rejected-input recovery and exact flat return.

| Optical precision | CUDA/CPU interaction relative error | CUDA full/half derivative error | CUDA worst held-out reconstruction error |
| --- | ---: | ---: | ---: |
| Float64 | 1.90 × 10⁻²⁰ | 0.002911 | 0.003406 |
| Float32 | 0.001026 | 0.002910 | 0.004412 |

Both CPU and CUDA candidates pass the existing 5% derivative/reconstruction
gates. Interaction equivalence uses 0.2% relative tolerance. These are finite
small-model tests, not a CAL2 calibration or a general precision qualification.

An initial raw residual comparison failed for two Float32 nonflat probes.
Diagnostic replay measured residual norms about 4.4 × 10⁻⁶, difference norms
up to 1.36 × 10⁻⁷ and maximum pixel difference 8.95 × 10⁻⁸. The reference F−U
norm was 0.6495: the difference was about 2.1 × 10⁻⁷ of that bright baseline,
while reaching about 3% of the tiny residual. Both flat residuals and return to
flat were exactly zero. The raw Float32 comparison therefore uses an explicit
case-specific rounding allowance of `4eps(Float32) * norm(flat_difference)`
on the image norm, applied once through array `isapprox`, without a per-pixel
allowance or a general optical error-bound claim. Independent interaction,
derivative and held-out gates remain in place. No production tolerance changed.

The existing chopped measurement/publication selector passed 51 assertions.
The canonical standalone optical selector passed 95, including native pupil
orientation, qualified Host expectation, effective upstream settings and
rejected candidates. A combined-module trial hit that selector's existing
`Main.PipeWireAORTC` assumption; its standalone invocation passed.

## Limits

AMDGPU retains the same admitted target and capture policy but was not exercised
here. Full 1024² CAL2 calibration, noisy feedback, external CUDA upstream
reference acquisition, detector/mask fidelity, hardware and deadlines remain
unqualified. The Host expected-reference law and its target restrictions are
unchanged. No sampling, exposure, optical mask, gain or production threshold
changed.
