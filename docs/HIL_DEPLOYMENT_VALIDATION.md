# Installed AOS/HIL deployment

This document records implementation and qualification evidence for
RTC-DEV-024 through RTC-DEV-026. The operating requirements remain in
[operations.md](operations.md). The independent findings and their dispositions
are in [HIL_DEPLOYMENT_REVIEW.md](HIL_DEPLOYMENT_REVIEW.md).

## Composition

An installed complete-frame Classic or Copper profile retains its measured
calibration, reconstructor, projections, extrapolation, controller, command
limits and clipping feedback. The HIL exporter substitutes an AOS detector
source and simulated command sink for the recorded source and discard sink.
FGN and JFG remain the scientific graph owners. The supervisor coordinates
admission and controls; it does not schedule scientific processing.

The simulator uses the public AdaptiveOpticsSimPipeWireHIL boundary. Detector
products are encoded as UInt16 ROW_MAJOR ADC values. Ordered HSDM277 demands
use Float32 micrometre OPD on the transport and multiply by 10⁻⁶ for the plant's
metre OPD command. There is no extra factor of two. Host staging and encoding
are explicit copies. Optical computation and accelerator synchronization run
outside PipeWire callbacks.

## Export and install

Use committed science sources and an installed recorded **complete-frame**
profile as the base. The exporter snapshots packages and resolves portable
Julia environments. Both external Julia owners use the same snapshotted
PipeWireAO package. The ThreadLoop GC correction requires PipeWireAO 0.6.12;
the selected native prefix must also include the reliable asynchronous buffer
reserve correction described below.

```sh
python3 deployment/export_hil.py \
  --base-package "$HOME/.config/pipewireao-rtc/revolt-copper-fgn-frame" \
  --output /absolute/export/revolt-copper-fgn-hil-cuda \
  --aos-root /absolute/AdaptiveOpticsSim.jl \
  --plant-root /absolute/REVOLTCopperSim.jl \
  --adapter-root /absolute/AdaptiveOpticsSimPipeWireHIL.jl \
  --pipewireao-jl-root /absolute/PipeWireAO.jl \
  --backend cuda --rate-hz 10 --frames 16

python3 deployment/deploy.py install \
  --package /absolute/export/revolt-copper-fgn-hil-cuda \
  --destination "$HOME/.config/pipewireao-rtc/revolt-copper-fgn-hil-cuda"
```

`--backend cpu`, `cuda` or `amdgpu` selects the simulator independently of
FGN/JFG. GPU dependencies are optional to CPU packages. An unavailable selected
device fails preparation without a fallback. Change the base profile and plant
source for Classic or JFG; do not substitute a simplified science graph.
Export precompiles the selected optional GPU package before the source owner's
bounded readiness wait. AMDGPU profiles set
`HSA_OVERRIDE_CPU_AFFINITY_DEBUG=0` so ROCr helper threads inherit the deployment
mask; its default otherwise permits helpers on all cores. This is a per-owner
setting, not a host policy change. See the
[ROCr environment contract](https://rocm.docs.amd.com/projects/ROCR-Runtime/en/docs-7.1.1/api-reference/environment_variables.html).

The finite batch range is 1–256 frames. The declared rate is 1–500 Hz and must
leave at least the model's exposure duration per period. These CLI bounds are
not throughput claims. Achieved publication cadence and missed wall periods
are reported. An overloaded simulation keeps every model/command sequence and
waits for a future wall deadline rather than producing catch-up bursts.

## Launch and control

```sh
python3 deployment/deploy.py preflight \
  --deployment "$HOME/.config/pipewireao-rtc/revolt-copper-fgn-hil-cuda/deployment.conf"
python3 deployment/deploy.py run \
  --deployment "$HOME/.config/pipewireao-rtc/revolt-copper-fgn-hil-cuda/deployment.conf" \
  --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper"
```

No FITS argument is needed. The source warms and resets before preparation,
connects held, and starts only after placement validation and the RTC's Running
acknowledgement. One frame and its matching command can be outstanding. Pause
waits for adoption before acknowledgement. Stop preserves science and model
state; reset is allowed only with the RTC stopped and advances acquisition
generation. A completed batch remains held and requires reset before restart.

```sh
python3 deployment/deploy.py control --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper" -- status
python3 deployment/deploy.py control --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper" -- session-stop
python3 deployment/deploy.py control --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper" -- reset
python3 deployment/deploy.py control --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper" -- session-start
python3 deployment/deploy.py control --runtime "$XDG_RUNTIME_DIR/rtc-hil-copper" -- quit
```

The installed `systemd/pipewireao-rtc@.service` uses the same launcher and
controls. Install it under the user unit directory as described in
[DEPLOYMENT_VALIDATION.md](DEPLOYMENT_VALIDATION.md). It does not change host
CPU policy. Maintained placement excludes CPU0 and CPU1.

## Focused qualification

```sh
python3 deployment/check_hil.py \
  --deployment "$HOME/.config/pipewireao-rtc/revolt-copper-fgn-hil-cuda/deployment.conf" \
  --runtime "$XDG_RUNTIME_DIR/rtc-hil-check" \
  --output /absolute/new-evidence-directory
```

The check exercises quiet admission, an acknowledged mid-batch pause and
resume, exact finite exchange, invalid requests, reset rejection while Running,
stopped reset, a second exact batch, and graceful owner shutdown. It retains
raw detector/command products with hashes and usable evidence paths. This is
functional qualification, not a latency benchmark.

## Corrected failures and claim limits

- **ThreadLoop GC deadlock:** a foreign callback could request collection while
  the Julia owner blocked on the native loop mutex or callback join. Both
  blocking FFI calls now permit GC. Bounded child-process regressions time out
  before the fix and complete afterward. Full PipeWireAO package tests pass.
- **Reliable asynchronous pool starvation:** two returned command buffers could
  occupy the two asynchronous IO cells, leaving no free producer buffer for the
  publication that would recycle them. Native negotiation now reserves at least
  three buffers for a reliable asynchronous edge. Link allocation already
  reserves asynchronous capacity, so reliable links conservatively receive the
  same minimum even with synchronous IO. Ordinary asynchronous negotiation
  retains two; direct synchronous negotiation retains one. The 256-case actual
  negotiation fixture and five existing return/lifetime tests pass in release
  and debug builds. Multi-peer fan-out capacity is not qualified by this fix.
- **Stopped idle-output removal:** normal JFG teardown removed an unused output
  prefetched while waiting for inputs. The native helper cleared its cache but
  incorrectly raised EPIPE. It now permits only stopped, unprepared output
  removal without OUTPUT_UNAVAILABLE; retained inputs, active processing and
  intentionally retained outputs still fail. The regression fails against the
  original source and passes after correction. Installed Classic JFG then
  completes both batches and exits zero without an owner signal.
- Backend preparation passed for Classic and Copper on CPU, NVIDIA RTX 3080
  using CUDA 6.4.1, and AMD Radeon Graphics gfx1030 using AMDGPU 2.7.3. The
  installed AMDGPU environment resolved 2.8.0 and passed a separate device and
  plant check. Direct GPU preparation is distinct from installed live transport
  qualification.
- The provisional grid-Gaussian HSDM277 plant is not calibrated to the measured
  RTC matrices. An earlier Classic replay matched all 1,982,464 encoded pixels
  exactly, but every returned command was zero. That establishes detector
  replay, not nonzero response, scientific equivalence or closed-loop
  convergence. Nonzero unit/order conversion has separate adapter tests.
- Copper's direct CPU plant replay matched 65,536 encoded detector pixels
  across 16 frames after adoption of their recorded nonzero commands. All 4,432
  command components were nonzero, none reached the limiter, and maximum
  magnitude was 0.26691416 µm OPD. This establishes model/recorded-command
  causality; it is not an independent wire trace or a calibration/convergence
  qualification.

## Installed GPU observations

Each run completed 16 exchanges, stopped reset, and another 16 exchanges,
with finite nonzero Copper commands, no limiter hits and graceful owner exits.
The table uses the second batch. The first batch contains an intentional pause
and cold costs and is not a cadence benchmark.

| Simulator / RTC | Requested cadence | Observed second batch | Missed wall periods |
| --- | ---: | ---: | ---: |
| CUDA 6.4.1 / Copper FGN | 10 Hz | 9.99993 Hz | 0 |
| AMDGPU 2.8.0 / Copper FGN | 10 Hz | 10.03763 Hz | 0 |
| CUDA 6.4.1 / Copper FGN | 100 Hz | 44.63698 Hz | 19 |

The last run preserves its 10 ms model step and all command exchanges but does
**not** meet 100 Hz wall cadence. Its cause has not been profiled or established.
These short functional checks do not qualify maximum throughput or hard real
time. Installed Classic GPU transport and JFG GPU transport are not covered by
these runs; both plants have direct device-preparation evidence.

## Installed CPU and user-service observations

All four installed CPU profiles passed quiet admission, mid-batch pause and
resume, 16 exchanges, stopped reset, a second 16 exchanges, rejected-request
survival and graceful shutdown. Every science/simulator/RTC owner exited zero;
only the owned private core received TERM. Actual placement stayed within its
declared masks and excluded CPUs 0/1. All 1,140 declared package artifacts were
hashed, and original science/calibration bytes and provenance were preserved.
The packages run from installed relative environments after export relocation.

| CPU simulator / RTC | Second-batch cadence at requested 10 Hz | Command observation |
| --- | ---: | --- |
| Classic / FGN | 10.00583 Hz | all zero |
| Classic / JFG | 10.01043 Hz | all zero |
| Copper / FGN | 3.33307 Hz | 4,432 nonzero components, no clipping |
| Copper / JFG | 3.26305 Hz | 4,432 nonzero components, no clipping |

Copper CPU preserves all exchanges and 100 ms model steps but does not meet
10 Hz wall cadence in these runs. These are short functional observations,
not capacity estimates.

Copper FGN and JFG also passed the generated systemd user units: READY
notification, 16 + reset + 16 exchanges, acknowledged quit, inactive/success
and exit zero. Fresh restart followed by deliberately terminating the required
simulator produced failed exit one with dependency diagnostics; all recorded
owned processes and supervisors were gone. The fault journals retain Julia
finalizer context warnings during forced termination. Nominal shutdown passed.
Both test units are left inactive and disabled. No host policy was changed.

The durable [evidence summary](HIL_DEPLOYMENT_EVIDENCE.json) records exact hashes,
versions, placements and retained artifact paths. GPU transport runs used the
first native correction (`5017892d4`); the four CPU and user-unit runs used the
subsequent stopped-output correction (`7e17c0fa2`). Both had tracing disabled.
The selected `/opt/pipewireao` prefix contains both corrections. A fresh JLL
artifact containing those native corrections has not been released by this
increment; installed profiles explicitly select the prefix.

## Numerical observations still under investigation

Copper JFG also matches all 65,536 pixels in direct replay with its own recorded
commands. The final Copper FGN and JFG detector products are byte-identical;
427 of 4,432 command components differ by at most four Float32 ULPs
(2.842170943 × 10⁻⁸ µm OPD). No component clips. This is an observed comparison,
not a new universal algorithm tolerance.

Classic JFG differs from the direct plant oracle in one of 1,982,464 encoded
samples: sequence 13, row 209, column 144 is recorded as 216 and replayed as
217. Both retained batches repeat it, and replay on CPUs 6 and 12 produces the
same result. The exact replay test remains failed. Direct detector-product
inspection sees 217.1523895 before UInt16 conversion, so a final half-code
rounding boundary has not explained the observation. A separate diagnostic clone then completed 16 + reset + 16 exchanges, with
live pre-conversion value 217.1523895, detector UInt16 217, graph Float32 217
and recorded UInt16 217. Its entire detector trace matched direct replay.
Original science files were unchanged; diagnostics used preallocated scalar
storage outside callbacks. That run did not reproduce the earlier 216 and
therefore does not localize the original difference. Different observed FFT
plan descriptions alone do not establish its cause. No algorithm or acceptance
tolerance was changed. All Classic returned commands remain zero.

Functional deployment success does not establish bitwise plant or graph
equivalence. RTC-DEV-024 remains partial at its direct-oracle acceptance gate,
and HIL010 remains open. The next discriminating observation is the detector's
pre-conversion value, photon rate, RNG state and FFT plans when the 216 sample
recurs. Existing failed replay and diagnostic artifacts are retained. No
speculative production change is justified by the present evidence.



