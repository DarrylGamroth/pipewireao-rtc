# CAL2 camera continuity with the bundled PipeWireAO queue

## Result

CAL2 passed two installed RTC activations and graceful native Quits on one continuously
publishing CPU simulator. The private core, simulator, two controller processes and
permanent camera taps kept their identities through both Quits. The taps recorded LLOWFS
sequences 1–40 and SCC sequences 1–8 without gaps. Each camera retained its acquisition
domain and generation, and its model timestamps advanced throughout. Both short Quit
operations fell between camera exposures and were bracketed by consecutive acquisitions.

| Observation | Initial RTC | Replacement RTC |
| --- | ---: | ---: |
| RTC MainPID | 3328971 | 3337655 |
| Systemd Start request to held Ready | 9.588 s | 5.679 s |
| First usable open-loop LLOWFS exposure | 7 at 30.940 s | 27 at 32.234 s |
| First usable completed open-loop SCC pair | 3 at 286.549 s | 7 at 289.743 s |
| Native Quit including service cleanup | 3.937 s | 5.194 s |
| LLOWFS exposures observed while detached | 16–25 | 36–40 |
| SCC exposures observed while detached | 4–5 | 8 |

The measurement times start at native Start acknowledgement and end when the observer
receives the matched modal residual. They include the wall-time-paced simulator. Both
native Status replies reported held Ready and ten owned Links. Both controllers reported
Open and primed after the measured arrivals, and the observed physical offsets were
zero. The replacement used fresh Link and authority identities and saw later exposure
labels on both cameras.

Each unused image queue held one pending capture buffer at each Quit. Both native
capture pools went from three buffers to zero, pending depth went from one to zero, and
withdrawal returns increased by exactly one per queue per Quit with zero protocol
errors. The native daemon logged capture nodes 55 and 63 returning slot 2 in queue
capture generation 1. In generation 2 the same nodes returned slots 1 and 0
respectively. These queue generations are separate from the cameras’ unchanged
acquisition generations.

The two RTC Quits left no RTC-owned Links. After the final detached exposures the
fixture explicitly stopped the controller graph services and confirmed that the
simulator and core were still live. It then stopped its own source and core services and
verified that all five fixture units had no running process. The result covers
functional software lifecycle on the paced CPU simulator under
[RTC-DEV-021](../../operations.md#rtc-dev-021--admission-and-coherent-lifecycle).
[Summary](summary.json) · [Native and camera receipts](qualification-receipts.tar.gz)

## Tested installation

The application installed RTC Git commit `20f9fe76c47f05be87e47605ce7e816ed1619491`,
tree `64533fc83fca93611bd17bc83ad8587ce6a8e067`, with Julia 1.13.3 and the ordinary
installed package cache. The RTC integration commit
`40bf399c1dce27197b376d444166b4546eb8b48d` differs only in the package's own version
strings in `Project.toml`, `Manifest.toml` and `test/science/Manifest.toml`. The
installed source identifies itself as RTC 0.7.30. The configuration, implementation and
dependency trees match the integration commit.

PipeWireAO.jl 0.9.6 used the published `PipeWireAO_jll 4.0.10+0` tree
`6fd3623d0e1b6630f07c2dd86aa3817033dc3ae1`. The Linux x86-64 AVX2 artifact was
`b5a54eff79257332e4f793664180fd59e277f26d`. The daemon mapped the native library and
`libpipewire-module-queue.so` from that artifact's single module directory. The
simulator mapped the same native library. The application lock contained no standalone
queue package. A separate clean resolution of the final RTC 0.7.31 integration commit
confirmed the same Julia binding, JLL and artifact on the test host. The artifact's
`pwao-spa-inspect` instantiated the bundled `api.pipewireao.discard` factory separately
from the CAL2 topology.

The fixture reused the calibrated CPU export from the [combined CAL2
activation](../rtc-ndarray-integration-20261123/README.md), export commit
`7be13085f25960b58f861e14d49660e7f8a3265e`. The staged lock selected the exact candidate
RTC and native release and preserved the export's science pins, including
AdaptiveOpticsSim 0.3.30, AdaptiveOpticsSimPipeWireHIL 0.5.13 and FilterGraphPipeWire
0.5.11. Installation ran the profile's existing offline graph prequalification before
the private core started. The live RTC activations used simulator exposures and kept
both correction loops open. Both launches used the ordinary installed interpreter and
package cache.

## Observation boundaries

The independent CPU simulator rendered both cameras from a continuously supplied
deterministic pupil. The feeder staged one 2 ms model-time pupil sample every 32 s of
wall time. SCC combined five pupil intervals into each 10 ms camera exposure. Two
permanent taps on the camera outputs recorded exposure identity, model time, duration
and payload validity independently of the RTC. The feeder and both tap Links remained
attached throughout the two RTC activations and both shutdowns.

The fixture prestarted both controller graph services. Each `systemctl start` had to
reach held native Ready with ten active or paused NDArray Links, and each native Start
had to enter Running with correction open. The output observer joined controller data to
the independent tap by camera, acquisition domain, generation, sequence and model time.
It required a finite nonzero modal residual and zero physical offset on each branch, a
completed chopped SCC pair and native confirmation that both controllers were primed
while open.

`systemctl stop` used the installed native Quit path. The stopped ledger had to
acknowledge Quit and report complete cleanup. The active native graph then had to
contain zero RTC-owned Links and preserve the core, simulator, retained graph processes
and permanent source/tap identities. The unused copy-mode image queues were sampled
before and after each Quit to measure their capture pools and withdrawal returns. The
replacement RTC had to use new process, native authority and Link identities, then
produce newer usable measurements from the same simulator acquisition generations.

## Preparation and receipts

The exact source trees were verified against the installed Manifest. The candidate RTC
and JLL trees were selected before installation, and the CAL2 instrument configuration
and calibration inputs came from the retained export. The installed export snapshot is
`1d0a587edbe39d9b36bb5f76e9ed6d9e4f9c7408`. The receipts include the parent export
identity, installed checksums, direct launch and stopped ledgers, camera traces, native
queue counters, artifact mappings and private fixture scripts.

The first two unscored starts reached systemd Ready and accepted native Quit during
fixture cleanup. The first uncovered the older launch ledger path in the probe. The
second uncovered its use of a retired CLI helper. The final probe validated the current
direct receipt and native control API before running the complete lifecycle on a fresh
private source epoch. Cold preparation also staged two package sources missing from the
fixture depot at their original locked trees. Those preparation records are archived
separately from the measured lifecycle receipts. [Qualification
receipts](qualification-receipts.tar.gz)
