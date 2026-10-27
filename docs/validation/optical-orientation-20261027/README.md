# Optical diagnostic orientation — 2026-10-27

The RTC 0.2.28 patch corrects the optional simulator wavefront and focal-plane
images. AOS reports increasing physical `[x,y]`; GUI images use `[row,column]`
with rows increasing down. Direct copying swapped physical axes on screen.
The publication boundary now transposes and reverses physical y so +x is right
and +y is up, matching owner-published DM positions.

Scientific arrays, camera frames, command vectors, calibration FITS, gains,
limits and raw-pupil RMS remain unchanged. The conversion uses preallocated
host products in the optional diagnostic worker, outside controller processing.
No instrument-specific renderer or GUI orientation override was added.

## Validation

Source fix `069da605` starts from RTC `8c6f1f0` (0.2.26). The
[versions](remediation-versions.json) and [commands](remediation-commands.json)
record exact scientific and transport sources.

- The same actual AOS 0.3.2 / HIL 0.2.7 isolated-actuator export probe fails
  8 of 20 assertions [before](actuator-fail-before.log) and passes all
  20 [after](actuator-pass-after.log). Physical +y now moves up and +x right.
- [Bounds-checked focused tests](pass-after.log) pass 39 assertions covering
  rectangular asymmetric arrays/masks, offset and strided views, source/RMS
  preservation, alias rejection and zero warmed allocation for both conversions.
- [Small SH/Pyramid prepared-owner checks](cpu-products.log) pass 80 assertions,
  including actual product formation and raw scientific-output preservation.
- Actual AOS focal metadata declares `PlaneAxisOrientation((:x,:y),(1,1))`;
  one-pixel source displacements validate the focal mapping independently.

The managed Classic transport/replay oracle was updated and syntax checked;
its complete live/private-core replay was not rerun. These are CPU software
checks, not hardware, fixed-rate latency or complete-system qualification.

## Deployment

Registered 0.2.26 / FGA 0.8.4 replacement is running on the CUDA plant. The
orientation patch is pending its registered consumer and installed rollout gate.
