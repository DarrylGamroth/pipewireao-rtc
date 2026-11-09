# Matched GPI2 timing through PipeWire — 2026-11-09

## Calibration and inputs

The workload is the saved GPI2 high-order loop, replaying the same 1,062
242 × 240 UInt16 detector frames in the same order. The CUDA owner uses the
registered captured Float32 GPI2 command graph and its hash-checked instrument
calibration. The external HEART GPI2 executable uses the translated calibration
and Standard WFS/DM PipeWire SPA bridges on isolated loopback. It receives the
same detector samples in row-major order. The CUDA owner uses column-major
buffers. Replay storage is prepared before either timed run.

Both released implementations use the mean over the four full pupil rectangles
from the previous frame. The mask selects 2,776 samples per pupil for
reconstruction. The mean includes the other pixels in those rectangles.
Switching to a selected-pixel mean would change the calibrated gain with flux
and background. On this corpus the selected-only mean divided by the full
mean ranged from 1.199 to 1.222. A masked-flat experiment produced an exact
startup command and then diverged when the previous-frame mean took effect.
The final replay uses the original bias and flat, original pupil positions,
and the same 1,509 × 11,104 reconstructor. The saved modal filter is identity.
The translation uses the original modal reference, gain, tip/tilt filter,
constraint feedback, system flats, offsets, and amplitude limits. HEART's
matrix files compose the linear VDM completion and projection operations,
including the feedback path. The wire conversion expresses the common command
values in micrometres and restores metres at the PipeWire sink.

The parity gate used 400 consecutive frames at 100 Hz, including priming and
warmup. Each of the 400 returned all three command vectors. Every value was
within the 1 nm absolute gate, with a largest difference of 0.0094 nm.
Both paths had 218 frames with at least one tweeter actuator at its limit.
The woofer and tip/tilt commands stayed within their configured limits.

## Timing contract

The same replay source and command sink logic used an independent absolute
monotonic clock. The measured deadline starts at each scheduled detector
release and ends at the last of the three complete PipeWire command receipts
for that sequence. The detector publication timestamp is recorded separately.
Both runs offer one priming frame, 4,000 warmup frames and 40,000 measured
frames at 500 µs intervals. The source allows two pending frames. All
scheduled offers enter the ledger. A source rejection, incomplete set,
duplicate sequence or final receipt later than 500 µs counts as a missed slot.
Timing quantiles use the first complete set for each delivered sequence.
Duplicates are recorded separately for each command. HEART's wire protocol
carries the frame ID, so the receipt is joined by sequence to the same
monotonic ledger. The capture graph also propagates the source PTS.

The Ryzen 7 6800H workstation ran Linux 6.12.113 with a GeForce RTX 3080
10 GB, NVIDIA driver 615.71.10, and Julia 1.13.3. The two private cores used
the same PipeWireAO_jll 4.0.2+0 artifact. Source CPU 8 and command sink CPU
10 used SCHED_FIFO priority 15 on both paths. The CUDA PipeWire graph ran
with the same policy on CPU 4. HEART WFS input ran on CPU 6, pixel processing
on CPU 4, reconstructor on CPU 2, and command workers on CPU 14. Its SPA
bridge data loop ran on CPU 12. Procfs snapshots identify the actual policies,
priorities and affinities. Control and background threads have their own
policies. The native executable uses the workstation simulation profile with
one control-matrix partition. It was rebuilt with gprof removed from build
flags and file/socket telemetry streams disabled for this replay. The CUDA
owner published the three commands and used no live callback probes.

## Results at 2 kHz

| Controller | Complete sets, first receipt per sequence | Missed 500 µs slots | Release to all commands p50 | p99 | p99.9 | Maximum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Captured Julia CUDA | 40,000 / 40,000 | 53 | 380.447 µs | 428.458 µs | 512.376 µs | 661.164 µs |
| HEART GPI2 CPU | 2,758 / 40,000 | 40,000 | 6.936 ms | 8.501 ms | 11.458 ms | 13.459 ms |

Both runs published all 40,000 detector frames. The publication cadence
error at p99 was 7.8 µs for CUDA and 13.9 µs for HEART. CUDA had 53 late
complete sets and zero missing or duplicate commands. Of the 53 late
slots, 35 took over 500 µs from publication to the last receipt. The worst
release split into 18.402 µs to publication and 642.762 µs from publication
to the last receipt. The uninstrumented timing does not divide that
second interval among the controller, driver and transport.

HEART had 37,242 sequences without a complete command set. Each of its
2,758 complete sets was late. Among those, 2,098 sequences also had
duplicate commands. The namespace reported zero UDP receive-buffer drops
and zero UDP receive errors. An initial 2 kHz attempt stopped on the
first duplicate. The retained timing run records all duplicates and
continues releasing frames. Its latency distribution describes the
subset with complete first command sets. HEART's timings include both
loopback protocol bridges and the single-partition workstation build.

All owned processes exited successfully. HEART acknowledged its SHUTDOWN
command and the CUDA owner exited after the launcher issued its quit request.
The CUDA preflight independently checked its first 400 output triples against the
same calibrated CPU graph within 0.0070 nm. A separate instrument job ran
on the host during this comparison. The CUDA owner warmed up while another
process held a CUDA context, and the replay waited for that context to
exit. The preflight immediately before CUDA replay showed only the measured
graph's compute context. Other CPU activity varied between the trials. The receipts
include host snapshots and the frame-thread policies for each run.

## RTX 3080 target

The earlier 60-second uninstrumented FIFO replay completed all 120,000
measured slots. Its release-to-command latency was 377.834 µs at p99 and
435.904 µs at maximum. The 40,000-slot traced run reached 505.661 µs and missed
one slot. These are finite-window measurements of a simulated high-order
command path with a complete detector image at release. [Connected replay record](../gpi2-connected-20261109/README.md)

The RTX 3080 is a candidate for target-host qualification. The measured
software boundary is narrower than the physical loop. Instrument selection
needs the timing budget from the qualified detector event to mirror and stage
latch, under real readout and full concurrent workload. Test thermal soak,
PCIe and interrupt placement, software telemetry, restart and driver/GPU
fault behavior on the target host. The tested board reports a 320 W power
limit. The instrument's readout choice and the CAL2 sensors are relevant to
the deployment workload. [GPI2 detector readout study](https://arxiv.org/abs/2410.01960)
[CAL2 integration design](https://repository.kaust.edu.sa/bitstreams/9fffe54c-decb-457f-81e0-272cfc1cdc1a/download)

## Evidence

The [archive](evidence.tar.gz) retains the ledgers and command parity vectors,
calibration file hashes, build recipe and flag changes, PipeWire configurations,
and timing analysis. The large detector corpus and generated FITS files are
identified by SHA-256 and can be regenerated or reused from the instrument
calibration and prior replay corpus. The [archive checksum](evidence.tar.gz.sha256)
and internal `SHA256SUMS` cover the retained files. The external sources were
the GPI2 application `a59a403`, HEART `50de9affa`, and DAO `65f05a5`.
The build uses the pinned WFS busy-poll compatibility shim to disable the
invalid negative timeout when `busy_read` is absent in the private network
namespace. The comparison runs the external executable with hardware interfaces
disabled. It leaves physical calibration and operation to their own validation.

Extract the archive in a fresh directory and run:

```sh
sha256sum -c SHA256SUMS
python3 reproduce/verify-parity.py parity-receipt oracle
python3 reproduce/analyze-pair.py heart-fixed-2khz 2000 4000 40000
python3 reproduce/analyze-pair.py cuda-2khz-rt 2000 4000 40000
```

The launch scripts record the local SDK, source and corpus layout used for
this run. The CUDA package project and manifest identify the registered cohort.
The prerequisite [connected run](../gpi2-connected-20261109/README.md) retains
the detector source recipe and input corpus reference.
