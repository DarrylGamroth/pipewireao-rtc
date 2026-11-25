# RTC 0.7.28 managed simulation and GPI2 controller replay

On `rtc-devel` on 2026-11-22 Pacific time, all four sealed CPU applications reached Ready, accepted native Start, produced the observations below, accepted native Stop back to Ready, and acknowledged Quit. Independent Status reads verified the same session and required owner processes across Start and Stop. Each private socket disappeared and all recorded process incarnations exited after Quit. [Managed receipts](managed.json)

| Sealed CPU profile | Start of service to Ready | Data delivered at the observation queues |
| --- | ---: | --- |
| GPI2 | 287.66 s | UInt16 detector frames of 242 × 240 pixels and finite Float32 woofer, tweeter and tip/tilt vectors of lengths 97, 2304 and 2. All four streams delivered Header sequences 1–9. The Running check matched acquisition identities 3, 4 and 5 across all four streams. |
| CAL2 | 313.65 s | Thirty 2 ms synthetic pupils produced 30 LLOWFS exposures and 30 finite offsets. Six 10 ms SCC exposures produced five finite offsets starting at sequence 2. The first fringed exposure carried a high trigger and the following unfringed exposure carried a low trigger. Each offset contained 2304 values. |
| SPIDERS fitted single | 32.58 s | Five finite 468-element DM demands, sequences 2–6. |
| SPIDERS fitted dual | 35.47 s | Both the 468-element DM demand and the simulator-applied command advanced from sequence 1 through 5. The applied observation supplied its reference timestamp. |

The GPI2 correction was closed and its three command streams carried nonzero values. CAL2 and both SPIDERS profiles retained their declared open correction settings. Their observed command vectors were finite and the last sampled vectors were zero. [Live control settings and payloads](managed.json)

After each Stop the probe continued driving its observer for at least two seconds and saw no further sequence advances during the recorded quiet interval. It attached to capacity-one copy/drop-oldest telemetry queues. The daemon journals included telemetry graph xruns during these runs. The scope is functional delivery, acquisition identity and lifecycle on CPU simulators. The timing measurement uses the separate captured workload described below.

## Environment and reproduction

The instrument export source was `fae158d487311ce104d1f17420aa53d17689cee3`. GPI2 used Julia 1.13.4. CAL2 and SPIDERS used Julia 1.13.3. All used registered PipeWireAORTC 0.7.28, PipeWireAO.jl 0.9.6 and the AVX2 PipeWireAO_jll 4.0.8+0 artifact `77da251765f3124df77322c562e67a7c7742ab1d`. The installer verified each saved export against its own Git commit. Its installed Project, Manifest and deployment files matched the sealed bytes. The per-application hashes and unit identities are in the [receipts](managed.json).

Two initial starts failed before admission. GPI2 loaded an incompatible Julia package cache and failed while compiling the CPU optical mask. Selecting the exact native cache builds required by the installed optical image allowed the same sealed application and Julia arguments to pass. The dual-SPIDERS simulator lacked the HIL synchronous command receiver in the depot used at runtime. Running `Pkg.build("AdaptiveOpticsSimPipeWireHIL")` for its registered version built the receiver against the sealed JLL. The retry and the fitted-single run used that build. [GPI2 cache diagnosis and reproduction](gpi2-cache.md)

Install each export with its matching Julia executable and native prefix, then start a fresh installed service instance on a private core. Read the absolute socket from its launch ledger. Run the [flow probe](../../../test/integration/README.md#sealed-simulation-data-flow) and the [control driver](controls.jl) concurrently against that instance. Give the driver the unit name, its systemd runtime directory, the probe's handshake directory and a separate output directory. For CAL2 this run used `RTC_FLOW_TIMEOUT=1400` and `RTC_FLOW_RUNNING_TIMEOUT=1100` seconds to allow the calibrated CPU optics to finish. The reported service-to-Ready times exclude installation and the subsequent client checks. Stop the service after the probe exits and verify the terminal ledger's native Quit acknowledgement, successful unit exit and socket removal.

## GPI2 captured CUDA replay

Each 60-second FIFO trial ran in fresh processes on the RTX 3080. The source replayed 1,062 retained detector frames at 2 kHz through the commands-only CUDA graph. The deadline starts at the scheduled release and ends when the native client has received woofer, tweeter and tip/tilt for the same frame. Each trial excluded one priming frame and 8,000 warmup slots. Percentiles use nearest rank over completed measured slots. Misses include rejected offers, incomplete commands and completions later than 500 µs.

| Trial | Offered | p99 | p99.9 | Maximum | Missed 500 µs |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 120,000 | 383.078 µs | 396.732 µs | 475.727 µs | 0 |
| 2 | 120,000 | 410.717 µs | 430.600 µs | 856.069 µs | 4 |

All 240,000 measured offers produced all three commands. Four completed late, three on consecutive releases. The 32-frame CPU/CUDA comparison reproduced the earlier maximum absolute command difference of 2.59 × 10⁻¹² m. The [earlier 120,000-slot FIFO run](../gpi2-connected-20261109/README.md#fifo-scheduling) recorded zero misses and a 435.9 µs maximum. The graph packages, kernel, host driver and workstation load differed between campaigns. This measures the detector release, scheduling, transport and CUDA controller together. The CPU optical simulators, MediaSession and physical devices are outside this timing boundary. [Reproduction and raw timing evidence](replay.md)
