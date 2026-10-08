# Delivery evidence catalog

- [Python tooling removal, 2026-10-08](PYTHON_REMOVAL.md): removed obsolete scripts, preserved historical source/results and checked the existing Julia SDK. No new live or timing qualification.

- [Installed AO runtime, 2026-10-08](validation/installed-runtime-20261008/README.md): `/opt/pipewireao` builds, installed-default manager export, Copper CPU FGN/JFG with CUDA AOS loading/controls/cleanup, independent review and test synchronization corrections.

- [Ordinary systemd session startup, 2026-10-07–08](validation/systemd-session-startup-20261007/README.md): generated owner services/target, literal arguments, cleanup recovery, selected Copper FGN/JFG native lifecycle/control checks and independent review.

- [Main integration and cleanup, 2026-10-07](validation/main-cleanup-20261007/README.md): fork main/master merges, private GUI repository, obsolete worktree and installed-snapshot cleanup.

Catalog preserved from the documentation index on 2026-10-06.
Descriptions below refer to their named revisions and cohorts; historical
“pending” or “complete” statements are not current project status. Start with
[the task index](README.md) and [current work](roadmap.md#current-work).
Load a record only when its requirement, finding or evidence is relevant.
The catalog is not a requirement or an acceptance claim. Original review and
validation files, logs and receipts remain at their existing paths.

[Main integration](MAIN_INTEGRATION_20261006.md) records the 2026-10-06 source
merge, paired SDK dependency, GUI handoff evidence and remaining qualification
gates. It does not declare deployment or scientific qualification complete.

[Application architecture adversarial review](APPLICATION_ARCHITECTURE_REVIEW.md)
records independent system/real-time reviews, their consolidated dispositions,
and the resulting ownership and migration recommendations. It is source review,
not new runtime, timing or hardware qualification.

[WirePlumber session independent review](validation/wireplumber-session-20261007/REVIEW.md)
records WPS-01–08 documentation dispositions and WPI implementation findings
for RTC-ARCH-025. Source review does not close runtime gates.

[WirePlumber session checks](validation/wireplumber-session-20261007/SESSION_CHECKS.md)
records Copper FGN/JFG installed admission, controls, retained scientific
prefixes, coordinator-free SDK readmission, GUI read-only selection and scoped
loss/Quit cleanup. It also links preserved original failures and open gates.

[Native WirePlumber module-load check](validation/wireplumber-session-20261007/MODULE_LOAD.md)
records fail-before/pass-after dependency loading and client-node export, followed
by a typed Warmup reply. Scientific lifecycle and resource admission are unqualified.

[WirePlumber compatibility, 2026-10-06](validation/wireplumber-compatibility-20261006/README.md)
records the isolated complete-frame NDArray fixture, exact delivery and basic
link cleanup. It does not qualify RTC/AOS admission or transfer ownership.

[Copper WirePlumber/HIL coexistence, 2026-10-06](validation/wireplumber-hil-coexistence-20261006/README.md)
records CPU FGN/JFG with CUDA AOS, held discovery, native stop/reset/resume,
two 512-command runs per executor, exact 256-frame baseline/reset prefixes and
preserved runtime-owned links after optional WirePlumber loss. Simulator tails
report zero Julia heap allocation/GC. Required-owner failure, process/link
ownership transfer and rate/latency qualification remain separate.

[Optional WirePlumber user service, 2026-10-07](validation/wireplumber-user-service-20261007/README.md)
records the installed Copper observer companion for CPU FGN/JFG with CUDA AOS.
Both executors pass automatic observer restart with the existing RTC unit,
observer stop/death independence, two 512-exchange incarnations, exact retained
baseline prefixes, zero simulator heap/GC tails and cleanup after whole-cohort
exit. It does not transfer link/scientific ownership or newly qualify isolated
required-owner loss, multiple endpoints, release packaging or rate/latency.

[Declared connection policy and required loss, 2026-10-07](validation/wireplumber-connection-policy-20261007/README.md)
records the required-link monitor's fail-before/pass-after tests, removal-latched
external incarnations, configured native Format/passive/owner checks and both
Copper CPU executor paths with CUDA AOS. Required-link/simulator loss, owned
cleanup and fresh admission pass with exact retained baseline prefixes and zero
simulator heap/GC tails. Preserved fault diagnostics limit the claim to bounded
cleanup. Link ownership transfer, graceful fault shutdown and general multi-output
AOS execution remain unqualified. Independent review and exact hashes are included.

[Source fault teardown, 2026-10-07](validation/fault-teardown-20261007/README.md)
records source-group revocation, core-first fallback and private report warmup
corrections with fail-before/pass-after software evidence. Copper CPU FGN/JFG
with CUDA AOS pass required-link/simulator loss, surviving-owner exit,
final living-source report publication and owned cleanup. Fresh admission passes
two 512-command runs per executor, exact retained baseline prefixes and zero
simulator Julia heap/GC tails. Expected native/transport errors remain visible;
no fault-time pause acknowledgement, revocation-latency, link/process ownership
transfer, general multi-output or physical-actuation claim follows. Checked hashes
and independent review are retained.

[Installed Copper qualification, 2026-10-06](validation/copper-main-20261006/README.md)
records refreshed main-runtime/SDK detector and DM trajectories, observer
death/replacement and stall, simulator Julia heap counters and independent
review. It also records the fixed Classic calibration startup defect, the dim
fixture's preserved Collect failure, and passed Collect/Capture with the
recorded recipe's illumination. No maximum-rate or optical-truth claim follows
from these checks.

The pre-RTC-ARCH-025 implementation baseline starts with one non-actuating, complete-frame
FGN/PipeWireAO development graph, then extends the same runner into a
small RTC workstation (RTCW) that can compose multiple ordinary PipeWireAO
filter-graph instances. The runner loads, links, inspects, and tests the
declared session without introducing another graph-authoring format. See
[RTC-ARCH-025](WIREPLUMBER_SESSION_DESIGN.md) for current session ownership and
the migration gates.

## Active documents

| Document | Authority |
| --- | --- |
| [Development architecture](architecture.md) | RTCW composition, scientist boundary, external-node substitution, laboratory placement, and the selected deployment package |
| [Development operating contract](operations.md) | RTC-DEV-001 through RTC-DEV-030: lifecycle, composition, updates, equivalence, placement, installed profiles, simulated calibration, bounded control and user-service operation |
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
The [Python live-control CLI retirement](PYTHON_LIVE_CONTROL_RETIREMENT.md)
records the bounded fail-closed entrypoints and the legacy fixture APIs that
remain available to tests.

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

[Native simulator controls](LIVE_CONTROL_NATIVE.md), the
[allocation plan](LIVE_CONTROL_ALLOCATION_PLAN.md) and
[independent review](LIVE_CONTROL_REVIEW.md) and
[validation](LIVE_CONTROL_VALIDATION.md) record the selected SPA parameter
transport and its separate installed midrun-control qualification. Saved JSON
reports remain artifacts. Selected supervisor and calibration controls now use
native transport; fresh integrated installed qualification remains separate.

[Native control migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md), its
[inventory](LIVE_CONTROL_INVENTORY.md),
[mechanism proof](NATIVE_CONTROL_FILTER_PROOF.md) and
[independent review](NATIVE_CONTROL_MIGRATION_REVIEW.md) document the selected
RTC-ARCH-024 / RTC-DEV-030 transport increment. The three active documents
above remain the normative authority. The [fixed envelope](NATIVE_CONTROL_ENVELOPE.md),
[codec review](NATIVE_CONTROL_CODEC_REVIEW.md) and
[CPU validation](NATIVE_CONTROL_ENVELOPE_VALIDATION.md) record the common header
and diagnostic interoperability separately from production owner migration.
[Local RTC session discovery](NATIVE_SESSION_DISCOVERY.md) defines the bounded
per-user native locator record and fresh-status selection boundary. The
[publication and operator validation](NATIVE_SESSION_DEPLOYMENT_VALIDATION.md)
records actual supervisor publication, independent duplicate-name sessions,
fresh Julia CLI selection and explicit private-runtime bindings. GUI and
installed scientific qualifications remain separate; the
[integration handoff](DISCOVERY_INTEGRATION_HANDOFF.md) identifies those gates.

[Calibration report publication](NATIVE_REPORT_PUBLICATION_VALIDATION.md) records
the stale-generation rejection and migration of the selected campaign and HEART
export consumers to fresh native completion before reading saved reports.

[Native deployment bootstrap](NATIVE_DEPLOYMENT_BOOTSTRAP_VALIDATION.md) records
actual public-control fixture corrections, locator alias retirement and
post-exit report verification with the captured launcher PID.

The [synchronization prerequisite](NATIVE_CONTROL_SYNC_VALIDATION.md) and its
[independent review](NATIVE_CONTROL_SYNC_REVIEW.md) record the corrected inner
wait and stalled-core evidence, separately from native runner ingress.
The [runner request profile](NATIVE_RUNNER_CONTROL.md), its
[independent review](NATIVE_RUNNER_CONTROL_REVIEW.md) and
[validation](NATIVE_RUNNER_CONTROL_VALIDATION.md) record closed typed dispatcher
results and exact native request encoding. The subsequent
[endpoint validation](NATIVE_RUNNER_ENDPOINT_VALIDATION.md) and
[endpoint review](NATIVE_RUNNER_ENDPOINT_REVIEW.md) record actual caller
admission, lifecycle and cleanup checks; migration of remaining production callers and
other owners remains open.
The [native runner client validation](NATIVE_RUNNER_CLIENT_VALIDATION.md) and
[independent client review](NATIVE_RUNNER_CLIENT_REVIEW.md) record the implemented
supervisor-to-runner hop. HEART, calibration, public operator and remaining live
readiness/status-file controls are still awaiting migration.
The [sealed source/evidence identities](NATIVE_RUNNER_CONTROL_EVIDENCE.json)
bind the passing runner/caller checks and preserve their remaining limits.
The [HEART profile](NATIVE_HEART_CONTROL.md),
[connected client tests](NATIVE_HEART_CLIENT_VALIDATION.md),
[unchanged vendor process checks](NATIVE_HEART_VENDOR_VALIDATION.md) and
[independent review](NATIVE_HEART_REVIEW.md) record wrapper preparation,
connection, reset, health and shutdown migration separately from pending
installed HIL caller qualification.
The [acquisition lifecycle codec contract](NATIVE_ACQUISITION_LIFECYCLE_CONTROL.md)
records the bounded calibration and correction phase D foundation; owner
integration remains pending.
The [cold lifecycle helper API](NATIVE_ACQUISITION_LIFECYCLE_HELPERS.md) records
the runtime/client transport boundary and private-core fixture evidence.
The [public supervisor codec foundation](NATIVE_SUPERVISOR_CONTROL.md) records
the separate public profile, combined typed owner status, mutation reply capacity
reservation and shared Julia/Rust fixtures. Public runtime ingress is implemented;
its installed qualification is separate. The [current retirement inventory](LIVE_CONTROL_INVENTORY.md)
and [actual private-core validation](LIVE_CONTROL_RETIREMENT_PRIVATE_CORE_VALIDATION.md)
record selected paths and retired ingress. [Fresh foreground qualification](NATIVE_FINAL_FOREGROUND_VALIDATION.md)
passes four native FGN/JFG reset compositions; [remaining integrated checks](NATIVE_FINAL_QUALIFICATION_PLAN.md)
include services, calibration, HEART and observation.

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

[Installed Julia executable validation](JULIA_SYSTEMD_RUNTIME_VALIDATION.md)
records issue #2, absolute runtime selection for every installed wrapper,
minimal-PATH foreground/static-user-unit checks, and the adjacent owned-accept
SIGINT correction. Its [evidence ledger](JULIA_SYSTEMD_RUNTIME_EVIDENCE.json)
keeps executable lookup and functional cleanup separate from scientific claims.

## Artifact update allocation checks

The [2026-10-06 artifact/update checks](validation/live-artifact-updates-20261006/README.md)
retain warmed zero-allocation adoption probes, the repaired native GUI test and
four passing Copper CPU FGN/JFG baseline/update runs with CUDA AOS. Each delivers
512 commands through live gain/reconstructor changes and cleans up. JFG's
256-frame replay is bitwise identical; FGN differences are characterized at
approximately 5 pm. Full public JFG processing measures zero warmed bytes;
control preparation and process-wide GC observations remain separately scoped.
The finite closed-loop experiment is not a loss-free capacity/deadline claim.

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

## WirePlumber pre-admission realization — 2026-10-07

[Primitive evidence and independent review](validation/wireplumber-realization-20261007/README.md)
cover native intent updates, real Links, generation withdrawal, delayed
completion, selected Copper FGN/JFG clean/retry/loss/fresh-admission checks
and the narrow WirePlumber POD-filter capacity correction. Systemd supervision
and broader timing/physical-device qualification remain separate.

## Separate systemd owner services — 2026-10-07

[Qualification and independent review](validation/systemd-owners-20261007/README.md)
record opt-in service supervision for Copper CPU FGN/JFG with CUDA AOS. All 11
selected owner/coordinator loss cases, final retained failure diagnostics and
fresh whole-session restart pass. Each engine delivers 2,048 final commands with
exact retained per-engine prefixes, zero simulator inclusive heap/GC tails and
empty owner cgroups. The headless RTC keeps native science/source authority and
WirePlumber keeps external links. Direct foreground, other profiles, target
timing, general multiple endpoints and physical actuation retain separate scopes.
