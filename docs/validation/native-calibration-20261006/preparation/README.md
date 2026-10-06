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

## Prepared packages

- Classic FGN: `/tmp/classic-fgn-nativecal-final-v2-installed`;
  [receipt](classic-fgn-nativecal-final-v2-receipt.json). This earlier package
  retains its original receipt and explicit provenance metadata exception.
- Copper FGN: `/tmp/copper-fgn-nativecal-final-v2-installed`;
  [receipt](copper-fgn-nativecal-final-v2-receipt.json),
  [scientific byte ledger](copper-fgn-nativecal-scientific-ledger.json), and
  [successful cold export log](copper-fgn-nativecal-final-v1-prepare-after.log).
  The same frozen base now passes public export after the bounded label fix.
  All 581 original base seals remain intact, all 355 retained scientific files
  match their originals, and all 565 installed artifact seals pass.

The Copper action caller uses the existing plan SHA
`043cfdaef6896fbf09ed2a477a771026cb7045f4cf8b8aa68bf1a14deb990fc5`:
run 1, two probes, two frames each, 277 physical coordinates and 3600
measurements. The encoded Collect reply preflight is 14,904 bytes with an empty
message. Two-frame Capture requires 45,192 payload bytes, exactly its sealed
budget. Neither preflight executes an action. This is a CUDA action fixture;
it does not transfer the old CPU plan's scientific acceptance to CUDA.

### Generated control SDK binding

The public export initially copied a control `julia/Manifest.toml` selecting
registry PipeWireAO 0.6.16 tree `09c5b1a7cf7869dcf9c252651e7c9569bf7bcbdb`,
while its HIL Manifest selected the sealed staged SDK with reviewed source
revision `d514d6b0d76a1dcac359ec23943876343b7bb205`. Version equality does not
establish source identity. This production package binding limitation remains;
the label fix does not correct it.

For this owned generated stage only, the parent authorised the existing v2
refresh helper's binding policy: remove the registry source fields and set
`path = "../hil/packages/PipeWireAO"`, then reseal and install to the fresh v2
path. See the [normalisation helper](normalize_copper_fgn_nativecal_runtime_v2-20261006.jl)
and [log](copper-fgn-nativecal-final-v2-normalize.log). The actual cold installed
SDK import resolved to that sealed path and its thread-loop SHA
`d622115599605017b251addf6f23c96d85c272d3c360c46b4048f2fb7eaed420`;
see [loaded SDK proof](copper-fgn-nativecal-final-v2-loaded-sdk.log).

The unnormalised v1 install was closed and had never run SCI. With explicit
parent authorisation it was losslessly archived, every one of its 655 entries
verified for file SHA, mode, link target, UID/GID and exact modification time,
then only its uncompressed duplicate removed. The archive, restore ledger,
pre-normalisation Manifest, full proof and logs remain at the exact paths and
hashes recorded in the receipt. The original frozen base was never changed.

The task-owned stage, v2 install, archive and receipts total 54,800,420 bytes,
below the 60 MB preparation limit. The receipt records free space and the
unchanged runner SHA `750059d1ee71783b63d1fbb96a6bc92cd9be436f551d1b450688a6aae2c2d5cb`,
calibration CLI SHA, qualifier source and both exact future Collect/Capture
argument vectors. **Those commands require the parent's SCI reservation and
have not been executed.** No correction or remaining-profile package was
prepared in this increment.
