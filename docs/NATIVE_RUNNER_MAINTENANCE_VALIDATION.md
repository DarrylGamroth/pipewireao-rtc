# Native runner maintenance admission correction

2026-10-06. This implements the adjudicated findings in the
[independent review](NATIVE_RUNNER_MAINTENANCE_REVIEW.md).
The [receipt](validation/runner-maintenance-20261006/receipt.json) records exact
source and binary identities and the retained test evidence.

## Observed defect and correction

The failed installed Classic FGN service v3 returned a correlated Status
rejection, `EBUSY`. Its diagnostic does not distinguish an occupied slot from
maintenance. Source inspection and a deterministic test independently establish
that maintenance rejected a sole request despite an empty slot. The new test
failed on the original code (`Rejected`, expected `Accepted`); it passes after
the correction. This does not retrospectively prove which branch rejected v3.

Maintenance now admits one request into the existing pending slot. Callbacks
reserve work; the owner dispatches it after monitoring. Occupied-slot, controller,
token, canonical duplicate and parameter-worker guards remain active. A newly
accepted request shortens the current PipeWire wait to its original deadline;
duplicates and rejected requests cannot change that limit. There is no retry,
extra queue or deadline extension.

Lexical scope deadlines and admission deadlines are separate. An admission limit
survives return from an inner scope even when the inner limit was already
shorter. The outer scope restores prior state on return or unwind. The shared
deadline uses a mutex because the public filter listener requires a Send callback;
these accesses occur in cold controls, outside scientific processing callbacks.
Roundtrips re-read the effective limit and handle an expired callback wait.
Monitoring rechecks tickets admitted after entry before applying observations.

## Verification

- Rust workspace: 198 tests pass; optional live fixtures remain explicitly
  ignored by that run. Formatting and Clippy with warnings denied pass. Cargo
  reports the existing dependency future-compatibility notice for
  `proc-macro-error2`; no project Clippy warning remains.
- Actual private core: all five monitor fixtures pass, 15 Julia assertions.
  Required-object loss fences both pending preparation and queued work.
  Already accepted and newly arriving requests bound a stalled-core wait.
- The delayed fixture invokes the production admission helper from a timer on
  the same owner loop, 40 ms after monitoring enters its roundtrip. Its original
  request budget is 250 ms. The retained log records elapsed time, a correlated
  local timeout, Ready lifecycle, released slot and no SessionStart effects.
  Admission identity is synthetic; there is no remote timeout observation while
  the daemon is stopped. This is deadline behavior, not SCI latency evidence.
- Pure scope tests cover shorter/equal/longer inner limits, scope restoration,
  admission during unwind, fresh unrelated scopes and non-extension. Admission
  tests cover duplicates, collisions and requests outside maintenance.

Installed service, calibration, observer and HEART qualifications remain separate.
The failed v1/v2/v3 runs remain failed. No scientific algorithm, calibration,
placement or native transport library is changed by this correction.

## Build storage

The fresh build uses `/tmp/rtc-maintenance-target-20261006` with debug information
and incremental compilation disabled, avoiding growth on the nearly full project
volume. Old executable and scientific evidence identities remain retained.
Earlier regeneration-only static compilation archives reclaimed 192,035,002 bytes:

| Ledger in `~/.cache/rtc-native-final-deployment-20261006` | Files / bytes | SHA-256 |
| --- | ---: | --- |
| `compile-archive-reclamation.json` | 6 / 91,015,782 | `28734d44f2385c41f82ffdf31193f2ff434d2b23de65a7a93386e633eb880350` |
| `compile-archive-reclamation-2.json` | 8 / 101,019,220 | `d652f8d7b6bf3eb3c05d275b010c2a816dfa2a648ac03bfcff4eaf4b2026c268` |

These are removed `.rlib` compilation archives, not an assertion that their source
was obsolete. Current executables, shared libraries and experimental records were
preserved. A later Cargo build may regenerate the archives.
