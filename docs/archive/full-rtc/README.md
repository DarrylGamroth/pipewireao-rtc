# Archived full-RTC design

Status: inactive design archive

This directory preserves the full operational RTC proposal reviewed on
2026-08-31. It is intentionally outside the maintained implementation
baseline. The files are useful design input if a future deployment selects a
physical camera, physical correction, durable recording, managed Julia
execution, remote access, progressive scheduling, or target-host
qualification.

Nothing in this directory is a current implementation requirement, delivery
commitment, capability claim, or qualification claim. The `RTC-ARCH-001`
through `RTC-ARCH-010` decisions and all `RTC-OPS-*`, `RTC-EXEC-*`,
`RTC-CAM-*`, `RTC-DATA-*`, `RTC-DM-*`, `RTC-GUI-*`, `RTC-TIME-*`,
`RTC-CAUSAL-*`, `RTC-FRAME-*`, `RTC-DEADLINE-*`, `RTC-PERF-*`,
`RTC-REPLAY-*`, `RTC-RECORD-*`, and `RTC-AUDIT-*` requirements are reserved
historical identities. They must not be reused for another meaning.

The active baseline is defined by the top-level [document index](../../README.md),
[development architecture](../../architecture.md),
[development operating contract](../../operations.md), and
[development roadmap](../../roadmap.md).

## Contents

| Archived file | Former scope | Reason sequestered |
| --- | --- | --- |
| [architecture.md](architecture.md) | Full development, operational, and qualified product architecture | Mixes the small runner with future authority, placement, recording, Julia, remote, and qualification decisions |
| [operations.md](operations.md) | Protected lifecycle, deployment admission, run identity, GUI, recording, Julia, supervision, and policy | Far beyond the non-actuating development runner |
| [camera-sessions.md](camera-sessions.md) | Physical, simulated, and replay camera-session contract | Physical camera lifecycle and device authority are not selected |
| [scientific-data-and-command-contracts.md](scientific-data-and-command-contracts.md) | Full scientific semantics and physical DM command authority | The active sink is non-actuating and no correction grant exists |
| [time-and-performance.md](time-and-performance.md) | Causality, replay, deadlines, progressive frames, and target-host evidence | The active baseline makes no real-time or correction-critical claim |
| [audit-and-reconstruction.md](audit-and-reconstruction.md) | Durable audit, reconstruction, and safe replay | The active baseline has no durable-run claim |
| [roadmap.md](roadmap.md) | Multi-track delivery and capability promotion | Replaced by the short development roadmap |

## Active disposition

| Historical material | Current disposition |
| --- | --- |
| RTC-ARCH-010 cumulative-profile delivery posture | Superseded as the active baseline by RTC-ARCH-011; identity remains reserved |
| RTC-OPS-006 development profile and exclusions | Distilled into RTC-DEV-001 and RTC-DEV-002 |
| RTC-OPS-007 dependency and observer rules | Distilled into RTC-DEV-003, RTC-DEV-004, and RTC-DEV-006 |
| Former minimum development configuration | Distilled into RTC-DEV-002 and the active minimum configuration model |
| Former scientist-authoring acceptance criteria | Distilled into RTC-DEV-008 |
| Former REVOLT immediate slice | Distilled into RTC-DEV-005, RTC-DEV-007, and the active roadmap |
| All physical, operational, recording, Julia, remote, progressive, and qualification clauses | Inactive with no current replacement |

## Promotion rule

A future task may promote one capability at a time. Promotion requires a new
active architecture decision, a reviewed minimal contract, an implementation
plan, and explicit evidence. It must not reactivate this directory wholesale.
The archived requirement text can be reused after checking it against the then
current PipeWireAO and Calculon interfaces, but its former “selected” wording
does not itself select anything.
