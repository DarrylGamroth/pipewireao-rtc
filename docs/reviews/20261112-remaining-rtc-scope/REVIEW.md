# Remaining RTC calibration and simulation export scope

Reviewed RTC `1e1b114`, instrument tools `355c139`, and
AdaptiveOpticsSimPipeWireHIL `f066db6`. This is a source and caller review.
The dispositions below are proposed. RTC-ARCH-026 keeps RTC responsible for
session admission and Links. RTC-DEV-029 keeps the acquisition protocol and
live calibration actions with their current owners.

## RTC-SCOPE-01 — Move offline interaction calibration and validation

**Confirmed transfer.** The instrument repository already owns
`tools/calibrate.jl` and `tools/validate-calibration.jl`. Both delegate their
campaign to RTC's [recipe dispatch](../../../src/calibration/recipe.jl).
The [Shack–Hartmann campaign](../../../ext/shack_hartmann_calibration.jl),
[modal campaign](../../../ext/modal_calibration.jl),
[Shack–Hartmann validation](../../../ext/shack_hartmann_validation.jl), and
[modal validation](../../../ext/modal_validation.jl) account for 1,092 lines
before extracting their shared helpers. They prepare a model, step it in process,
drive the estimator, and write or validate calibration products. The live
Collect owner has a separate path.

Move both procedures and their dispatch behind the existing shared instrument
launchers. Keep sensor and execution choices in the recipe YAML. Retain the
shared recipe and bundle readers for deployment and live preparation.
`calibration_settings` is also called by the staging tool to check the
prescription. Preserve that behavior when moving the Shack–Hartmann campaign.
`controller_graph` serves graph projection and shared reference and statistics
tools. The named `calibration_frame!` method serves the moved optical campaign.
Transfer the latter together with the scalar frame stepping interface only
after migrating those callers to a shared HIL or instrument-tool operation.
Keep the published campaign methods until the instrument launchers switch.

Verify Classic and GPI2 CPU parity with the same authored recipes and model
inputs. Compare matrices, rank, reference and held-out diagnostics, validate
the emitted bundles, and repeat Classic staging and a live reference selector
to check the shared contracts.

## RTC-SCOPE-02 — Move hidden-mode preparation and historical completion reading

**Confirmed transfer.** [Hidden-mode preparation](../../../ext/modal_hidden_modes.jl)
is 186 lines. The instrument repository's `tools/prepare-hidden-controller.jl`
calls it on a saved calibration. It validates the parent and derives two FITS
matrices from its RMS-weighted TSVD. Move the whole path behind that tool,
using the existing AdaptiveOpticsCalibration TSVD API and RTC's bundle reader.
Compare retained rank, projector and reconstruction residuals, parent hashes,
and typed parameter readback. Compare subspaces when equivalent singular
vectors differ in sign.

The public [historical completion reader](../../../src/calibration/instrument.jl)
`heart_completion` has callers in the inspected instrument calibration tests.
Move it with the historical comparison or retire it after confirming external
callers. Preserve archived inputs and their checks. The 149-line
[modal completion](../../../ext/modal_completion.jl) serves the modal campaign
and `tools/prepare-spiders.jl`. Move its recipe and geometry adapter with those
callers. Consider moving the array-only operation to AdaptiveOpticsCalibration
after comparing the coordinate, obstruction and actuator-health semantics.
Keep runtime command allocation and deployment artifact admission in RTC.

## RTC-SCOPE-03 — Move the standalone simulation bundle writer

**Confirmed boundary.** The 428-line
[standalone writer](../../../ext/aos/simulation_export.jl) resolves instrument
settings, emits graph YAML and typed FITS, copies compiled models, and publishes
the portable HIL manifest. Its public entry point is documented in the
[standalone configuration guide](../../HIL_CONFIGURATION.md). The inspected
maintained instrument tools do not call it. RTC's managed application exporter
has a separate path through `prepare_simulation_configuration!`.

Move portable manifest and asset writing to
`AdaptiveOpticsSimPipeWireHIL.Simulation`, beside its existing public loader
and preparation methods. Have the shared instrument tools resolve instrument
authoring into the writer's inputs. This keeps the standalone writer usable
without the RTC package and avoids importing RTC's instrument compiler into HIL.
Migrate the documented entry point and the three export selectors together.
Preserve schema 1 for lockstep and schema 2 for external-pupil and clocked
optical products. Verify relocation, typed bindings, compiled model hashes,
selected Proper loading, and a standalone consumer with no RTC dependency.
The standalone lockstep writer has no inspected production caller, but its
documented API and tested format warrant migration before any removal.

## RTC-SCOPE-04 — Consolidate the managed simulation configuration

**Confirmed shared dependency.** RTC's
[configuration module](../../../src/simulation/configuration.jl) and its
[external-pupil](../../../src/simulation/external_pupil_configuration.jl) and
[pupil-source](../../../src/simulation/pupil_source_configuration.jl) includes
total 1,219 lines. HIL's managed extension aliases `PipeWireAORTC.AOSOwner`
and calls its parser. RTC also reads the configuration for cold session Port
contracts, pacing checks, pupil composition and live simulated calibration.
The standalone manifest loader consumes a different format.

Move simulator-specific interpretation to HIL and expose the typed Port
contracts and preparation inputs needed by RTC. RTC should consume that
interface to generate and validate its own Nodes and Links. First establish a
lightweight parser API that preserves cold export without importing numerical
packages for ordinary profiles. Then switch the HIL managed extension and RTC
consumers together. Keep the current configuration formats until both users
migrate. Validate all managed profile exports, standalone relocation, and
CAL2/SPIDERS admission on private cores. Verify live simulated acquisition and
a retained deployed configuration against the same parser.

The [retired launcher check](../../../src/configuration/deployment_configuration.jl)
is the only remaining executable branch for `AOSOwner.main` in the inspected
RTC paths. It gives an explicit error for old owner argv. Remove that special
case only when the corresponding compatibility behavior is retired.

## Delivery order

Start with the offline calibration and validation transfer, then move
hidden-mode preparation. Transfer the standalone writer independently.
The managed configuration transfer follows an agreed HIL interface and
preserves RTC's cold export and live acquisition gates.
