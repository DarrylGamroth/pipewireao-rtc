# PipeWireAO RTC task index

Start with [current work](roadmap.md#current-work). Read the row matching the
change, then the affected clauses and their dependencies.
The runner delegates science execution to FGN/JFG and transport to PipeWireAO.

## Authorities

| Authority | Purpose |
| --- | --- |
| [Architecture](architecture.md) | Scope, ownership and `RTC-ARCH-*` decisions |
| [Operating contract](operations.md) | `RTC-DEV-001` through `RTC-DEV-030` requirements |
| [Roadmap](roadmap.md#current-work) | Current work and dependency order |

Requirements and accepted decisions remain authoritative regardless of whether
all their implementation/qualification gates are complete. Dated reports have
revision/cohort-specific scope. Use source and the linked evidence to support a
claim; do not infer completion from prose.

## Read by task

| Task | Relevant contract/design | Working guide or evidence |
| --- | --- | --- |
| Ecosystem integration/session-manager reuse | [System boundary](architecture.md#system-boundary), [configuration](architecture.md#configuration-boundary) | [PipeWireAO, FGN/JFG, AOS/AOC and proposed WirePlumber integration](ECOSYSTEM_INTEGRATION.md), [declared connection policy](WIREPLUMBER_CONNECTION_POLICY.md), [realization/withdrawal design](WIREPLUMBER_REALIZATION_DESIGN.md) |
| Runner/configuration/ownership | [System boundary](architecture.md#system-boundary), [configuration](architecture.md#configuration-boundary); RTC-DEV-001–004, 009–013 | [Operations](operations.md#requirements) and the matching source/tests |
| Graph properties/parameters | RTC-DEV-005, 010–012; [update classes](operations.md#update-classes) | [Native controls](NATIVE_CONTROL_MIGRATION_DESIGN.md), [public supervisor](NATIVE_SUPERVISOR_CONTROL.md) |
| Native controls/discovery/bootstrap | RTC-ARCH-024; [RTC-DEV-030](operations.md#rtc-dev-030--native-local-live-controls) | [Live-control inventory](LIVE_CONTROL_INVENTORY.md), [session discovery](NATIVE_SESSION_DISCOVERY.md), [bootstrap decision](NATIVE_OWNER_BOOTSTRAP_DESIGN.md) |
| Installation/systemd/placement | [Deployment architecture](architecture.md#selected-deployment-package); RTC-DEV-019–023 | [Julia deployment usage](JULIA_DEPLOYMENT_USAGE.md), [deployment validation](DEPLOYMENT_VALIDATION.md) |
| AOS/HIL/backends/offsets | [HIL architecture](architecture.md#selected-aoshil-deployment); RTC-DEV-014–017, 024–027 | [HIL usage](HIL_DEPLOYMENT_VALIDATION.md), [sustained usage](SUSTAINED_HIL_USAGE.md) |
| Unchanged HEART integration | [HEART bridge](architecture.md#heart-simulation-bridge), [RTC-DEV-028](operations.md#rtc-dev-028--external-heart-simulation-deployment) | [HEART HIL](HEART_HIL_VALIDATION.md), [HEART calibration adapter](HEART_CALIBRATION_ADAPTER.md) |
| Calibration/correction | [Calibration architecture](architecture.md#instrument-calibration-through-deployed-endpoints), [RTC-DEV-029](operations.md#rtc-dev-029--operational-interaction-calibration) | [Method usage](CALIBRATION_METHOD_USAGE.md), [completion plan](CALIBRATION_COMPLETION_PLAN.md), [native action API](NATIVE_CALIBRATION_ACTION_CONTROL.md) |
| GUI/non-gating observation | [RTC-DEV-006](operations.md#rtc-dev-006--optional-observation), RTC-DEV-022/030 | [Observation validation](LIVE_OBSERVATION_VALIDATION.md), [progress adjudication](NATIVE_HIL_PROGRESS_REVIEW.md); GUI owns rendering/client code |
| Acceptance/performance investigation | [Current work](roadmap.md#current-work), affected numerical/resource clauses | [Qualification plan](NATIVE_FINAL_QUALIFICATION_PLAN.md); select only the affected gate and its receipts |

Locate individual IDs/headings with `rg -n 'RTC-DEV-030|^##' docs/operations.md`
and read their sections plus necessary dependencies. Follow links for a specific
finding or result rather than loading the entire delivery catalog.

## Evidence and deferred work

- [Delivery evidence catalog](EVIDENCE_INDEX.md): preserved index of reviews,
  reports and receipts; historical wording does not define current status.
- [Application architecture adversarial review](APPLICATION_ARCHITECTURE_REVIEW.md):
  ownership-transfer findings and qualification boundaries for WirePlumber reuse.
- [Main integration snapshot](MAIN_INTEGRATION_20261006.md): exact source/dependency
  merge and its qualification limits on 2026-10-06.
- [Inactive full-RTC archive](archive/full-rtc/README.md): non-normative deferred
  design; read only for an explicitly selected scope change.
- [PipeWireAO contracts](https://github.com/DarrylGamroth/PipeWireAO/tree/master/doc/dox/internals):
  lower-level transport/FGN ownership. Scientific APIs remain with their packages.
