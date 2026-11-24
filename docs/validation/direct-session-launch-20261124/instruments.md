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
| SPIDERS fitted dual CPU, retained | `84fcd27` with FGPW `8b18385` | An independent HIL 0.5.13 source using the exported SPIDERS optical configuration published the expected nodes on the private core. The composition prepared in 471.56 seconds, including 471.54 seconds of compilation. The fixture reached its 850-second deadline before Ready. |

[Installed live-session receipts](instrument-live-session.json)

## Reproduction

The local fixture directory recorded in `/var/tmp/rtc-direct-instruments-location`
contains `stage.py`, `install.jl`, `run.py` and `controls.jl` for rebuilding
and exercising the staged profiles. The stage records each RTC source tree
and, for SPIDERS, the companion tree. The scheduler, source controller and
readout taps use live native messages. Graph launch omits numerical warmup.
The exact-owner gate uses `exact-owner-attach.jl` and `exact-owner-claim.jl`.

GPI2 authoring commit `bb74679` in the instrument repository applies the
opening and priming declarations to both the integrator and HEART modes.
The native parser verified the open configuration and public reconstruction
pixels output in both modes. The change preserves the package pins and
calibration. The SPIDERS declaration remains in the fixture as
`spiders-priming-authoring.patch`.
