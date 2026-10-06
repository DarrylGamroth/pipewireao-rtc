# Native acquisition lifecycle codec foundation

Baseline: `60e28b8`, RTC-DEV-030 and phase D of the native control migration.
This document fixes the Julia wire profile for calibration and finite HEART
correction owner lifecycle control. It does not claim owner integration or close
RTC-DEV-030.

## Profiles and fixed envelope

Both profiles use the shared `NativeControlCodec` version 1 request, completion
and rejection envelope, the `NativeControlClient` traits, a 16 KiB request limit
and a 64 KiB lifecycle reply limit. The profile names are
`pipewireao.rtc.calibration-lifecycle/1` and
`pipewireao.rtc.correction-lifecycle/1`. Each advertises exactly six capability
names under its own namespace, with suffixes `version`, `instance`, `owner-pid`,
`lifecycle`, `last-token`, and `controllers`.

The request payload Struct has zero fields. Operation Ids are `status=1`,
`pause=2`, `resume=3`, `reset=4`, `connect=5`, `shutdown=6`. These are wire
identities; the owner still decides whether an operation is supported in its
current state. In particular, ordinary calibration reset requires a new owner
instance and is rejected by its current owner. There is no report path or JSON
body in this lifecycle codec.

Cold lifecycle Ids are `Preparing=1`, `Prepared=2`, `Connected=3`, `Fault=4`,
`Stopped=5`. Scientific `running` and `completed` are snapshot flags. The
owner's existing serialized dispatcher remains their authority.

The completion payload Struct has exactly three fields: lifecycle Id, Snapshot
Struct or None, and bounded message String (at most 8192 UTF-8 bytes). A
successful correlated completion requires a Snapshot, including Preparing and
Prepared status. Those states can use an `initial` snapshot with no cursor.
None is reserved for a negative result. The initial empty completion sentinel
is handled by the shared client and is not decoded as an owner completion.
The rejection payload has exactly lifecycle Id and bounded message String.

## Snapshot Struct

Fields appear in this exact order:

| Field | SPA POD | Rule |
| --- | --- | --- |
| instrument | Id | Classic=1, Copper=2 |
| cursor | None or Struct | domain, generation, sequence, model_ns: four SPA Long bit patterns, decoded as UInt64 |
| report_cursor | None or Struct | Same four UInt64 Long fields for the last actually published saved report; may lag cursor |
| running | Bool | Cannot be true with completed |
| completed | Bool | Cannot be true with running |
| phase | String | Nonempty ASCII, at most 64 bytes, from profile vocabulary below |
| held | Bool | Current owner hold evidence |
| restored | Bool | Current owner restoration evidence |
| window | None or Long | Calibration always None; connected correction requires positive UInt64 |

Connected requires a cursor and generation > 0. Preparing and Prepared may
omit the cursor. `report_cursor` may be None until an owner actually publishes a
saved report. It must never be inferred from a file poll or copied from the
acquisition cursor just to make status appear current. The two cursors can
legitimately differ, including across a reset boundary. All cursor components
preserve all 64 bits, including the high
bit and `typemax(UInt64)`. The Long encoding is a bit reinterpretation; signed
comparisons on the resulting values would change their meaning.

Calibration phases are `initial`, `held`, `adopted`, `settled`, `collected`,
`restoring`, `restored`, `released`, `fault`. They match the phase assignments in
`deployment/hil/calibration_server.jl`. The same server backs the HEART
calibration owner. Its `calibration_report` separately carries running,
completed, cursor, hold and restoration fields.

Correction phases are `initial`, `startup_run`, `correcting`, `restore_run`,
`restored`, `fault`. The first three active phase names come from
`HeartCorrectionPhases.PHASES`, which ends at `restore_run`. `restored` is a
derived lifecycle label for the completed retained window after the restore
run has drained; it is **not** an existing `PhaseStore.current` value. `fault`
is likewise a lifecycle failure label, not a telemetry file phase. Current
`heart_correction_owner.jl` records the active telemetry phase in
`session.service.phases.current`, the finite window in `owner.window`, and
completion in `owner.retained` / `state.completed`. An integrating owner must
derive the snapshot at its serialized effect boundary and must not mutate the
telemetry phase store to manufacture these labels.

The complete scientific JSON reports remain saved artifacts. The lifecycle
snapshot supplies bounded live status and does not replace their detailed
science or evidence fields. Owner endpoint, caller authority and migration of
the existing file controls remain phase D integration work.
