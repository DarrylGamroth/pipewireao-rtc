# GPI2 mirror calibration and registration audit — 2026-10-26

Scope: read-only source/configuration inspection and CPU arithmetic. HEART stays
unchanged at `973b20af778949e62bd048c219cb872e8bb09d2b`. Instrument source is
`6949c2a`; RTC evidence starts from `054da19` on dedicated branch
`codex/gpi2-mirror-calibration-20261026`. No controller, plant, calibration,
geometry, GUI or service settings changed. This is not hardware qualification.

## Findings and disposition

| ID | Evidence and conclusion | Disposition |
| --- | --- | --- |
| GPMC-01 | HEART uses 97 woofer and 2,304 tweeter command channels. Its tweeter writer addresses a 48 × 48 subregion within the 64 × 64 hardware map. | Retain command dimensions; physical total and command region are separate quantities. |
| GPMC-02 | Checked-in driver calibrations imply woofer ±3.4 phase-µm, predominantly tweeter ±1.07 phase-µm, and TT ±1,820 mas. HEART documents DM commands as microns of wavefront. | The logical RTC boundary converts µm OPD → m OPD with scale 10⁻⁶. Legacy coefficient/deployment provenance and effective limits still require verification. |
| GPMC-03 | The tweeter calibration has five equal-voltage channels whose driver phase range is forced to zero, plus two other exceptional channels. | Preserve per-actuator limits in any future import; do not infer present physical health or replace all limits with one number. |
| GPMC-04 | Command crop position is recoverable, but current optical pupil registration and controlled/extrapolated masks are not established by the command maps or screenshot. | Preserve provisional registration pending an optical calibration/pupil prescription. |
| GPMC-05 | Controller and driver clipping/slew are separate. The selected controller template references external woofer clipping and flat files absent from the HEART checkout. | Driver voltage endpoints alone cannot recreate effective controller constraints. |

## Commands and addressing

The user-provided calibration image explicitly displays 97 and 2,304 actuators.
This agrees with HEART's `gpi2config.yaml` PDM sizes and command-map labels.
The tweeter writer uses zero-based offsets x=11, y=8 to map its 48 × 48 input
through the full 64 × 64 hardware lookup table. Its addressed subarray centre is
therefore (35.5, 32.5) in one-based coordinates. The public original-GPI
[coronagraph documentation](https://docs.planetimager.org/pipeline/gpireference/coronagraph.html)
reports that same primary-pupil centre. This agreement supports the crop
interpretation; it does not independently calibrate optical orientation or
current GPI2 pupil registration.
The same 48 × 48 subregion is explicitly described in Duan Li's 2025 Cornell
[dissertation, pp. 71–72](https://sioslab.com/wp-content/uploads/2025/11/Li-2025-Focal-Plane-Wavefront-Sensing-and-Control-for-Various-Optical-Systems.pdf).

Sources: [configuration, lines 486–502](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/template/config/gpi2config.yaml:486),
[crop offsets](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/devices/src/dpioTweeterHandler.c:94),
[hardware conversion](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/devices/src/dpioTweeterHandler.c:1047).
The woofer driver separately retains the legacy 69-active-channel/9 × 9 path
and a full 97-channel path; 69 is not evidence that the full mirror has only
69 physical actuators. Comments contain stale counts, so executable sizes and
configured paths take precedence.

## Calibration equations and arithmetic

Here μ means the driver's stated **microns of phase**. HEART core's
[physical-units document](/home/dgamroth/workspaces/codex/heart/heart/doc/hrtUnits.dox:13)
at revision `02c85a6490f33b057f1d0410a6c9db1564ae57b0` explicitly defines both
wavefront error and DM commands as microns of wavefront. This establishes the
framework contract as wavefront length/OPD, not mirror-surface displacement.
The logical conversion to our m-OPD command interface is therefore 10⁻⁶, without
an additional reflection factor. It does not independently certify the physical
origin of legacy device coefficient files. θ means the driver's stated **mas**,
not an asserted mechanical or sky angle. Values below describe checked-in CSVs,
not confirmed installed files.
Device and template-handler versions match numerically and in file hashes.

| Device | File equation | Derived endpoint range |
| --- | --- | --- |
| Woofer, all 97 | μ = 0 − 0.01V, with V ∈ [−340, 340] | μ ∈ [−3.4, 3.4]; positive μ requires negative V |
| Tweeter, 2,297 channels | μ ≈ −1.07000005 + 0.00005350000356V², V ∈ [0, 200] | μ ≈ [−1.07, 1.07] |
| TT, both axes | θ = 182V, V ∈ [−10, 10] | θ ∈ [−1,820, 1,820] mas |

The tweeter startup overrides polynomial evaluation for equal voltage endpoints,
giving zero phase range to zero-based command indices 323, 385, 1030, 1577 and
1932. Index 879 has 75–95 V and about −0.08595…+0.09669 phase-µm; index 1656
has about −0.47…+1.67 phase-µm. These indices describe the checked-in command
calibration, not an independently verified current bad-actuator map.

Woofer initialization inverts the linear relationship, despite the file's
`PhaseToVoltsCoeff` name. Its third coefficient is loaded but unused. The
negative slope reverses the meanings of endpoints named `MinMicrons` and
`MaxMicrons`; sorting the physical interval is necessary when reporting it.
Tweeter startup builds an inverse LUT. Its endpoint index scaling uses N−1
while table phase steps use N (N=16,192); the CPU endpoint calculation here is
not a bit-exact emulation of that LUT or its C Float32 arithmetic.

Sources: [woofer initialization](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/devices/src/dpioWooferTTHandler.c:1422),
[tweeter initialization](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/devices/src/dpioTweeterHandler.c:465),
[TT conversion](/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc/source/devices/src/dpioWooferTTHandler.c:905).
The public [GPI calibration documentation](https://docs.planetimager.org/gpilib/aoc/aoc_calibration_files.html#twt-phs-vlt)
explicitly records historical uncertainty about phase versus surface calibration.
That older device-calibration caveat does not supersede HEART's explicit
framework convention, but it remains relevant when validating the legacy
coefficients against an optical measurement.

For comparison, MagAO-X's
[ALPAO controller](https://magao-x.org/docs/api/alpaoCtrl_8hpp_source.html) describes
conversion from micron displacement to normalized SDK stroke, and its
[BMC controller](https://magao-x.org/docs/api/bmcCtrl_8hpp_source.html) converts a
calibrated displacement representation into squared fractional voltage before
taking a square root. The inspected local source is revision
`66a6087f7c4dbb7197468c43c9259d3e8b0350d3`. Its
[surface characterization paper](https://magao-x.org/publications/media/2018SPIE10703E..5AV/manuscript.pdf)
explicitly measures DM surfaces. This illustrates a different device-boundary
representation; it cannot redefine HEART's documented wavefront command units.

## Effective limits, slew and feedback boundaries

The upstream controller template names `/home/software/config/gpi2WfrMaxMinLimit.csv`
and an external `NEW_woofer_flat.fits`; neither was found in the HEART tree.
It enables upstream woofer slew with 0.2378 per update and an initial value of
3.4, but the device-handler configuration disables its own slew clamp. Driver
code limits DN increments by 1,948 per call when enabled. Using the checked-in
slope and 81.919 DN/V gives 0.23779587 phase-µm per call, agreeing with the
upstream numeric value. This does not define a rate per second: actual update
cadence and skipped updates matter. No elapsed-time enforcement is inferred.

Controller TT clipping is separately set to ±1.0 without a local unit annotation.
Driver endpoint values therefore are not equivalent to configured controller
limits. The conversion routines do not themselves supply phase-domain
anti-windup feedback. Tweeter writing returns before hardware transfer when its
conversion reports clipping, so its behavior must not be summarized as always
applying a saturated command.

The current simulator stage bound is ±1 µm for coefficient a of OPD=a·x, where
x is normalized by pupil radius R=7.77/2 m. Thus its equivalent sky deflection
is θ=a/R, or ±53.09 mas. **Only if** the driver's ±1,820 mas denotes sky angle,
the corresponding coefficient would be ±34.28 µm OPD. This conditional
comparison neither authorizes that bound nor demonstrates the cause of current
woofer/tweeter clipping. Mechanical stage angle requires an optical mapping.

The focused HEART search did not resolve TT's angular frame. Its core applies
configured VDM→TT and TT→PDM matrices and forwards commands to the device
handler. GPI's mode selector picks coordinates 0 and 1 with unit coefficients;
the configured external woofer projection and `ttToPdm0_rand.fits` do not supply
a documented physical angular calibration. Thus the user's tentative stage-motion
interpretation and an on-sky interpretation remain hypotheses, not established
facts. The unit mas alone settles angular scale, not the reference frame.

## Pupil registration

The current instrument uses 10 actuator pitches across the woofer pupil diameter
and 43 across the tweeter diameter. A count of actuator centres across a pupil
is not identical to the number of pitches. The
[original-GPI paper's](https://soul.arcetri.inaf.it/proceedings/fulltext_16014.pdf) roughly
nine woofer actuators across the illuminated pupil and older 69-active path
warrant checking the woofer registration, but do not establish a new GPI2 pitch
from the 97-channel display alone. Neither manufacturer useful aperture nor
the number of command cells uniquely supplies the illuminated footprint.

## Verification and remaining evidence

`check-calibration.jl` passes **100/100 CPU arithmetic/data checks** with Julia
1.13.2: CSV shape/finiteness, matching device/template values, polynomial
endpoints, special channels, map label coverage/multiplicity, crop arithmetic,
slew conversion and the conditional stage conversion. `result.json` records
source hashes and unresolved conventions; `check.log` records the result.
Independent source/arithmetic review found no numerical error within this
scope. It emphasized that command addressing does not prove optical registration.

Reproduce without a core, simulator or GPU:

```sh
julia --startup-file=no --project=/path/to/json-yaml-environment \
  check-calibration.jl /path/to/heart/gpi2.0-rtc /path/to/heart/heart \
  /path/to/instruments/gpi2 result.json
```

Before adopting physical constraints, obtain the actual deployed clipping/flat
and device calibration files, verify legacy coefficients against HEART's known
wavefront convention, resolve TT's angular frame, and establish the illuminated
footprint and controlled/slaved mask.
Then validate one signed known-amplitude command against an independently
calibrated optical measurement, followed by matched simulation replays. Until
then the existing limits and registration remain explicitly provisional.
