# RTC 0.7.22 managed startup and Quit

Tested the GPI2 and REVOLT Classic CPU simulator profiles from instrument
`4df5804e6f3c824f31904e144f304c88e1e34fe5` on rtc-devel with Julia 1.13.3.
The profile and host inputs were `profiles/simulator/profile.yaml` and
`profiles/simulator/host.cpu.example.yaml` under each instrument. Both
exports were prepared with the registered RTC 0.7.22. The installed Project
and Manifest matched each export byte for byte.

One initially empty Julia depot served the two runs in sequence. Pkg populated
it from General tree `5d36cfb278fba525c2005bc741b0bd87188359b5` and
DarrylGamrothRegistry commit `7852867dc57143da1a78d967c91680b1ef32d8a7`.
GPI2 reused packages and artifacts fetched into that depot during the same
verification. The manifests carried registry trees and no path or repository
overrides. RTC reported version 0.7.22 and tree
`c6f7b9c1f175e6b15f5c7188ede8bb1e6fa152b7`. The apps used
AdaptiveOpticsSim 0.3.26, AdaptiveOpticsSimPipeWireHIL 0.5.9,
FilterGraphs 0.10.3, FilterGraphAlgorithms 0.12.5, FilterGraphPipeWire 0.5.6,
PipeWireAO.jl 0.9.3 and PipeWireAO_jll 4.0.4+0.
The daemon and client library came from JLL artifact
`f09bac41e69c35bf0114480fecd814eb129ee121`.

| Application | Manifest SHA-256 |
| --- | --- |
| GPI2 | `afeee6b33bc5b41d60664f059ef434c94205350c3d68099d256d8a948d75d91f` |
| REVOLT Classic | `a5f0a6041c53aa8c09c5c2d0230a02d3248681d80331abf8516d1820cfcb9c3a` |

Each installation used the released `SessionInstall` entry point. Every
launch selected a unique runtime systemd user unit and private PipeWire
socket. The stop check used the managed systemd stop path and its native
Quit acknowledgement. The probe checked the session and Julia owners'
depot paths, including their generated per-application startup caches.
The first Classic install's graph-cache compiler exited on signal 9 and
the containing cgroup recorded an OOM kill. The retry and the GPI2 install
used `JULIA_IMAGE_THREADS=1` for installation. The launch and stop times
below exclude installer work.

| Private-core run | Start to Ready | Native Running | Native Quit | systemd result |
| --- | ---: | --- | --- | --- |
| REVOLT Classic | 81.39 s | Verified | Acknowledged | `success` |
| GPI2, Quit after Running | 114.55 s | Verified | Expired | `exit-code` |
| GPI2, Quit after 30 s in Running | 99.77 s | Verified | Expired | `exit-code` |

Start timing measures the blocking `systemctl --user start` call, with the
900 s budget from the installed unit. In each run native Status verified
Ready and Running and checked the identities of the private core, Julia
controller, parameter publisher and standalone HIL simulator.

Classic's managed stop and reconciliation took 16.23 s. The retained
record showed `attempted=true` and `accepted=true`. The service exited
with `ExecMainStatus=0`.

Both GPI2 stop attempts used one native Quit. The retained records showed
`attempted=true` and `accepted=false`. In each attempt the RTC logged
`Session effect expired; outcome unknown`, and the stop client reported
that its owner proxy was removed. Systemd recorded `ExecMainStatus=1`.
The second attempt reused the same installed application on a new
private core and verified Running again after the 30 s wait. The logs
establish the repeated expiry. They do not identify the pending effect
or its timing before the deadline.

The session and all four required owners exited and the private socket
and temporary unit links were removed after every launch. The service
journals recorded no SIGKILL during shutdown. GPI2 passed startup and
failed clean native Quit on both attempts.
