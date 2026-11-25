# RTC session controller admission and instrument profiles

MediaSession chooses the RTC's own controller by the Node ID assigned to its
local PipeWire Filter. It looks up that ID among controllers admitted by the
RTC ingress gate. Owner capture checks the same record against the current
Node and owning Client, including their registry serials, the declared name,
controller instance and PID. A controller whose authority has been retired
cannot regain it by repeating its old metadata.

The RTC owns those decisions. PipeWireAO.jl exposes native operations and
handles language interoperation. PipeWire assigns Link policy to a session
manager. A daemon-loaded module shares the daemon's context, whereas the
existing RTC client can be supervised as its own process. Frames travel
between the detector, graph and sink independently of the policy client.
[PipeWire session manager](https://pipewire.pages.freedesktop.org/pipewire/page_session_manager.html)
and [PipeWire modules](https://pipewire.pages.freedesktop.org/pipewire/page_modules.html).

## Instrument declarations

The profile selector resolves the declared session and mode using the RTC
export and deployment code. Each Link count includes all declared session
Links, including diagnostic streams. Execution groups are RTC lifecycle
groups and can contain a graph with several scientific stages.

| CPU profile | Links | Groups | Connections exercised |
| --- | ---: | ---: | --- |
| CAL2 simulator | 10 | 2 | The LLOWFS and SCC each feed their own controller and publish separate physical offsets. The upstream compositions preserve both returns and the pupil input. |
| SPIDERS fitted dual | 27 | 2 | The SCC and LLOWFS feed a shared DM controller. A separate SCC differential graph publishes a difference image and pair status. |
| GPI2 integrator | 32 | 1 | The frame graph takes the raw WFS input and publishes woofer, tweeter and tip/tilt commands. |

The CAL2 optical-calibration profile also validated with zero declared controller
Links. Reversing an authored passive flag in each controller profile failed
execution-group validation. These are configuration checks. The earlier private
systemd runs exercised CAL2 and SPIDERS on RTC 0.7.12 and GPI2 on RTC 0.7.22.
[CAL2 and SPIDERS runs](../rtc-0712-hil-054-20261111/README.md) and
[GPI2 runs](../rtc-0722-gpi2-classic-20261116/README.md).

## Verification

The effects and ingress selectors passed 309 assertions. The private-core
selector passed 52, including discovery of the local Filter, cancellation
during startup, and cleanup of owned Links. The two owner-capture regressions
failed four assertions on the base revision and passed all four after the
change. The service-free instrument selector passed 26 assertions. These
runs exercised control and configuration. Detector-to-controller latency and
instrument hardware were outside their scope.

The full core suite stopped at calibration materialization. The same selector
on the untouched base gave the identical result of 110 passes and 12 failures.
The failing cases check rejection of invalid nested calibration artifact hashes
and paths. Later core selectors did not run in that invocation.

## Reproduction

RTC base `987296b87792321ab2b85ca4a38cb908b2f52305` used the repository
Manifest with Julia 1.13.4, PipeWireAO.jl 0.9.3 and PipeWireAO_jll 4.0.4+0.
The instrument declarations were read from adaptive-optics-simulations at
`1b1b3022065684741efea7b7be66049b89762332`. Run from the RTC package root
and pass the instrument repository path to the [profile selector](profiles.jl).

```sh
julia --startup-file=no --project=. -e '
using PipeWireAO
ENV["PIPEWIREAO_PREFIX"] = String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir)
for name in ("effects", "ingress", "private_core")
    include("test/media_session_" * name * ".jl")
end'
julia --startup-file=no --project=. docs/validation/session-orchestration-20261121/profiles.jl /path/to/adaptive-optics-simulations
```
