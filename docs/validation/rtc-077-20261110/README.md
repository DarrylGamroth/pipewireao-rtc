# GPI2 startup and controls with RTC 0.7.7

RTC 0.7.7 prepares session controls and parameter owner dispatch before
reporting readiness. FilterGraphPipeWire 0.5.4 shares graph snapshot
compilation across PipeWire wire types. The releases carry the fixes tested
against the earlier startup timeout. [RTC 0.7.7](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.7),
[FilterGraphPipeWire 0.5.4](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/releases/tag/FilterGraphPipeWire-v0.5.4),
[RTC #41](https://github.com/DarrylGamroth/pipewireao-rtc/issues/41#issuecomment-6764056904)

| Package | Release commit | Registered source tree |
| --- | --- | --- |
| PipeWireAORTC 0.7.7 | `a7aac1c3755fe038c97674997498009bda9f0249` | `0f36e54dc2b8a20d2867a711106adef769739dcb` |
| FilterGraphPipeWire 0.5.4 | `fd8103d9f17440b1f33f268887e6a76af947d4c8` | `65e50f513c60d0fdcc883c493c6073671fcbcff1` |

## Registry-only export and installation

Julia 1.13.3 used an initially empty depot with public General at tree
`11bd5ef8e253367c2c9dcd98aaca55d867af63e3`. Pkg resolved the GPI2 Project
from instrument commit `6a1fbfddb7bf03212077a8f512af661d9b0ecc27`. The
Manifest contained no path or repository overrides. Installed source hashes
for both releases and the other nine graph, science, transport and JLL
packages matched their registry entries. [DarrylGamrothRegistry at `f04eeeb`](https://github.com/DarrylGamroth/PackageRegistry/commit/f04eeebfc76d70e841c9adc38e9afc46a9a15a60)

The cohort also used FilterGraphs 0.10.2, FilterGraphAlgorithms 0.12.2,
PipeWireAO 0.9.2, AdaptiveOpticsSim 0.3.22, AdaptiveOpticsSimPipeWireHIL 0.5.1,
AdaptiveOpticsCalibration 0.17.3 and Proper 0.4.1. The private core used the
PipeWireAO 4.0.2 SDK artifact `b84754cc61ae9a8e33d31ec4352f188fa5405581` and
the registered queue artifact `20afa07132938ae663c7cf4c10f00172ca40e70f`.
The validation depot and the owners' writable prefixes contained no
artifact overrides.

The instrument repository's `tools/build.jl` exported `gpi2` with
`gpi2/profiles/simulator/profile.yaml`, a workstation CPU host file and the
Pkg-generated Manifest. The installed Project and Manifest matched the
resolved files byte for byte. The Manifest SHA-256 was
`5d5de34e72d1cfb5f870ac6568c2315070bb70b75a8003a5fa89a358d41a9d80`.
Package loading and export populated the depot before timed startup. An
instance-specific systemd drop-in selected that depot. The Julia owners
used it with their ordinary private writable depot prefix.

The host file selected 10 Hz simulator pacing, controller CPUs 8–9, core
and RTC CPUs 8 and 10, session CPU 10, simulator CPUs 11, 13 and 15, and
analysis CPU 14. This placement differs from the original #41 run.

## Private-core startup and controls

The first instance reached Ready in 472.39 s and reported Running. The
browser bridge could not load its web protocol module, so that instance
received no operator writes. The second instance used the same installed
application and the bridge's web protocol module in the bridge process only.
It reached Ready in **428.08 s**, with **471.92 s** remaining in the 900 s
startup budget. Systemd preparation took 31.46 s, followed by 396.62 s
from RTC process start to Ready. The standalone simulator logged Prepared
284.37 s after startup began.

Both operations went through the browser and loopback bridge on the second
instance. Native observations confirmed adoption. Each operation sent one
write, recorded zero browser errors, and left the RTC Running with all 32
declared session Links active.

| Operation | Native adoption | Detector sequence | Woofer command sequence |
| --- | --- | --- | --- |
| Open loop | Closed changed from true to false. Requested and active generations advanced from 0 to 1. | 26 → 27 | 27 → 28 |
| Woofer Shape | Requested and active parameter sequences advanced from 0 to 1. All 97 nonzero values matched the acknowledged request. | 49 → 50 | 50 → 51 |

Both stop hooks attempted native Quit once. The client lost the owner proxy
before receiving a reply, and the RTC logged `object is not captured` during
cleanup. Both launch records marked emergency cleanup complete. The private
sockets were removed, the session, owner and analysis processes exited, and
the service journals recorded no SIGKILL.
