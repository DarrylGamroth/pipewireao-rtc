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
