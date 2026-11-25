# GPI2 FIFO host profile

Instrument commit `9774d92` adds
`gpi2/profiles/simulator/host.cpu-fifo.example.yaml`. The CPU simulator
uses 10 Hz host pacing. The generated Julia graph client configures
`libpipewire-module-rt` with priority 15 and disables RTKit and portal
fallback. PipeWire runs the FilterGraphPipeWire callback on the named
client data thread. The process leaders, private daemon and simulator
use ordinary scheduling.

The profile exported, installed and started on a private PipeWire core
using Julia 1.13.3, PipeWireAORTC 0.7.9, FilterGraphPipeWire 0.5.5 and
PipeWireAO SDK 4.0.2. The exported and installed Manifest matched
(`d8d5f34184f6f67df9a9a3c5a59b130daffc71e98f03f1645fc9e152d62e08ef`).
Startup reached Ready in 481.22 s of the 900 s budget. After native
Start and a fresh Running Status, the verifier used the RTC placement
check to read the kernel scheduler and exact affinity for each named
thread in the profile.

| Owner | PipeWire thread | Policy | RT priority | Affinity |
| --- | --- | --- | ---: | --- |
| Julia controller | `julia-data-loop` | SCHED_FIFO | 15 | 8 |
| Private core | `rtc-data-loop` | SCHED_OTHER | 0 | 8 |
| Private core | `telemetry-loop` | SCHED_OTHER | 0 | 10 |
| Simulator | `AOS-HIL-images` | SCHED_OTHER | 0 | 13 |
| Simulator | `AOS-arrays` | SCHED_OTHER | 0 | 15 |

The controller, core, simulator and session leaders all used
SCHED_OTHER on their configured housekeeping CPUs. Systemd recorded
an accepted native Quit. The private socket and unit files were
removed, and all owners exited without SIGKILL.

A first admission reached Ready and independently confirmed the
controller thread with `chrt` and `taskset`. The post-admission
verifier looked up the session PID in the owner map and failed. The
repeat used the PID from the session handle and completed all checks
against the same installed profile.

This is a scheduling and lifecycle check on the CPU simulator.
The earlier [2 kHz GPI2 test](../gpi2-connected-20261109/README.md#fifo-scheduling)
used a separate replay workload.
