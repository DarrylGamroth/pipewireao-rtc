# SPIDERS SCC mode count and damping on CUDA HIL

The [previous held-out comparison](../spiders-wide-bank-20261117/README.md)
changed two controller settings together and retained just six paired exposures
per phase. This comparison crosses 64 and 112 SCC modes with TSVD and legacy
damping, giving four controllers on each of two held-out trajectories.

## Method

The two banks used the same fitted optical prescription, optimized static DM
bias, 12,703-pixel dark-hole mask, reference signal, 5 nm full and 2.5 nm half
pokes, active-to-physical command completion, and control limits. The 112-mode
bank adds 24 Fourier frequency pairs to the 64-mode bank. Both fits include
two nuisance tip/tilt columns, and both SCC reconstructors zero their output
rows for those columns. LLOWFS stays open throughout. The SCC integrator uses
gain −0.05 and pole 1.

The [64-mode recipe](../spiders-closed-loop-20261117/optical-dark-hole.yaml)
and [112-mode recipe](../spiders-wide-bank-20261117/optical-wide.yaml) select
the same [DM bias](../spiders-closed-loop-20261117/system-flat.fits).
Within each bank both inverses come from the same full-poke interaction
matrix. TSVD uses a relative cutoff of 10⁻⁴ and retains the full measured
rank in both banks. The legacy rule applies
`σ / (σ² + λ²)` at every singular value, with `λ = σ[min(rank, 100)]` for
these full-rank matrices. The two nuisance columns enter the fit and the
damping scale. The 64-mode fit gives λ = 172467.81 at index 66. The 112-mode
fit gives λ = 253461.4 at index 100. This measures the effect of the same
damping rule at each width, with the scale defined by that width's spectrum.
The 112-mode fit reproduces the 64-mode bank’s pupil modes, command
projection, and full-poke interaction over the common columns exactly. The
physical mirror completion is identical. [Array comparison](bank-overlap.txt)

The [source generator](../spiders-wide-bank-20261117/trajectory.jl) sets the
facility residual RNG seed to 17 or 73 and the model period to 10 ms. The
simulator advances on its private PipeWire core with detector noise disabled.
The observer reads the phase, acquisition generation, sequence, model time,
and mean electrons in the fixed dark-hole mask directly from the SCC camera.
It also checks physical DM demand and native closure state. Each session runs
a biased-open epoch, issues a native Restart to reset the trajectory, and
closes SCC for the second epoch. The comparison pairs samples by phase,
sequence, and timestamp across every arm and both epochs for each seed.

Each epoch targets 4,096 exposures. The analysis discards the first 2,048
and pools the next four 512-exposure blocks to estimate the late-window
contrast. The burn-in covers roughly 4.5 time constants for the weakest
damped 112-mode direction in the linearized fit, assuming one integrator
update per F/U pair. The block results check whether contrast kept changing
through the late window. At fixed exposure and modeled flux, the ratio of
closed to biased-open mean intensity measures relative contrast.

## Results

All eight runs reached Running and acknowledged SCC Close with matching active
and requested generations. Each simulator PID had a CUDA context on the RTX 3080.
Every run acknowledged native Quit, exited its owners and removed its private
PipeWire socket. Open-loop DM demand matched the fixed bias during observation.
The largest observed closed-loop shift from the bias was 0.003961 native units.
[Run receipts](runs.tsv)

The open-loop camera means matched bit for bit at each retained sequence on
each seed. The common late windows contain 1,021 and 1,022 unfringed exposures
per epoch for seeds 17 and 73, respectively, out of 1,024 available. The table
reports signed changes relative to biased open loop. Positive values indicate
higher intensity in the dark hole.

| SCC modes | Inverse | Seed 17 unfringed | Seed 73 unfringed |
| ---: | --- | ---: | ---: |
| 64 | TSVD | +0.4213% | +0.4435% |
| 64 | Legacy damping | +0.3803% | +0.4033% |
| 112 | TSVD | +0.8691% | +1.0088% |
| 112 | Legacy damping | +0.8074% | +0.9307% |

At a fixed inverse rule, widening the bank raised late unfringed intensity
by another 0.427–0.565 percentage points. At a fixed width, legacy damping
lowered it by 0.040–0.078 points. Each of the 32 late blocks had higher
unfringed intensity with SCC closed. The sign persists through the final
block in both trajectories. Fringed intensity was more seed-dependent.
[Matched means, blocks, and factorial effects](comparison.txt)

The earlier 0.59% decrease was measured over 20 exposures on a different
trajectory. These longer runs show a small steady-window penalty at the
tested gain and bias. SCC tracks the chopped reference around that bias.
The reported outcome is the mean unfringed intensity in the dark-hole mask.
The experiment does not measure the per-pixel chopped error against its
control reference.

## Contrast normalization

The fitted sky model records an unocculted star peak of
0.00228467846854 in its optical intensity units. The current SCC camera
uses 10⁶ photons/s per unit intensity, quantum efficiency 0.8 and a 10 ms
exposure. These convert the model peak to 18.27743 electrons per pixel
per exposure. Dividing the observed mean electrons by that peak gives
the simulated dimensionless mean contrast. Both biased-open means were
1.095–1.097 × 10⁻⁵. The eight closed-loop means were 1.100–1.106 × 10⁻⁵,
well below 10⁻⁴ for this fitted, noise-free simulation.
[Reference inputs](photometry.toml)

## Environment

The fitted-dual controller remained on the CPU. The standalone HIL processes
used the CUDA backend on an NVIDIA GeForce RTX 3080 with driver 615.71.10.
[Host overrides](host.yaml) select both the simulator backend and the runtime
CUDA dependency. The seed pipelines could overlap on the host, but each run
had its own PipeWire core, session, simulator and controller. The experiment
compares model time and does not measure real-time cadence or deadlines.
Initial launches exposed a missing CUDA runtime-dependency declaration.
Later attempts hit temporary-storage limits. The runs reported here used
the corrected declaration and completed with their full selected windows.
[Runtime input hashes](runtime-inputs.sha256)

The input instrument revision was `58ecd8ac842a789c8df06586a2875273b0b80042`.
All runs used Julia 1.13.3, RTC 0.7.23 with recovery patch `7222557`,
PipeWireAO 0.9.3 with JLL 4.0.4+0, HIL 0.5.9, AOS 0.3.26,
AdaptiveOpticsCalibration 0.17.4, Proper 0.4.2, FilterGraphs 0.10.3,
FilterGraphPipeWire 0.5.6, FilterGraphAlgorithms 0.12.5,
CUDA 6.5.1 and KernelAbstractions 0.10.7.

## Recalculate

Run `julia --startup-file=no compare.jl` from this directory to recalculate the
paired means, block results, and conditional mode-count and damping effects.
The script reads the compressed native observer traces with `gzip`.
