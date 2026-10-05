# PipeWireAO RTC document set

The maintained baseline starts with one non-actuating, complete-frame
FGN/PipeWireAO development graph, then extends the same runner into a
small RTC workstation (RTCW) that can compose multiple ordinary PipeWireAO
filter-graph instances. The runner loads, links, inspects, and tests the
declared session without introducing another graph-authoring format.

## Active documents

| Document | Authority |
| --- | --- |
| [Development architecture](architecture.md) | RTCW composition, scientist boundary, external-node substitution, laboratory placement, and the selected deployment package |
| [Development operating contract](operations.md) | RTC-DEV-001 through RTC-DEV-029: lifecycle, composition, updates, equivalence, placement, installed profiles, simulated calibration, bounded control and user-service operation |
| [Development roadmap](roadmap.md) | Dependency-ordered implementation, completion evidence, performance characterization, and deferred capability triggers |

These three files are the complete RTC-level implementation baseline. An
implementation task should not load the archive unless it is explicitly
promoting a deferred capability.

[Deployment review](DEPLOYMENT_REVIEW.md) records the independent review and
implementation prerequisites. It is evidence and design input; the active
requirements below govern implementation.

[Deployment validation](DEPLOYMENT_VALIDATION.md) records the completed
recorded-input increment and its functional qualification limits.

[Recorded-FITS restart correction](UI_RESTART_ISSUE_1.md) and its
[independent review](UI_RESTART_REVIEW.md) record the discard-counter caching
defect, focused RTC correction and Classic/Copper client/lifecycle regressions
under RTC-DEV-004, RTC-DEV-011 and RTC-DEV-022.

[AOS/HIL deployment](HIL_DEPLOYMENT_VALIDATION.md) gives export, launch and
control instructions and separates backend preparation from installed live
qualification. [HIL review](HIL_DEPLOYMENT_REVIEW.md) tracks confirmed defects
and remaining acceptance evidence.

[HEART HIL validation](HEART_HIL_VALIDATION.md) records the installed Classic/Copper
CPU bridge checks, packet-level evidence and remaining physical/scientific
limits. [HEART HIL review](HEART_HIL_REVIEW.md) records independent findings;
the [evidence summary](HEART_HIL_EVIDENCE.json) preserves measured artifact identities.

[Calibration coordinator review](CALIBRATION_COORDINATOR_REVIEW.md) records the
completion-event acquisition core, independent findings and remaining endpoint
integration gates. It does not establish operational calibration support.

[Julia calibration migration](JULIA_CALIBRATION_MIGRATION.md) records the selected
production language boundary and completed replacement gates; its delivery
record retains the historical Python evidence.
The selected operational entrypoints and their installed dependencies now use
Julia; scientific calibration acceptance remains separate.

[Calibration endpoint evidence](CALIBRATION_ENDPOINT_EVIDENCE.json) records
the initial graph preparation, held-probe transport checks, independently
reviewed native buffer-return fix, exact source identities and remaining
operational calibration gates.

[Calibration acquisition validation](CALIBRATION_ACQUISITION_VALIDATION.md)
records the native Classic FGN/JFG full cycles, explicit simulated selection,
noise discriminator and remaining scientific/deployment gates.

[Automatic Classic campaign](CALIBRATION_CAMPAIGN_USAGE.md) documents the
finite dark/reference/qualification/interaction workflow. Its
[validation](CALIBRATION_CAMPAIGN_VALIDATION.md),
[independent review](CALIBRATION_CAMPAIGN_REVIEW.md) and
[evidence identities](CALIBRATION_CAMPAIGN_EVIDENCE.json) separate functional
completion from remaining scientific and exact-trajectory acceptance.

[Classic calibration quality](ANALYSIS_PLAN.md) tracks the next precision,
coordinate-composition and correction gates. Its
[source and dependency provenance](CALIBRATION_PROVENANCE.md) records reuse
constraints and unresolved license metadata separately from numerical evidence.
The [measured-offset export review](CALIBRATION_OFFSET_REVIEW.md) records the
import boundary and its independently verified recipe-validation correction.
The [quality review](CALIBRATION_QUALITY_REVIEW.md) records numerical findings
and the predeclared held-out acceptance plan.
[Quality validation](CALIBRATION_QUALITY_VALIDATION.md) and its
[evidence identities](CALIBRATION_QUALITY_EVIDENCE.json) separate the measured
matrix, frozen held-out decision and correction checks.
[Method measurements](CALIBRATION_METHOD_VALIDATION.md) records the bounded dense
pattern screens and completed physical/controller-modal/spatial comparisons.
[Selectable calibration usage](CALIBRATION_METHOD_USAGE.md) describes the maintained
method acquisition and unaccepted-candidate boundary. The
[correction review](CORRECTION_ANALYSIS_REVIEW.md) preserves failed replay gates
and their dispositions. The [method comparison](CALIBRATION_METHOD_COMPARISON.md)
records the zonal/Hadamard/controller-modal/spatial design and independent audits.
[Fresh method selection](CALIBRATION_METHOD_SELECTION.md) records the frozen
common controller decision, selected-only locked test and deployed FGN/JFG
correction checks for the 206-mode Hadamard inverse.
[Copper capture](COPPER_CALIBRATION_CAPTURE.md) and its
[independent review](COPPER_CALIBRATION_CAPTURE_REVIEW.md) describe the completed
bounded CPU endpoint extension, separate from Copper matrix acceptance. Its
[evidence identities](COPPER_CALIBRATION_CAPTURE_EVIDENCE.json) preserve the
failed stale-binary admission and successful FGN/JFG captures.

[Copper reference candidates](COPPER_REFERENCE_USAGE.md), their
[validation](COPPER_REFERENCE_VALIDATION.md),
[independent review](COPPER_REFERENCE_REVIEW.md) and
[evidence identities](COPPER_REFERENCE_EVIDENCE.json) record the measured
dark/lamp/fresh-reference workflow. Byte-identical paired CPU results are
functional evidence; Copper scientific reference and matrix acceptance remain
open.

[Copper amplitude and precision pilot](COPPER_QUALITY_USAGE.md), its
[predeclared plan](COPPER_QUALITY_PLAN.md),
[validation](COPPER_QUALITY_VALIDATION.md),
[independent review](COPPER_QUALITY_REVIEW.md) and
[evidence identities](COPPER_QUALITY_EVIDENCE.json) record the completed bounded
FGN/JFG directional collection. The paired measurements/products match exactly;
the pilot does not establish adequate precision for full-matrix admission.

[Calibration completion plan](CALIBRATION_COMPLETION_PLAN.md),
[measured evidence](CALIBRATION_COMPLETION_VALIDATION.md) and
[independent review](CALIBRATION_COMPLETION_REVIEW.md) track the brighter noisy
detector cohort, matched methods, held-out inverse selection, deployed correction
and completion of all five selected finite simulation gates. The
[HEART calibration adapter](HEART_CALIBRATION_ADAPTER.md) distinguishes held
command acquisition from ordinary closed-loop operation and records the selected
native ingress mode. Finite simulation results do not qualify physical devices
or wall-clock cadence.

[Prepared exchange delivery](PREPARED_EXCHANGE_DELIVERY.md) records the native
JLL ownership fix, release of the prepared Julia API and generic CCR-006
private-core qualification separately from those scientific cohorts.

[Sustained HIL plan](SUSTAINED_HIL_PLAN.md) defines the bounded Classic/Copper
complete-frame extension. The [usage guide](SUSTAINED_HIL_USAGE.md) describes
installed options, reports and measurement scope. Its [independent review](SUSTAINED_HIL_REVIEW.md)
separates continuous delivery, clipping feedback, simulator allocations and
cadence evidence from the earlier finite scientific checks. The
[evidence ledger](SUSTAINED_HIL_EVIDENCE.json) seals completed campaign reports
and records the remaining midrun-control and qualification limits.

## Julia operational deployment

The [Julia package structure review](JULIA_PACKAGE_STRUCTURE_REVIEW.md) distinguishes
the former include-loaded application from a named package and records the
resource/provenance contracts. The
[package remediation](JULIA_PACKAGE_REMEDIATION.md) and
[independent review](JULIA_PACKAGE_REMEDIATION_REVIEW.md) record the named package,
SDK relocation, installer corrections and selected installed qualification.

The [Julia operational deployment usage](JULIA_DEPLOYMENT_USAGE.md),
[migration plan](JULIA_CALIBRATION_MIGRATION.md),
[delivery record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md) and
[independent review](JULIA_CALIBRATION_MIGRATION_REVIEW.md) track the operational
language boundary and completed selected installed qualification. The
[evidence ledger](JULIA_CALIBRATION_MIGRATION_EVIDENCE.json) binds tested sources
and results. Selected finite simulation calibration gates are complete; physical,
ordinary Copper streaming and wall-clock rate qualification remain separate.
Historical Python evidence continues to identify its original producer.

## Inactive design archive

The [archived full-RTC design](archive/full-rtc/README.md) preserves prior work
on physical cameras and deformable mirrors, protected authority, recording and
reconstruction, Julia execution, remote clients, progressive scheduling, and
target-host qualification. It is non-normative and not a delivery commitment.
Its historical identifiers remain reserved and are not selected.

## Lower-level authorities

Generic ndarray, FGN, metadata, polling, row-block, and progressive-processing
contracts remain authoritative in the
[PipeWireAO repository](https://github.com/DarrylGamroth/PipeWireAO/tree/master/doc/dox/internals).
Portable scientific Algorithm implementations and declarations remain
authoritative in their owning packages. This repository states only the RTC
runner behavior that connects those pieces.
