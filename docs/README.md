# PipeWireAO RTC document set

These documents define the proposed headless RTC product and its delivery
path. They are split by authority so an implementation task can load only the
contract it needs.

| Document | Owns |
|---|---|
| [System architecture](architecture.md) | Product boundary, component ownership, control and data planes, and selected architecture decisions |
| [Operational architecture](operations.md) | Lifecycle, configuration, artifacts, graph deployment, telemetry, recording, GUI behavior, supervision, and WirePlumber policy |
| [Time, causality, and performance](time-and-performance.md) | Clock domains, causal ordering, frame boundaries, deadlines, replay timing, and performance evidence |
| [Scientific data and command contracts](scientific-data-and-command-contracts.md) | Scientific quantity compatibility, schemas, normalization, and deformable-mirror command stages |
| [Audit and reconstruction](audit-and-reconstruction.md) | Protected-operation progression, terminal disposition, durability isolation, reconstruction, and safe replay |
| [Assessment and delivery roadmap](roadmap.md) | Current capability assessment, phased implementation, evidence gates, risks, and open decisions |

Low-level ndarray, FGN, metadata, polling, row-block, and progressive-processing
contracts remain authoritative in the
[PipeWireAO repository](https://github.com/DarrylGamroth/PipeWireAO/tree/master/doc/dox/internals).
