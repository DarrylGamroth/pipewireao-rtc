# Independent source and arithmetic assessment

A separate Sol 6.1 reviewer traced HEART revision `973b20a` without changing
HEART, calibration files or live processes. It independently inspected the
offline script and JSON results after the first 98-check run. The primary then
added two command-map multiplicity checks and reran the selector: 100/100 pass.

The assessment confirmed the woofer linear inverse and negative slope, tweeter
polynomial endpoints and equal-voltage zero-range override, TT linear conversion,
and 1,948/81.919 × 0.01 = 0.23779587 phase-µm per driver call. It found no
incorrect arithmetic under the stated Float64 checked-in-data scope. This is
not bit-exact C-driver or inverse-LUT validation.

The addressed 48 × 48 crop centre (35.5, 32.5) is correct for zero-based offsets
(11, 8). It establishes command addressing, not optical pupil registration,
orientation or the currently illuminated actuator set. Map label coverage alone
would not establish multiplicity; the primary's two additional checks cover
positive-label count without claiming optical validation.

The conditional stage relation a = (D/2)θ is correct for normalized-pupil OPD
and sky angle. Applying it to a mechanical angle without an optical mapping
would be incorrect. The report preserves that angular distinction.

In a follow-up documentation search, the same reviewer found the explicit
HEART units authority: core `doc/hrtUnits.dox`, revision `02c85a6`, defines
DM commands as microns of wavefront. The primary independently read that source
and corrected the earlier unresolved framework-unit disposition. The remaining
calibration uncertainty concerns whether the legacy/deployed coefficient data
obey that contract, not what the documented framework command units mean.
No explicit mechanical-versus-sky TT definition was found in the inspected
core projection paths or GPI mode-selection files. MagAO-X's displacement-based
device boundary is a comparison, not evidence to change HEART's convention.

No narrowly inspected source declares the shipped calibration values fabricated,
but uniform coefficients do not prove measurement or deployment provenance.
The external controller clipping/flat files and actual installed device files
remain unavailable. Driver voltage endpoints do not establish effective
controller limits. The assessment supports leaving production limits and
calibration unchanged rather than guessing missing conventions.
