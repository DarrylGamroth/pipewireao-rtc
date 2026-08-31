# PipeWireAO RTC document set

These documents define the proposed headless RTC product and its delivery
path. They are split by authority so an implementation task can load only the
contract it needs.

The first implementation is intentionally smaller than the complete document
set. Start with the `development` capability profile in
[System architecture](architecture.md#capability-profiles-and-incremental-composition),
the minimal operating model in
[Operational architecture](operations.md#capability-profile-applicability),
and the [immediate delivery slice](roadmap.md#immediate-recommended-slice).
Camera sessions, recording, Julia execution, remote access, row-block tuning,
and target-host qualification are independently selectable capabilities. Their
contracts apply when those capabilities are selected; they are not all
prerequisites for running a Calculon graph.

| Document | Owns |
|---|---|
| [System architecture](architecture.md) | Product boundary, cumulative capability profiles, component ownership, control and data planes, and selected architecture decisions |
| [Operational architecture](operations.md) | Capability applicability, RTC-authoritative control, replacement admission, authority epochs, run identity and closure, lifecycle, configuration, artifacts, Calculon execution profiles and candidate activation, graph deployment, telemetry, recording, native and WebAssembly GUI behavior, remote access, supervision, and WirePlumber policy |
| [Camera-session contract](camera-sessions.md) | Proposed normative per-camera deployment unit, source-profile identity, source-configuration and format generation, control reconciliation, acquisition scheduling, isolation-first exported SPA host, qualified daemon-side loading, transforms, recovery, and placement qualification |
| [Time, causality, and performance](time-and-performance.md) | Clock domains, causal ordering, frame boundaries, deadlines, replay timing, execution-profile admission, and performance evidence |
| [Scientific data and command contracts](scientific-data-and-command-contracts.md) | Scientific quantity compatibility, schemas, normalization, deformable-mirror command stages, and the correction-authority grant |
| [Audit and reconstruction](audit-and-reconstruction.md) | Protected-operation progression, execution-composite provenance, terminal disposition, durability isolation, reconstruction, and safe replay |
| [Assessment and delivery roadmap](roadmap.md) | Current capability assessment, small independently testable delivery increments, profile-specific evidence gates, risks, and open decisions |

Low-level ndarray, FGN, metadata, polling, row-block, and progressive-processing
contracts remain authoritative in the
[PipeWireAO repository](https://github.com/DarrylGamroth/PipeWireAO/tree/master/doc/dox/internals).
