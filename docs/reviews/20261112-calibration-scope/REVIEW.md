# RTC calibration and capture-file scope review

Reviewed RTC `88e9751` on 2026-11-12. This is a source and caller review.
It uses the checked-out instrument repository at `97fbb82`,
AdaptiveOpticsCalibration at `c7983df`, AdaptiveOpticsSim at `4f94e43e`,
AdaptiveOpticsSimPipeWireHIL at `f066db6`, PipeWireAO.jl at `ec57daf`,
and the GUI at `32a65c1`. The caller search covered maintained source,
tools, tests and authored YAML. It cannot establish use by external
clients or previously installed applications. Line counts are physical
source lines at the reviewed RTC revision.

## CAL-SCOPE-01 — Retire finite capture-file publication if the optional product can be dropped

**High confidence in the separation and observed caller inventory.
Requires a public feature decision.**

[CaptureFiles](../../../src/calibration/capture_files.jl) is 1,022 lines.
The [owner](../../../ext/calibration_owner.jl) creates a store only
when given a capture directory and stage. The [recipe parser](../../../src/calibration/recipe.jl)
admits the optional YAML channel list and byte budget. The owner consumes
the same exposures for ordinary Collect, but its Capture action writes
immutable payload files and returns a manifest descriptor. The only
in-tree callers of the file reader are tests. The instrument checkout
declares no capture section and its maintained tools and tests do not
call the reader or select a capture directory. The public Julia guide
still documents both ends of the file API.

The maintained Classic and pyramid [reference workflows](../../../ext/reference_calibration.jl)
use correlated Collect with a synchronous online consumer. The
[live collector](../../../ext/calibration_capture.jl), 630 lines, is
required by that path. It negotiates typed channels and matches their
exposures before rearming. Removing the writer does not eliminate this
collector or replace it with a generic stream read. HIL's
`prepare_pipewire_calibration` owns the simulated probe and publication
boundary. It does not supply the receiver's cross-port validation or an
evidence-file reader.

If the optional product can be retired, remove the entire CaptureFiles
module, capture-only owner setup and recipe fields. Retire the Capture
capability as a coordinated protocol change. Keep existing operation
IDs and define deterministic handling for a retired Capture request
on the wire. Audit capability advertisement, action client/server,
and frozen cross-language records together. RTC-DEV-029 and the
architecture currently describe the capability. Revise them with the
retirement decision. Keep the ordinary Collect path, including Copper
settling, restoration, and the unknown-outcome fence. Verify Classic
and GPI2 reference calibration and the action protocol. Preserve
already-published captures and the source needed to interpret them.

There is no schema-4 reader to remove. The current reader requires
schema 5, and [the schema-4 test](../../../test/test_calibration_capture_files.jl)
asserts rejection. Repository guidance that describes `Val(4)` as an
available reader is stale.

If the file product is still required, transfer the writer, reader
and their tests together once there is a consumer with that scope.
The inspected ArchiverService.jl
checkout, `38cbe00`, processes recorded messages and exports FITS.
No implementation of this bounded Capture request, selected ndarray
contract or completion-manifest handoff was found there. Adding an
archive service would not remove the need for a finite evidence
contract. No drop-in receiver was identified.

## CAL-SCOPE-02 — Retire the uninstalled acquisition CLI adapter

**High confidence in the packaging and observed caller inventory.
Public Julia entry point retirement.**

[CalibrationCLI](../../../src/calibration/cli.jl) is 148 lines. It wraps
the [Julia acquisition driver](../../../src/calibration/acquisition.jl)
with argument parsing, JSON output and an optional JSON-lines evidence
writer. The writer creates its evidence file before acquisition and
buffers completion records for finalization. This is distinct from the
retired session journal and its write-before-effect requirement.

The current app declaration and exporter do not install `rtc-calibrate`.
The maintained instrument tools invoke `InstrumentCalibration` directly.
The observed direct calls to `CalibrationCLI.main` are in RTC tests,
although the README lists the module and the acquisition guide still
describes the old launcher. Retire this adapter and its CLI-only tests
after confirming that supported external callers can use the Julia
driver and completion callback. Keep the reusable acquisition driver,
its correlation and restoration tests, and historical launcher evidence.
Validate the documented replacement with a maintained calibration path.

## CAL-SCOPE-03 — Move reference campaigns to the existing shared instrument tools

**High confidence in the ownership split. Transfer requires public API
work before the RTC files can be deleted.**

[Shack-Hartmann reference orchestration](../../../ext/reference_calibration.jl)
and [pyramid reference orchestration](../../../ext/pyramid_reference_calibration.jl)
total 1,639 lines. They select dark, lamp and qualification stages,
prepare the camera and frontend, drive calibration actions, accumulate
references through AdaptiveOpticsCalibration, and publish campaign products.
The instrument repository already owns the shared `tools/calibrate-references.jl`
entry point and the YAML choices. Move the campaign into that shared
tool layer and delete both RTC files together once its dependencies are
public. This needs no per-instrument Julia package. The shared tool
can depend on RTC and the science packages.

The transfer must account for `reference_stage` calling
`prepare_initial_calibration` and using prepared graph, owner and
exposure evidence. Identify the smallest public acquisition interface
that supports those callers. Reuse the existing endpoint and lifecycle
implementation. Keep the native endpoint, exact session admission and
Link ownership in their current owners. Keep estimator arithmetic in
AdaptiveOpticsCalibration. Keep simulated command adoption and exposure
publication in HIL. Verify Classic and GPI2 reference outputs, declared
commands and units, validity, restoration, and cleanup before removing
the old entry point. Carry external callers through an explicit migration
from `InstrumentCalibration.calibrate_references`.

[Calibration staging](../../../ext/calibration_staging.jl), 233 lines,
is a second candidate for the shared tool layer. The instrument
repository already has `tools/stage-calibration.jl`. Its RTC
implementation rewrites and validates a staged application and uses
exporter internals. Move the user-facing staging sequence only after
identifying the public export operations that can replace those calls.
Keep the [bundle reader](../../../src/calibration/bundle.jl) and
[materialization](../../../src/deployment/calibration_materialization.jl)
with deployment while they validate inputs for actual RTC export.
Verify fresh export and relocation with staged products.

## CAL-SCOPE-04 — Split offline optical calibration by responsibility before transferring it

**Confirmed mixed ownership. A whole-file move to the numerical package
would cross its documented scope.**

[Optical calibration](../../../ext/optical_calibration.jl) is 3,073
lines, with a further 906 in [the detector expectation path](../../../ext/optical_expectation.jl)
and 414 in [publication](../../../ext/optical_calibration_publication.jl).
The instrument repository already runs `tools/calibrate-optical.jl`.
Its application workflow belongs with those shared tools. The files
also mix simulation-only detector assumptions, graph preparation,
numerical projection and inversion, and deployment publication.

Start by separating the model expectation from the qualified detector
and frontend selection. The expectation directly uses AOS detector
configuration and a fixed ADC/noise envelope. AOS is the existing owner
for reusable detector-model expectations once they can consume its
public model inputs. Keep the qualified operating envelope with the
campaign. AdaptiveOpticsCalibration already supplies the probe-basis
and TSVD APIs invoked in this path. Transfer reusable math there
only as transport-neutral numerical operations. Keep FITS and
bundle publication with the tool, and retain RTC export-side artifact
admission. Compare the existing expected, measured and held-out paths
before transferring this cluster. No full-file drop-in replacement
was identified.

## Disposition

Start with the Capture feature decision and the independent CLI adapter.
Then move the reference campaigns as whole files through public interfaces.
The optical cluster needs a smaller ownership split before its application
workflow can move. This review changes no runtime source or requirements.
