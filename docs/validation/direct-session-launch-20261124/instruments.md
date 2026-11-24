# Classic, GPI2 and SPIDERS startup

The functional workstation fixtures use a private PipeWireAO 4.0.8 core for
each profile. They relocate the retained CPU placements to CPUs 12–15 to
avoid the CAL2 timing placement. Treat their elapsed times as fixture
diagnostics. The detector and command configuration, calibration bytes,
native Port formats and declared Links come from the retained instrument
exports in `/var/tmp/rtc-ndarray-integration.beRGH1`.

| Profile | Startup correction | Required live output |
| --- | --- | --- |
| Classic CPU | `closed-loop-correction:closed=false` | `--prime-on-output slopes,validity` uses Shack–Hartmann slopes and the calibrated active-lenslet mask |
| GPI2 CPU recovery | `closed-loop-correction:closed=false` | `--prime-on-output reconstruction-pixels` requires positive current flux and prior normalization from live exposures |
| SPIDERS fitted dual CPU | Both correction integrators start open in their authored branch graphs | `--prime-on-output correction:closed=modal-residual` selects an SCC pair. `--prime-on-output llowfs-correction:closed=llowfs-modal-residual,llowfs-validity` selects a valid LLOWFS measurement. |

The preparation probe loaded the three actual calibrated graph configurations,
prepared each twice and checked separate open, unprimed attachments. It passed
six Classic, eight GPI2 and eight SPIDERS assertions. A tracked RTC regression
closes one controller on the first composition, removes its source files and
recreates an open second attachment from the retained declarations. Its four
assertions passed. See [the composition regression](../../../test/calibration_type_dispatch.jl).

Released FilterGraphPipeWire 0.5.11, subtree
`601d7d8e32d4a818e3410b3c66bc943a0eca1ee0`, rejects the observer required by
the SPIDERS priming declarations. The same probe accepted the observer with
the local companion backport `8b1838554f7fef041cbfedd9e21d8d1bf0898bee`,
subtree `76cb8f2d09397a53ea0e6b0b57502ab3a75d816f`. It preserves the
FilterGraphs and FilterGraphAlgorithms pins. Its maintained native callback
fixture passed 35 assertions including independent arrivals, published-output
availability, reset and warmed allocation. Existing Classic and SPIDERS
release pins remain in place.

## Native graph restart

The exact Classic, GPI2 and SPIDERS graph owners each passed ten checks on a
private core using Julia `-O0`. The fixture killed the first native bootstrap
claimant with SIGKILL and connected a new claimant. The graph owner kept its
PID. Native bootstrap and graph serials changed, and the new claimant
acknowledged Quit. Both native property snapshots reported Open and unprimed
for each correction, including the two branches of the SPIDERS composition.
[Native rebind receipts](instrument-native-rebind.json)

| Graph | RTC source | Persistent owner PID | Bootstrap serials | Graph serials |
| --- | --- | ---: | --- | --- |
| Classic CPU | `3c964d3` | 1617116 | 13, 47 | 17, 52 |
| GPI2 CPU recovery | `0747f0f` | 1618755 | 14, 68 | 20, 76 |
| SPIDERS fitted dual CPU | `84fcd27` with FGPW `8b18385` | 1633335 | 13, 54 | 17, 59 |

This selector checks the native bootstrap and graph lifetime with the
calibrated graph declaration. It runs without camera Links. The managed
instrument and separately publishing source trials use the full session.

## Installed sessions

These trials use Julia 1.13.4 for the RTC and graph owners. CPUs 12–13
share a physical core, as do CPUs 14–15. The standard-optimization cold
trials also overlapped workstation compilation. Their elapsed times are
specific to these attempts.

| Profile | RTC source | Observed outcome |
| --- | --- | --- |
| Classic CPU, session-owned | `3c964d3` | Two installed activations reported Ready with the selected Julia as MainPID, each with 20 declared Links. Both rejected Close while held, then started and observed generation 1 sequence 1 in both the detector and slopes. Both corrections became primed and remained Open. Native stop returned Ready, systemd stopped successfully, and the replacement used a new invocation, session UUID and private core. |
| GPI2 CPU recovery, session-owned | `0747f0f` | The managed simulator connected held at sequence zero. The graph finished calibrated preparation and entered native node construction. systemd reached its 900-second start timeout before Ready. |
| GPI2 CPU recovery, session-owned | `61b77ca`, graph owner `-O0` | The installed activation reported Ready with 32 declared Links and rejected Close while held. Detector and reconstruction pixels both began at generation 1 sequence 1. The correction primed and remained Open. The session refused a stale recovery release and accepted a new recovery request, which reached `applied`. Native stop returned Ready and systemd stopped successfully. The installation used normal runtime simulator construction. A duplicate second activation was canceled to prioritize retained-owner trials. |
| SPIDERS fitted dual CPU, retained | `84fcd27` with FGPW `8b18385` | An independent HIL 0.5.13 source using the exported SPIDERS optical configuration published the expected nodes on the private core. The composition prepared in 471.56 seconds, including 471.54 seconds of compilation. The fixture reached its 850-second deadline before Ready. |
| SPIDERS fitted dual CPU, retained | `84fcd27` with FGPW `8b18385`, graph owners `-O0` | The independent source and both graph owner units were active when the installed session reached Ready with 27 declared Links. The readout client stopped before running the session because it imported an unused package absent from the instrument project. That attempt establishes installation and Ready, and the readout import was corrected for subsequent trials. |

[Installed live-session receipts](instrument-live-session.json)

## Retained source and graph owners

Classic used its configured v3 optics in the managed HIL package's
free-running acquisition mode. A separate native bootstrap client started
the simulator and tracked generation 1 from sequence 8 before RTC startup
through sequence 2742 after the two RTC activations. The source, private
core and graph-owner services retained their process IDs, process start
times and systemd invocations through the forced replacement and graceful
stop. The test used `3c964d3` and graph-only `-O0`.

The first RTC was killed while Running. Its replacement used fresh declared
Link serials and a fresh graph Node serial (144 to 226). It began Open and
unprimed, refused Close while held, then primed on fresh live output during
Running. The first captured detector acquisition advanced from 1574 to
2434 with the same acquisition domain and generation. The first slopes
advanced from 1594 to 2454. The replacement accepted an Open write while
Running. The old control client reported that its native owner proxy had
been removed. Native stop returned Ready and systemd stopped the replacement
while all three independently supervised owners remained active.

GPI2 used its configured v3 optics with a separate free-running native
bootstrap client and RTC `61b77ca` with graph-only `-O0`. The source cursor
advanced in generation 1 from sequence 3 before RTC startup to 396 after
both activations. The graph Node serial changed from 208 to 312, declared
Link serials changed, and the same core, source and graph services survived
the Running RTC's SIGKILL and subsequent graceful stop. Detector sequence
255 advanced to 369 and reconstruction pixels advanced from 259 to 372 in
the same acquisition domain and generation. Both activations began Open,
unprimed and recovery-idle, then primed in Running with the correction open.
The replacement refused release using the prior activation's actual recovery
generation, accepted an Open write and applied a new recovery request. The
prior control client reported that its owner proxy had been removed.

SPIDERS fitted dual used RTC `84fcd27` with the FilterGraphPipeWire backport
and graph-only `-O0`. The already-publishing source ran the retained optical
configuration with HIL 0.5.13 in Julia 1.13.3. The private core, source and
both graph-owner services kept their process identities through forced RTC
replacement and graceful stop. The camera and DM source Nodes kept their
native serials. The composition's graph Node changed from serial 690 to 788
and the RTC allocated new Link serials. Both correction branches were Open
and unprimed while held, became primed from live output in Running and
remained Open. The SCC and LLOWFS camera sequences advanced from 10 to 19
within their respective acquisition domains and generations. Their modal
residual sequences advanced from 12 to 21 and 11 to 20, respectively. The
replacement rejected the prior recovery generation, accepted an Open write,
applied a new recovery request and stopped cleanly. The old client's owner
proxy had been removed.

## Reproduction

The fixture scripts rebuild staged applications from the retained exports and
record each RTC source tree and its applicable companion tree. The scheduler,
source controller and readout taps use live native messages. Graph launch
omits numerical warmup. The scripts record functional results on the private
cores. [Instrument fixture sources and selected checks](instrument-fixtures.tar.gz)

GPI2 authoring commit `bb74679` in the instrument repository applies the
opening and priming declarations to both the integrator and HEART modes.
The native parser verified the open configuration and public reconstruction
pixels output in both modes.

Instrument validation branch `codex/spiders-live-open-startup` at
`7aa90d43b3d00ecac9793d718568dc6c9dcf46db` documents the required companion
and adds the fitted dual declarations. Three checks compared the parsed
authoring with the installed graph-owner arguments and checked the package
version from the selected companion tree. The validation branch and patch
target the fitted dual mode. [SPIDERS authoring patch](spiders-fitted-dual-priming.patch)
