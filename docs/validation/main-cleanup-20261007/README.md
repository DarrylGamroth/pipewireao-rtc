# Main integration and cleanup — 2026-10-07

The user authorized merging the WirePlumber session migration, creating a
private GUI GitHub repository, removing obsolete worktrees, and cleaning
`~/.config/pipewireao-rtc`.

## Integration

| Repository | Branch | Integrated source |
| --- | --- | --- |
| PipeWireAO | master | `691928291` |
| WirePlumberAO | master | `9e339138` |
| pipewireao-rtc | main | `354ae53` |
| pipewireao-gui | main | `6e1a77b` |

All four merges were fast-forwards and pushed only to DarrylGamroth's forks.
The GUI repository is private, with main as its default branch. No public
artifact/license review is claimed. The GUI's pre-existing uncommitted
`docs/workstation-review.md` edit is preserved byte-for-byte. JFG's main
remains `b609116`; its generated untracked files are untouched.

## Cleanup and preservation

- Removed 34 clean worktrees: 13 ancestry-merged and 21 whose commits are
  patch-equivalent in main, independently checked with `git cherry`.
  Existing branch refs remain. Archive refs preserve the exact 21 divergent
  heads, including detached review heads.
- Kept 15 linked worktrees containing dirty/untracked changes or unique
  commits. These changes were not merged, reset, stashed or discarded.
- Removed 17 dated RTC deployment snapshots. Kept all 17 named `revolt-*`
  reference profiles. The configuration tree decreased from 660 MiB to
  256 MiB (allocated disk usage).
- Before removing snapshots, copied and SHA-256 checked their 22 uncovered
  calibration assets and preserved provenance/configuration records in
  `~/.local/share/pipewireao-rtc/retired-calibration/20261007` (5.7 MiB).
  This is historical reference data, not a runnable or sealed package.
- Removed 12 disabled, inactive legacy coordinator user-unit files after
  confirming each had MainPID zero, then reloaded the user manager.
- Relocated the private PipeWireAO library out of its removed build worktree,
  preserving its SHA-256 and all three library names. `/opt/pipewireao` was
  not rebuilt or modified.

The active `pipewireao-gui-hil-demo-hIo0tX.service` retains PID 1632744 and its
cache-owned package. No active service was stopped or restarted. Cleanup
checked current process/file and active-unit references before deleting
configuration snapshots. The named retained profiles still contain the old
coordinator SDK; they are legacy references and are not qualified for launching
through the new WirePlumber owner.

## Verification scope

Merge ancestry/patch equivalence, worktree cleanliness, calibration hashes,
private repository visibility, remote main/master heads and active service
identity were checked. No scientific implementation changed and no new runtime
suite or performance experiment was run for this cleanup. Earlier
[session qualification](../wireplumber-session-20261007/SESSION_CHECKS.md)
retains its recorded scope and remaining gates. [Receipt](receipt.json) records
exact source heads, removed paths, retained paths and preservation evidence.

## Follow-up: remaining reference deployments removed

The user subsequently requested removal of the remaining legacy deployments.
All 17 named `revolt-*` packages and the now-empty
`~/.config/pipewireao-rtc` directory were removed. Their calibration payloads,
graph configuration and provenance were copied and SHA-256 verified under
`~/.local/share/pipewireao-rtc/retired-calibration/20261007/profiles`. Identical
content shares storage using hard links. The complete reference archive now
occupies 15 MiB; its local manifest records all 328 preserved files. Legacy
executables, copied SDKs, service templates and reproducible replay inputs
were removed. Current process/file and active-unit checks found no users of
the deleted deployment paths.

The unused global `pipewireao-session@.service` symlink into the temporary
FGN installation was also removed, after confirming its instances had no
MainPID or pending jobs. This removes a temporary launch dependency; fresh
installed sessions continue to use their generated exact-instance units.
The active GUI/HIL service remains running on PID 1632744 from its separate
cache-owned legacy package. It has not yet been transitioned to WirePlumber.
See [the follow-up receipt](final-config-cleanup.json). `/opt/pipewireao`
remains unchanged and does not yet contain WirePlumberAO.
