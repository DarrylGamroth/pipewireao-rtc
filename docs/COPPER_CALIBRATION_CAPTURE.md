# Copper operational capture increment

## Starting state and scope

RTC main `7fe0bcd` records the accepted finite Classic CPU method selection.
This increment begins in the clean `work/copper-calibration-capture-20261003`
worktree and extends RTC-ARCH-023 / RTC-DEV-029's capture endpoint to Copper.
It preserves the normal noisy detector, four-pupil pixel representation,
absolute physical commands, completion association and ordinary graph owners.
HEART, plant registration, controller coefficients and detector settings are
unchanged. Capture support does not establish a new operational Copper matrix.

## Declared payload and settling

| Channel | Element type | ROW_MAJOR shape | Bytes per exposure |
| --- | --- | --- | ---: |
| Raw detector | UInt16 | 64×64 | 8,192 |
| Reconstruction pixels | Float32 | 4×900 | 14,400 |
| Current mean-pupil intensity | Float32 | 1 | 4 |
| Total | | | 22,596 |

The measurement vector has 3,600 entries. Current mean-pupil intensity is a
diagnostic channel, not a 3,601st measurement. Preserve the four declared pupil
origins and each pupil's row/column order. The deployed algorithm normalizes
each frame with the **previous successful frame's** mean. Reset starts with zero
gain. After startup and each adopted probe, at least one completed discarded
exposure must therefore precede accepted capture/collection. Immediate settling
must be rejected before generating any accepted measurement. Positive model-time
settling and a discarded-exposure count retain their completion semantics;
restoration does not authorize a new response batch.

The existing bounded reply admits up to 41 averaged exposures for 3,600
measurements; 42 exceeds the conservative 64 KiB reply bound. This increment
preserves that bound and does not enlarge Julia/Rust protocol records. Larger
raw captures retain the separate finite payload/metadata budgets.

## Implementation and verification gates

- Parameterize capture storage by a concrete profile descriptor; use dispatch
  for payloads. Preserve Classic's four-channel format and budget.
- Admit an externally declared expected profile in exported capture packages
  and capture validation. A manifest cannot choose its own measurement contract.
- Preserve full acquisition domains, consecutive identities, exact durations,
  settled association, immutable files, hashes, deadlines and held fault state.
- Establish Copper rejection before the change, then test all three channels,
  exact byte budgets, wrong-profile/payload rejection, packed views, interruption,
  priming and the 41/42 reply boundary without unintended model effects.
- Run bounded CPU FGN/JFG captures through public deployed endpoints, finish
  reference restoration/release/shutdown, and independently inspect the records.
  Compare graph outputs on identical transported ADC inputs where practical.

## Scientific boundary

Dark-frame moments and a 3,600-element normalized lamp reference can be measured
through this path. Copper currently has no adopted reference-pixel subtraction
parameter. Capturing a reference is evidence, not reference adoption through
Classic's reference-slopes interface. A full operational Copper campaign,
reference-centering graph contract, interaction/reconstructor acceptance and
correction checks follow separately. Historical independent offset fixtures,
provisional DM registration and detector settings must remain identified as
simulation inputs. This increment makes no physical, cadence or accelerator
qualification claim.

## Software checks and retained admission failure

The frozen Julia implementation passed 688 assertions across server, owner
options, acquisition and client checks. The primary agent separately repeated
524 server and 27 option assertions with bounds checks and deprecation errors.
The Python deployment suite passed 165 tests with two fixture-dependent skips
(167 discovered). Ten Rust configuration tests passed against main `7fe0bcd`,
including external raw-receipt admission and the retained restrictions on
row-block and owned endpoints. These are software checks, separate from live
acquisition evidence.

The first installed FGN attempt used a stale release binary
`762bc218700a016ffbb82391254df606e5146fe4e76ec75844231638953ef20f`.
It rejected the external detector-to-raw-recorder link before RTC admission.
The source had prepared and connected at sequence zero; no calibration exposure
was acquired. The failed stage and fault/shutdown records are retained under
`~/.cache/rtc-copper-calibration-capture-20261003/`, and every owned process
exited. This failed stage did not confirm reference restoration or release.

The emitted complete-frame session satisfies the existing source admission
rule. Rebuilding main without a validator change produced RTC binary
`96c115595811665061232c641e901be1856d7fb6577d4e9351372508439879d2`
and calibration client
`701443e1cd85912f12fcff6a3009c32019b054dd50f48cd261b472c3eacf6011`.
Fresh packages and a frozen prelaunch policy were created under
`~/.cache/rtc-copper-calibration-capture-20261003-v3/`; the rejected packages
were preserved. The policy SHA-256 is
`54d6ace77d23faa3265678a956f75b43c996de03606594576fd119244dbc8c29`.
Scientific nodes, startup arrays, plant settings and detector parameters were
preserved across this binary refresh.

## Observed installed capture, 2026-10-03

Both CPU packages passed the frozen four-exposure gate. The completed manifest
in each run contains generation 1, sequences 2–5, valid receipts, 2 ms exposure
durations and start model times of 100, 200, 300 and 400 ms. Sequence 1 was the
discarded normalization exposure; reference restoration completed sequence 6.
The adopted and restored 277-coordinate figure was zero µm OPD, without
clipping. Each capture contains exactly 90,384 payload bytes and all three
channels. Full acquisition UUIDs remain distinct between runs and are bound
to each manifest; the small opaque protocol domain is not used to conflate them.

| CPU engine | Startup to readiness | Capture/settle/restore/release | Public shutdown | Total stage |
| --- | ---: | ---: | ---: | ---: |
| FGN | 44.408 s | 14.365 s | 1.084 s | 59.860 s |
| JFG | 75.893 s | 13.815 s | 1.280 s | 90.991 s |

These are cold installed-stage wall times, including package loading and
compilation during startup. Acquisition includes the six completed model
exposures and protocol operations. The declared 100 ms model period and 2 ms
detector exposure do not establish a 10 Hz or 500 Hz wall cadence. The frozen
historical Copper fixture retains photon/read noise, 14-bit ADC, gain 1,
excess-noise factor 1 and 1 e⁻ read noise; it does not adopt the proposed DU860
instrument settings. The stationary lamp uses the public calibration plant
preparation, without atmospheric evolution.

Primary paired analysis verifies the actual raw payloads before comparing WFS
outputs. All four ADC arrays, reconstruction-pixel arrays and mean-intensity
values are byte-identical between engines: maximum and RMS differences are
zero for every channel. The 16,384 raw values span 0–60 ADC counts, current
intensities span approximately 26.974–27.235, and all pixels are finite.
These zero-held-command observations establish processing parity for this
corpus; they do not test a nonzero interaction response, linearity, observability
or clipping performance.

Both launchers exited zero after confirmed restoration, ownership release and
public stop/quit. Every recorded child PID is absent and both runtime instances
were removed. The successful rebuilt FGN run uses the same session, scientific
assets and Julia helpers as the retained rejected package, with only rebuilt
executables and their provenance changed. No source validator modification was
needed to resolve the admission failure.

The [independent review](COPPER_CALIBRATION_CAPTURE_REVIEW.md) and
[evidence ledger](COPPER_CALIBRATION_CAPTURE_EVIDENCE.json) bind source, policies,
package descriptors, failures, tests, receipts, all captured payloads and paired
analysis. The complete Copper calibration campaign, 277→253 controller map,
reference-centering contract, measured inverse acceptance and correction remain
open. Unchanged HEART and accelerator acquisition also remain unqualified by
this CPU increment.
