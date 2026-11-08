# Simulator runtime retirement

The RTC changes start at `1326e9aa25ede0a4b7530f55054c79edcdc9f41f` on
`codex/hil-optical-extraction-20261107`. The worktree was clean at the start.
The simulator process runs from the standalone HIL configuration and owns its
model time, detector exposures, command adoption and buffer publication.

| Finding | Observed behavior | Disposition |
| --- | --- | --- |
| SIM-01 | RTC still launched lockstep, external-pupil, clocked-optical and pupil-only processes. It also ran their diagnostics, pacing and pupil publication workers. | Retire the RTC entry point and process-specific placement, workers and reports. Export rejects commands that still name the old launcher. |
| SIM-02 | The RTC management worker described simulator settings and could replace a managed deployment. | Retire that request domain and its rebuild service in `fe16178`. Keep the artifact catalog and its receipt protocol. |
| SIM-03 | Calibration preparation consumes existing simulation definitions, FITS bindings, optical products and a physical command/pupil transfer proof. | Keep cold preparation and standalone export. Exercise the pupil graph and packet layout during calibration preparation without opening streams. |
| SIM-04 | Auxiliary-source export required an AOS scheduling kind even when the owner declared the correct SourceControl protocol. | Select the auxiliary source by its existing protocol. Keep the runtime's exact owner and bootstrap checks. |
| SIM-05 | The exposure-fraction and compact-metadata selector directly exercised HIL internals. | Move the selector to HIL in `abba1eafaee7876e0453b7b5c25b5de0ae454414` and use the typed Float32 stream state. |

RTC commits `fe16178` and `b45c301086152717075c1edb40cafbe3e57d7cf7`
remove 3,945 net Julia lines under `src` and `ext`.
The retained PipeWire contracts include endpoint names, shapes, types, schemas
and metadata profiles, session admission and link ownership, bootstrap,
SourceControl, graph controls and calibration transport. Source preparation
remains cold and uses the existing AOS and HIL APIs.

The [migration guide](../../HIL_CONFIGURATION.md#migrate-an-rtc-application)
describes the scope of a standalone launch. Existing managed instrument
profiles require an external provider of their declared RTC bootstrap and
SourceControl interfaces. Version-5 pupil-source profiles also require the
coupled physical-offset receiver and scientific pupil output. Standalone
schema 1 and 2 launches cover the stated HIL modes. Managed profiles without
an equivalent external provider require their pinned package cohort.

## Verification

Julia 1.13.3. Optional science and transport checks use PipeWireAO 0.9.2,
PipeWireAO_jll 4.0.2+0, FilterGraphAlgorithms 0.12.0, FilterGraphs 0.10.0,
FilterGraphPipeWire 0.5.2, AdaptiveOpticsCalibration 0.17.3, AOS 0.3.22 at
`c058f32f84c646d4510720e7a274f400e2939627` and HIL 0.5.1 with production
code at `fc5bd72f965f786bc12662868337baa2bac8d8da`.

- The RTC core suite passed 10,659 checks across 498 summaries.
- Management catalog dispatch and activation-unit generation passed 34 checks.
  The removed simulator request domain returns an unsupported-domain error.
- External auxiliary source authoring and exact session identities passed 36
  checks. The old scheduler required a simulator-specific kind.
- `test/runtime_install.jl --prepare-only` passed nine offline export checks
  using a declared external source and the matching SDK artifact.
- Standalone export, CPU trajectories, relocation, compiled model tamper
  rejection and session port contracts passed 176 checks. Another 66 cold
  checks covered pupil feedback, response cadence and optical calibration
  preparation. The pupil feedback selector validates an offline application
  declaration. The synthetic application contains a Project and deliberately
  omits a resolved Manifest.
- Named calibration transport and registry readiness passed 195 checks. Live
  checks used test-owned cores.
- Standalone HIL mode and finite optical transport passed 33 checks, including
  Hold/reset and cleanup on completion, stop and failure. The HIL environment
  resolves independently of RTC. The moved stream-format selector passed 172
  checks in the same environment.
- New documentation links and anchors, requirement identities and Git
  whitespace checks passed.

These are software, numerical and private-core transport checks for the
selected development cohort. Timing, hardware, and migrated managed-profile
qualification are separate gates.
