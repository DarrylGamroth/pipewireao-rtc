# Fresh-depot installation of the four sealed RTC profiles

On `rtc-devel` on 2026-11-22 Pacific time, all four sealed CPU simulation
profiles reached Ready, accepted Start, produced the configured data,
returned to Ready on Stop and acknowledged Quit on a private PipeWire core.
Each successful Quit removed its socket and all observed owner processes.
The simulator mapped its installation's own optical image in every run.
Both fitted SPIDERS simulators also mapped their own installed native
command receiver. [Runtime receipts](managed.json) · [Depot provenance](depot.json)

| Profile | Data observed in Running | Service start to Ready |
| --- | --- | ---: |
| GPI2, first invocation | Five detector frames and five complete woofer, tweeter and tip/tilt sets | 219.9 s |
| GPI2, fresh invocation on the same installation | Five detector frames and five complete command sets | 61.8 s |
| CAL2 | Thirty 2 ms pupils, 30 LLOWFS offsets, six SCC exposures and five SCC offsets with the expected chopper phases | 354.3 s |
| SPIDERS fitted dual | Five DM demands and five simulator-applied commands | 118.6 s |
| SPIDERS fitted single | Five DM demands, sequences 2–6 | 35.8 s |

The first GPI2 invocation passed Start, observation and Stop. Its systemd
Quit attempted native shutdown, expired during an RTC effect and completed
emergency cleanup. The graph controller exited before the expiry was logged.
The log does not identify the expired effect. The repeated invocation used
the same installed application and ordinary deadlines and passed the entire
lifecycle. Each test verified at least two seconds of quiet observation after
Stop. CAL2's shell wrapper reported a syntax error after the Julia installer
had returned its successful installation path. A separate process verified
the installed Git snapshot and generated assets, followed by the passing
managed run.

## RTC and simulator startup

Each simulator is already a separate systemd service. After the private
socket accepts a connection, the launcher starts the simulator and graph
owners together. The current systemd `ExecStartPre` completes preparation
before the coordinator launches, so the simulator starts earlier than the
RTC coordinator in every profile. The coordinator retains the final
admission gate. [Launch implementation](../../../src/deployment/session_launch.jl)

The columns below are wall times and overlap. The endpoint column starts
at RTC process creation and ends when the control client has connected.
The model column starts at simulator process creation and ends at the
model-prepared log. In GPI2 the simulator subsequently establishes its
streams. In CAL2 it subsequently warms optical execution. An endpoint
observation gives an upper bound on when the endpoint became available.
These measurements use kernel process start ticks, invocation-specific
monotonic journal records and the service start return. [Startup events](startup-times.json)

| Profile | Core / simulator / RTC launch after service start | RTC launch to endpoint observed | Simulator launch to model prepared | RTC launch to service Ready |
| --- | ---: | ---: | ---: | ---: |
| GPI2 first | 51.1 / 58.2 / 74.8 s | 95.8 s | 53.6 s | 145.1 s |
| GPI2 repeat | 5.7 / 6.9 / 13.8 s | 33.5 s | 22.4 s | 47.9 s |
| CAL2 | 23.1 / 28.3 / 36.2 s | 37.4 s | 10.4 s | 318.1 s |
| SPIDERS fitted dual | 14.1 / 18.6 / 44.4 s | 60.2 s | 15.9 s | 74.2 s |
| SPIDERS fitted single | 5.7 / 6.9 / 8.7 s | 9.8 s | 16.2 s | 27.0 s |

On GPI2, simulator launch to connected-and-held took 87.3 s, then 35.8 s
on the repeat. The time from that marker to service Ready was 74.4 s, then
19.0 s. CAL2 spent 1.1 s preparing its model and 302.8 s in live optical
warmup. The service reached Ready 12.8 s after that warmup. The RTC reports
a shared wait for endpoint discovery and owner preparation, which includes
simulator work. Neither that wait nor coordinator lifetime measures
standalone RTC CPU demand. Host activity and cache state differed between
invocations. The data support individual timelines rather than a fixed
controller startup cost.

## Dependency and application identity

The original RTC 0.7.28 GPI2, CAL2 and two fitted SPIDERS exports pin
AdaptiveOpticsSimPipeWireHIL 0.5.11. The validation uses a local registry
with HIL source commit `7440add6a2ec125ef1f28c8e9f3999e7018dc697` and
changes its package version to 0.5.12 for resolution. The candidate Git tree
is `910b2882af3212148dc0c3077ca1fe4098eee237`. This version was used
privately. The published RTC, binding and native binary versions are
0.7.28, 0.9.6 and 4.0.8+0. GPI2 uses Julia 1.13.4. CAL2 and both SPIDERS
profiles use Julia 1.13.3.

Julia downloaded the registered sources and binary artifacts into an
initially empty depot. The dependency resolver used a separate writable
depot for its package-build step. The verification depot instantiated the
locked sources with dependency builds disabled. The HIL source directory
in that depot contained no receiver binary when installation began. The
only remaining Julia depots on the search path belonged to the Julia
distribution. The installer and services used a new PoCL cache.

For each profile, the installation takes a new Git-sealed application.
The RTC generator rebuilt the GPI2 simulator preparation receipt with the
new manifest digest. Comparing each export tree to its original checks every
scientific and deployment file. The changed files are the application
Project and Manifest and, for GPI2, the preparation receipt's manifest digest.
All 191 other manifest entries match for GPI2 and all 199 match for the
other three profiles.

## Changes under test

HIL builds its optical image using the installed package sources and
artifacts. It exposes the installation's own compiled cache to the
simulator and keeps shared compiled caches outside its search path.
A selected native SDK override applies during the build and the RTC's
selected SDK applies at launch.

HIL builds a synchronous command receiver for the clocked optical
simulator declared by both SPIDERS profiles. It links against the selected
SDK and opens the result in a fresh verifier process. At runtime the
simulator selects the installed receiver by absolute path and checks its
ABI and command record size. GPI2 and CAL2 use different simulation
contracts and do not require this receiver.

The same two regression checks failed on 0.5.11 and passed with the
changes. The focused startup selector passed 42 checks. The private-core
receiver selector passed 38 checks, including synchronous receive, reset
and Julia allocation checks, with the native compiler disabled in the
receiver process. Its first attempt exhausted the Unix-domain socket path
length in a nested temporary directory. It passed with a shorter private
socket path.

## Reproduction

Use the local candidate registry and the four exports with their sibling
Git snapshots. Start with an empty directory for `JULIA_DEPOT_PATH`,
append a trailing colon for the distribution depots, and set
`JULIA_LOAD_PATH=@:@stdlib`. Add General and the validation registry.
Run the following with the matching Julia executable, the profile's export
as the active project, and a new destination directory.

```julia
using Pkg
Pkg.instantiate(; allow_build=false, allow_autoprecomp=false)
using PipeWireAO, PipeWireAORTC
prefix = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
PipeWireAORTC.SessionInstall.install((package=abspath(ARGS[1]),
    destination=abspath(ARGS[2]), pipewire_prefix=prefix))
```

Start the installed unit on its private core with the same fresh depot.
Use the existing [flow probe and control driver](../rtc-0728-running/README.md#environment-and-reproduction)
to check native Ready, Start, data flow, Stop and Quit. While the simulator
is live, read its loaded library paths from `/proc/<pid>/maps`. This
distinguishes successful use of the installed image and receiver from a
fallback to package source or a depot receiver.
