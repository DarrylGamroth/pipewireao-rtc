# Native calibration cold preparation

## Bounded generated labels

The current frozen Copper FGN base at
`/tmp/copper-fgn-sdk-interrupt-final-v1-installed` passed its strict profile and
581 sealed artifact checks. Public `CalibrationExport.export_package` then
failed before producing an output: appending `-calibration` to the valid base
label exceeded the existing 40-character deployment name bound. The retained
[before log](copper-fgn-export-name-before.log) was produced from source
`943bfa9d9a6e5975c5d1db4ed0c0b455b748a441` on CPU15 without a science launch.

The generated calibration label now keeps the first 28 ASCII characters of the
already validated base label and adds `-calibration`. Short labels keep their
previous spelling. This applies to ordinary calibration exports and the
matching Copper HEART suffix path. Classic HEART retains its existing prefix
replacement. The label remains metadata; native PID, incarnation, UUID and
request authority are unchanged.

The focused cold fixture checks 1-, 28-, 29- and 40-character bases, exact prefix,
valid syntax, length, deterministic spelling and the corresponding HEART path.
It passed 28/28; see [after log](export-name-after.log). Correction already uses
its bounded, validated `profile-heart-backend-correction` label, so it needs no
production change. Its Classic/Copper CUDA spellings are checked in the same
fixture.

Package receipts below describe cold export/install and plan preflight only.
They do not establish SCI, action completion, scientific acceptance or hardware
qualification. Original packages and earlier receipts remain intact.
