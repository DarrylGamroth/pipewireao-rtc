# HEART with the AOS simulated plant

Functional deployment verification, 2026-10-02. Active authority is
RTC-ARCH-022 and RTC-DEV-028. The native HEART source and scientific algorithms
were not modified for this increment.

## Implemented path

```text
AOS complete ADC frame → SPA Standard WFS sink → UDP → native HEART
native HEART → UDP → SPA Standard DM source → AOS command adoption
```

The private PipeWire core owns bridge nodes. An `external-rtc` Rust session
owns exact links and lifecycle without an FGN/JFG processing graph. The
supervised native owner initializes HEART, enables the declared controller
flags, enters correction and verifies its six scientific worker placements
before simulator admission. All native threads stay within the declared CPU
envelope, excluding CPUs 0 and 1. Controller flags have command SUCCESS
acknowledgements; effective readback is not available.

HEART uses its ordinary progressive stdWfs handler. The simulator computes a
complete optical exposure before the SPA sink packetizes it. This is not
progressive optical detector generation or a physical camera timing model.

## Verification results

The retained experiment root is
`/home/dgamroth/.cache/rtc-heart-hil-20261002`. The portable
[evidence summary](HEART_HIL_EVIDENCE.json) records paths, hashes and observations.
The [independent review](HEART_HIL_REVIEW.md) records findings and disposition.

| Profile | Input | Sender readout interval | Accepted exchanges | Wire result |
| --- | --- | --- | --- | --- |
| Classic CPU | 352 × 352 U16, 32 packets per frame | 0 µs | 16 + reset + 16 | every pixel and 277 command coordinates match retained buffers |
| Copper CPU | 64 × 64 U16, two packets per frame | 2000 µs | 16 + reset + 16 | every pixel and 277 command coordinates match retained buffers |

These are the relocated installed profiles
`~/.config/pipewireao-rtc/revolt-classic-heart-hil-cpu` and
`~/.config/pipewireao-rtc/revolt-copper-heart-hil-cpu`, using adapter commit
`277d822` and installed plugin commit `9aeea53`. Their canonical evidence folders
are `evidence/classic-final` and `evidence/copper-final`; every exported package
artifact hash was verified (349 Classic, 342 Copper).

Both checks exercise held admission at sequence zero, mid-batch pause/resume,
rejection of reset while running, stopped paired reset with a new native PID,
restart, invalid controls, completed-source rejection and successful owner
shutdown. All 27 native threads and the six required workers were inspected.
The separate child-death check kills only the owned native child while the
source is held, observes the actual supervisor `required heart exited` error,
and verifies no admission, reaped children and removed owned runtime.

Each accepted capture also contains two extra repeats of the final accepted
command during native reset/shutdown. Native logs show shutdown forcing
downstream propagation. These are held nonzero commands, not necessarily a
zero or flat. The wire checker accounts for them only inside recorded stopped
reset/shutdown intervals, with no outstanding WFS frame and an exact payload
match to the last accepted command. It rejects unmatched IDs, altered payloads
even with valid checksums, or unsolicited repeats outside those intervals.
The plant adopts exactly 32 commands. Shutdown closes the simulator command
stream before authorizing native HEART shutdown.

Both generated systemd user services also passed 16 + reset + 16 exchanges
and stopped with `Result=success`, `ExecMainStatus=0` and inactive/dead state.
They are installed but not enabled for login. These additional runs validate
service lifecycle and simulator reports; packet equality was checked in the
canonical foreground captures above. The first ad hoc service driver mistakenly
sent a second start after automatic admission; the RTC rejected it in Running
and the service shut down successfully. That driver failure is retained, and
the corrected driver observes the automatic first start.

The existing Copper FGN CPU HIL profile also passed 16 + reset + 16 exchanges
through the changed supervisor. Focused Julia control tests pass 77 assertions;
simulator tests pass 23. Python deployment tests pass 117 tests with one
intentional skip. Rust workspace tests, live-feature tests, formatting and
Clippy pass. The adapter's focused suite passes 232 assertions, including eight
warmed borrowed-copy cases allocating zero bytes. All six plugin tests pass
normally and under ASan/UBSan; the DM-source test also passes 20 repetitions.

Passing live logs retain PipeWire warnings about DBus loading, mixer setup and
format release (`EBUSY`) during teardown. These warnings were not corrected by
this increment; the finite payload, lifecycle and exit checks passed despite
them. Clippy also reports the existing future-incompatibility warning for
`proc-macro-error2` 2.0.1. Cold package precompilation occurs before admission,
so these runs do not establish first-use latency or absence of compilation
during a higher-rate workload.

## Failures and repairs

Earlier failed artifacts remain retained as failures:

1. Classic admission rejected an incorrect passive link declaration.
2. DM-source buffer negotiation required a diagnostic HeartStdDm annotation
   that the generic consumer did not request. Header/data remain mandatory;
   Acquisition and HeartStdDm are now optional bounded annotations.
3. The graph-free Rust owner inherited an FGN processing-thread requirement.
   It now has its own control-only placement/client configuration.
4. WFS sink negotiation omitted Acquisition, which the simulator source
   requires for its local identity. The sink now advertises this optional
   annotation without serializing it into UDP.
5. The adapter supplied scalar stride 2 for a Classic U16 image. The WFS sink
   requires packed row stride 704. The adapter now computes the appropriate
   stride once during preparation; pixel payloads and callback copies are
   unchanged. Fail-before/pass-after and allocation evidence are retained.
6. Copper with zero readout sent both packets but timed out before its first
   command. The identical package with only a 2 ms sender interval passed.
   This is observed pacing dependence; the native mechanism and minimum safe
   interval are not established. Copper export defaults to the demonstrated
   setting; explicit overrides are characterization inputs.

Review also corrected evidence code: the raw WFS tag is 1; native diagnostics
are retained after process reaping without permitting copy failure to bypass
cleanup; source-close failure withholds consumer quit and revokes transport;
the wire checker distinguishes lifecycle resends from normal exchanges.

## Units, calibration and scope

The SPA DM decoder converts wire micrometres to Float32 metres once. Every
adopted coordinate matches Float32(Float64(wire µm) × 10⁻⁶), without an actuator
permutation. The AOS boundary applies scale 1. Native backgrounds, Classic
reference slopes and DM static offsets come from the simulated plant. Recorded
reconstructors, projections, masks and thresholds remain hybrid calibration.

The numerical fixture interprets commands as OPD. Neither stdDM nor these
finite tests establish physical mirror displacement versus OPD, its optical
factor of two, registration, scientific equivalence or closed-loop convergence.
The earlier Classic exact-replay discrepancy HIL010 remains separate.

Fresh native children restart local stdDM counters. UDP carries no acquisition
generation. Stream reset and local queue drainage do not fence arbitrarily
delayed prior-generation packets. These profiles are private loopback fixtures,
not a qualified physical/network deployment. Functional checks at a requested
10 Hz do not establish that cadence, maximum rate, latency tails or deadlines.
GPU simulation, exclusive-core isolation and progressive readout performance
require subsequent evidence.

## Copper EMCCD settings

The current plant uses the AOS EMCCD-specific acquisition node, with EM register
gain 1, excess-noise factor 1 and zero clock-induced charge. Photon/readout
noise are enabled. It therefore does not exercise nontrivial multiplication.
Its inherited full-well and read-noise settings are provisional simulation
parameters; they are not a DU860 calibration.
The local generic iXon contract does not yet identify the user-reported DU860.

The user identified Copper's camera as an **iXon3 DU860** and supplied tentative
settings: **10 MHz horizontal readout, 14-bit digitization, 0.45 µs vertical
shift, pre-amp gain 4.6× and EM gain 2**. These are user-reported configuration,
not camera readback or a measured conversion calibration. They are recorded for
a detector-fidelity increment. AOS's
`gain` maps to EM register gain; it has no separate pre-amp or vertical-shift
parameter in the current complete-frame acquisition node. Pre-amp multiplier
must not be substituted for EM gain or directly treated as electrons per ADC
count. The latter needs model/readout-specific calibration. Andor supplies
individual camera sensitivity values by readout and pre-amplifier configuration
in its [performance-sheet guidance](https://andor.oxinst.com/learning/view/article/understanding-ccd-saturation:-pixel-well-depth-vs.-bit-depth).
Andor documents
model-dependent shift choices and separate pre-amp/EM settings in its
[SDK readout article](https://andor.oxinst.com/learning/view/article/sdk-index-values-for-readout-speeds)
and [iXon3 hardware guide](https://andor.oxinst.com/downloads/uploads/iXon3_Hardware_Guide.pdf).
The 2000 µs SPA packet interval above is an empirical transport compatibility
setting, not derived from those camera clock speeds. A physical timing model
would also need crop/binning, serial-register overhead, frame-transfer mode and
transport buffering; pixel-clock division alone is insufficient.

The current accepted fixture is unchanged; a detector-setting change must
regenerate simulation-derived offsets consistently across the three RTC paths.
