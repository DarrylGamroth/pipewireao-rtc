# PipeWireAORTC application review scope

Review date: 2026-10-14 (America/Vancouver).
Review branch: `codex/rtc-astra-review-20261014`.
Review worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-astra-review-20261014`.
Starting shared commit: `f7777e8154f9593b793edb50b5162df05161b9aa`.
Starting instrument commit: `9c3e51ce6d943719ffa9aec180f18b34cfb26a1b`.

## User decisions controlling this review

- Rename the existing shared Julia package `PipeWireAODeployment` to
  `PipeWireAORTC`; assess filenames, organization, public interfaces and package
  boundaries before implementation.
- Resolve framework/science code from registered Julia packages through the
  user's Local Registry. Instrument deployments contain configuration and FITS
  artifacts, without copied implementation source or packed u8/f32le files.
- Decode FITS to validated owner arrays in memory. This restriction concerns
  persistent artifacts, not the existing typed ndarray wire representation.
- Expose RTC scientific Graph configuration and simulation Graph configuration
  as instrument-owned inputs. Preserve native PipeWire configuration formats.
- Do not register `REVOLTClassicSim`. Separate Classic-specific configuration,
  geometry and presets from reusable simulation implementation.
- Include `AdaptiveOpticsCalibration` in the package strategy. The installed
  Local Registry already contains it, through version 0.17.0.
- Assess actual opportunities to use the user's Julia packages, including Hsm
  and HdrHistogram; package reuse needs a concrete semantic and operational fit.

The earlier suggestion to merge FilterGraphPipeWire and
AdaptiveOpticsSimPipeWireHIL into PipeWireAO extensions is a proposal under
review, not an accepted implementation instruction.

## Scope and preserved authorities

Review the complete headless application path: shared operational tools and
protocol clients, WirePlumber session authority, systemd supervision, scientific
owner integration, instrument exporters, calibration orchestration, artifact
loading, deployment generation and GUI/CLI request boundaries. Inspect relevant
scientific adapter interfaces and the current Classic example. Review source,
public APIs, tests as evidence, documentation and configuration. This is not an
independent rederivation of every scientific equation or a complete GUI visual
review.

WirePlumber Lua remains the sole session lifecycle/admission authority under
RTC-ARCH-025; systemd owns process supervision. Scientific packages retain
mathematics and frame execution. Preserve native v1 protocol names, IDs, types,
units, incarnation checks, Unknown outcomes and cancellation/adoption sequencing.
No second Julia lifecycle coordinator, data scheduler or unnecessary event loop.

## Source state and safety

Review actual working sources, including user changes. The dedicated worktree
is the destination for review documents; it is a committed baseline, not a copy
of all uncommitted sibling source state. Reports must identify which working
source/version a finding concerns.

Pre-existing shared changes:

| File | SHA-256 at review start |
|---|---|
| README.md | 6884d1fc82732c2bc05d9a97fc99b848c89b9c00760537960a0755dfaefd29ea |
| src/PipeWireAODeployment.jl | a4737b449af749e011906faa06d6011a48c9b1be7bdceb70cab53431d47cdeb4 |
| src/native_source_control.jl (untracked) | f09ba2cf4ee38389f4408eefd4804fd2486b09171f91f7d73bfd20d5e61a1792 |

Pre-existing REVOLT changes: modified `assets/deployment/hil/simulator_owner.jl`,
deleted `source_control.jl`, modified `test_owner_loop.jl` and
`test_source_control.jl`. Additional scientific repositories have uncommitted
changes and source/registry version differences; inventory records are required.

Existing GUI and Classic RTC services are excluded from mutations. No production
source changes, registration, publishing, automatic remediation, test execution,
benchmarks or live operations are authorized by this review task. Existing tests
and measurements may be read; their conclusions retain their original scope.

## Deliverables and finding admission

Two independent Astra reports cover architecture/organization and runtime/
package reuse. A bounded inventory supports coverage. The primary agent reviews
significant findings against source and produces an adjudicated review and
ordered remediation plan.

Each finding has a stable ID, severity, confidence, location, evidence,
classification (observed/derived/hypothesis), concrete impact, proposed action,
required validation and disposition. Source patterns and long files alone do
not demonstrate defects. Performance claims require measurements; missing tests
or observability are gaps, not proof of a runtime failure.

Review completeness means each scoped component was inspected and coverage/
limitations were recorded. It does not mean source review proves runtime,
scientific, deadline, hardware or resource qualification.
