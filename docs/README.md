# PipeWireAO RTC document set

The maintained baseline is intentionally small. It defines one non-actuating,
complete-frame Calculon/PipeWireAO development graph and the runner needed to
load, inspect, and test it.

## Active documents

| Document | Authority |
| --- | --- |
| [Development architecture](architecture.md) | Scope, component boundary, configuration choice, scientist boundary, exclusions, and RTC-ARCH-011 |
| [Development operating contract](operations.md) | RTC-DEV-001 through RTC-DEV-008, minimum lifecycle, updates, observation, diagnostics, and equivalence |
| [Development roadmap](roadmap.md) | Dependency-ordered implementation, completion evidence, performance characterization, and deferred capability triggers |

These three files are the complete RTC-level implementation baseline. An
implementation task should not load the archive unless it is explicitly
promoting a deferred capability.

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
Portable scientific algorithms and declarations remain authoritative in
Calculon. This repository states only the RTC runner behavior that connects
those pieces.
