# Recorded RTC deployment validation

## Delivered increment

RTC-DEV-020 through RTC-DEV-023 are implemented and functionally validated for
the maintained recorded-input, non-actuating profiles. The deployment owns a
private PipeWireAO core, the serialized Rust lifecycle/control owner and an
optional external Julia scientific owner. FGN and JFG execute the scientific
graphs. The supervisor does not process frames or implement another scheduler.

[Deployment instructions](../deployment/README.md) cover export, installation,
preflight, foreground operation, systemd user units and local controls.
[Independent review](DEPLOYMENT_REVIEW.md) records dispositions and scope.
[Evidence summary](deployment-evidence.json) retains artifact hashes, effective
placement and results. Raw local records are retained beneath
`~/.cache/rtc-deployment-functional-20261001/`; installed runtime does not depend
on that directory.

## Final installed profile checks

All eight profiles are installed under `~/.config/pipewireao-rtc/revolt-*`.
They use the same scientific artifacts as their maintained generators, an
installed PipeWireAO prefix at `/opt/pipewireao`, and ordinary resolved Julia
dependencies. Each source runs at 10 Hz; row profiles use 2 ms simulated readout,
shorter than the 100 ms frame period. These settings qualify a short functional
replay, not a maximum rate or latency bound.

| Profile | Mode | Expected commands | Observed | Cleanup |
| --- | --- | ---: | ---: | --- |
| Classic FGN | frame | 7 | 7 | passed |
| Classic FGN | row | 7 | 7 | passed |
| Classic JFG | frame | 7 | 7 | passed |
| Classic JFG | row | 7 | 7 | passed |
| Copper FGN | frame | 4 | 4 | passed |
| Copper FGN | row | 4 | 4 | passed |
| Copper JFG | frame | 4 | 4 | passed |
| Copper JFG | row | 4 | 4 | passed |

Each check observes Ready with zero discarded commands before admission,
verifies realized thread placement, starts the session, checks command count,
resets while stopped, rejects an invalid command without faulting, and removes
owned processes/runtime. Frame checks also submit scalar and reconstructor
updates. Row checks keep calibration fixed: an adoption test is separate from
an exact replay. Counts alone are not a numerical or universal identity oracle.
The separate Classic FGN row probe verifies Header sequences 0–6 exactly once.

The maintained placement excludes CPUs 0/1: source CPU 12, sink CPU 8, native processing CPU 2,
Julia processing CPU 4, monitor CPU 10 and housekeeping CPU 14. Realized data workers use
FIFO 83; control/JIT leaders remain SCHED_OTHER. Default profiles request neither
memory locking nor CPU power QoS. Effective affinity is not exclusive CPU/IRQ
isolation. User-service limits cannot supply privileges absent from the manager.

## Corrected delivery boundaries

The FITS source had two demonstrated loan-handoff defects: process re-entry
could hide or abandon a pending row loan, and timer publication could overtake
an incomplete graph cycle. It now reports existing loans before cadence checks
and waits for the exact loan return before another timed row release. Finite
row completion likewise waits for the terminal source loan. No PipeWire core
implementation, scientific algorithm or additional data copy changed.
The installed source-to-discard probe delivers all 224 blocks on both same-loop
and separate-loop placements. Restoring the old behavior fails its regression.
The FITS repository retains the detailed row-handoff evidence and tests.

After that correction, native Classic still suppressed the initial frame even
though all 224 source blocks arrived. Maintained owners already preload the
calibrated reconstructor; RTC submitted it again after execution started.
Under the same final binary, source, scientific artifacts and input, restoring
only this duplicate initial mapping delivers IDs 1–6; omitting it delivers
IDs 0–6. Initial file submission is now optional, while live parameter routes
remain derived from validated passive links. The exporter omits duplication
only for these evidenced owner-preloaded profiles.

Progressive parameter adoption deliberately abandons an in-flight publication
unit to avoid a partially updated command. Identical matrix bytes do not imply
a no-op. Julia's calibrated offline probe publishes all 7 samples when an update
arrives before offset 0, and 6 when it arrives mid-frame, then recovers on the next
complete sample with unchanged feedback during abandonment. Native frame and
row live tests verify a newly requested generation becomes active and later
command counts advance while it remains active. These are adoption/recovery
checks, not loss-free mutation or new numerical-equivalence claims.

## Lifecycle, controls and services

Separate native-frame and Julia-row control fixtures pass seven invalid-request
cases in both Ready and Running, preserving scalar values/generations and
lifecycle. They verify a deliberately queued pending parameter rejects another
submission, stopped and running Float transactions, group stop/start, reset
restrictions, subsequent adoption and clean shutdown. No normal profile queues
a redundant startup value to manufacture that pending test.

The refreshed user-service checks pass native start/stop, a second fresh native
launch, native dependency-death cleanup and Julia start/stop. Each normal replay
delivers 4 Copper commands. A killed required RTC process terminates the owned
set and leaves the unit failed rather than silently reusing it. All units are
left stopped; none was enabled automatically. The supervisor confirms source
stop or terminates its private source core before external consumer quit markers.

Socket clients and file preparation run outside the lifecycle owner. Commands
have bounded request/argument/payload/reply sizes and total client deadlines.
Unknown timeout outcomes remain unknown; the launcher does not retry mutations
automatically. Existing effect deadlines and ordinary filesystem stalls remain
documented limitations.

## Software verification and provenance

- RTC source baseline: `50dc370`; release SHA-256
  `1a32b6f6b86e81fb942c87de7f8f870a42ccbef4ed27ad208fce9a9db985f78c`.
- JFG owner/public preparation: `116cdb4`.
- FITS source: `8c862cb`; installed plugin SHA-256
  `3f3fb042201afb2cf646fd76a468103d8f57609e0630eef065b332fe03e14e2a`.
- Public plugin headers: `655b352`; scientific FGN bundle source: `518a578`.
- Rust: 89 passed, 3 environment-gated tests ignored in the ordinary suite;
  selected private-core property and live-replacement tests run separately.
- Python: 38 passed, including real export/relocation/tamper checks for all 8.
- Julia: 77 deployment checks, 24 preparation checks and 332 actual-calibration
  reset-oracle assertions with zero maximum command/feedback difference versus
  fresh execution. This oracle checks Julia reset, not HEART equivalence.
- FITS: 3 suites plus the shared image-frame suite passed. Formatting, strict
  Clippy, local documentation links and changed Mermaid renders passed.

Existing startup/teardown warnings remain: optional DBus support is absent,
PipeWire reports mixer/format-unset warnings, Rust reports a dependency future-
compatibility notice, and Julia can report package precompilation/version-cache
warnings during preparation. Their logs are retained; the listed functional
checks pass. No per-frame tracing/logging was added to production.

These checks do not establish physical-device authority, a hardware closed loop,
new HEART numerical equivalence, worst-case timing, or maximum delivery rate.
The earlier characterization remains separate; no new latency/capacity campaign
was run for this deployment increment.

## Next increment

Create the AOS/HIL graph using AdaptiveOpticsSim.jl and the appropriate
AdaptiveOpticsSimPipeWireHIL.jl adapter. Establish detector/DM units, schemas and
calibration provenance, a simulator readiness/release contract, and command-
to-next-frame causality. Then exercise both scientific owners through the same
non-actuating plant, reset and update scenarios. The older 277-coordinate HIL
integrator fixture is not the matched Classic extrapolation/limiter/feedback
graph and must not be relabelled as such.
