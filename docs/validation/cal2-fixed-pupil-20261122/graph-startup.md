# Controller graph preparation and service Ready

The RTC publication helper connects to the native control endpoint, then
polls for owner preparation and RTC warmup. Once warmup is acknowledged
it verifies process placement, submits Admit, and checks native Status
before returning Ready to systemd. Its reported warmup interval includes
time waiting for the simulator, graph owners and declared Links. The
per-owner Julia logs separately time graph preparation and graph warmup.
The package image build takes place during installation. Each service run
below starts new processes and opens its own private PipeWire core.
[Publication helper](../../../src/deployment/session_cli.jl) · [Original journal archive](../hil-installed-startup-20261122/startup-experiments.tar.gz)

## Comparison across installed profiles

Times are seconds from systemd service activation unless labeled as
durations. The Julia compile column is time recorded inside the graph
preparation phase. Startup before that phase includes executable launch
and package-image loading. Controller warmup end is the last instrumented
graph warmup completion across the controller owners. Additional actions
such as opening ports, negotiating links and native admission follow it.

| Sealed CPU service and trial | Graph preparation elapsed (Julia compile inside) | Last graph warmup end | Simulator milestone | RTC warmup acknowledged | Ready |
| --- | ---: | ---: | --- | ---: | ---: |
| CAL2, previous ordinary | SCC 0.64 (0.55), LLOWFS 1.99 (1.83) | 47.62 | Optical warmup ended at 341.44 | 351.70 | 354.30 |
| GPI2, generated launcher | 16.48 (10.32) | 45.72 | Simulator connected at 39.49 | 50.93 | 54.04 |
| SPIDERS fitted dual, ordinary | SCC differential 0.05 (0.05), controller 0.74 (0.57) | 24.69 | Optical transport prepared at 42.59 | 111.84 | 118.60 |
| SPIDERS fitted single, generated launcher | 0.54 (0.49) | 10.56 | Optical transport prepared at 28.17 | 32.67 | 34.73 |

The GPI2 startup trial used the sealed CPU profile. The separate 500 µs
CUDA replay measures detector-to-command latency after warmup.
GPI2's 54.04 s result used the candidate RTC launcher that selects
`-O0` for the prepare and publication helpers. On its earlier 219.91 s
activation the controller logged 29.43 s of graph preparation including
12.29 s of Julia compilation. On the ordinary 61.77 s repeat it logged
15.15 s including 8.92 s of compilation. The very different service times
include scheduler contention and waits outside controller preparation.
[Startup helper experiments](../hil-installed-startup-20261122/startup-performance.md)

## Implications for Rust FGN

The local `filtergraph-rs` main at `e757f7b` includes all seven distinct
algorithm labels in the sealed CAL2 graph declarations. They cover pixel
selection, validity, chopped image difference, SCC residual, dense
reconstruction, vector offset and leaky integration. Its production bundle
exports these operations through the native PipeWire ndarray filter-chain
host. Switching the controller provider can remove the Julia controller
processes' package loading and JIT work. The native provider still has to
load the calibration, prepare the graph, create ports and pass admission.
The RTC coordinator, publication helper and AOS optical simulator remain
on their existing paths.

In the previous CAL2 run both Julia graphs had finished warmup nearly
294 s before the simulator finished optical warmup. GPI2's controller
spent substantially longer preparing its graph, closer to its service's
Ready transition. The recorded compiler times and graph warmup completion
times identify the more plausible target for a provider comparison. A
numerical Ready-time benefit for Rust requires a sealed run with equivalent
ports, metadata, calibrated outputs, reset behavior and control admission.

The [per-instrument phase records](previous-instrument-phases.json) retain event times
relative to service activation and the compiler counters reported by each owner.
