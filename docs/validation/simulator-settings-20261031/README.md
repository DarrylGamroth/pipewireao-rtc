# Simulator management and shutdown — 2026-10-31

Work is isolated from RTC `4604ce8` on
`codex/simulator-settings-and-shutdown`. GUI acceptance is isolated on
`codex/browser-simulator-acceptance`, rebased on local GUI main `320534f`.
The source fixes and live acceptance remain in progress.

## Cold settings description (RTC issue 36)

The registered RTC 0.2.51 Classic CPU application previously exceeded its
scientific description child's 50-second bound when driven by the rendered
browser. The read-only GUI helper's longer bound exposed that owner-side
failure; it did not resolve it. No rebuild was submitted in those failed runs.

The management dispatcher now compiles only the selected JSON operation through
`invokelatest`. Read-only scientific description selects `-O0` in the application's
pinned subprocess. Actual backend preparation retains normal optimization.
Application asset verification, fresh native identity, scientific validation,
request/reply bounds and operation deadlines are unchanged.

Fresh-process measurements on this concurrently used workstation:

| Measurement | Before | After |
| --- | --- | --- |
| First invalid-request `serve` call, same `-O0` process options | 10.70 s | 7.00 s |
| Scientific worker body, normal optimization versus `-O0` | 31.13 s | 17.12 s |
| Actual description subprocess through the modified parent | — | 41.86 s |

The three parsed settings/schema responses are identical. Package import is
excluded from worker-body timing; its first source-path cache compilation cost
was 18.97 seconds versus 1.30 seconds with an existing cache. These observations
do not establish a latency guarantee or ample margin under the 50-second bound.

The core Julia suite passes 7,982 assertions; the focused simulator suite, with
two subsequent JSON dispatcher assertions, passes 79. It covers declared settings,
immutable fields, replacement ordering and failure fences, record admission,
unknown launch acknowledgements, bounded JSON requests, and terminal receipt
polling through the actual JSON dispatcher. A separate source review found no
blocking correctness issue in the two cold-description changes.

## Shutdown and remaining acceptance (RTC issue 12)

The previous registered Classic session lost its owner proxy during one native
Quit. Cleanup completed, but accepted Offline was not established. That result
remains unknown and must not authorize a replacement or retry.

A new private CPU deployment adds bounded native hook phase/target diagnostics
and per-owner compilation traces. Its single Ready → Start → Running → Quit
experiment completed all native phases in 2.830 seconds, with accepted Offline,
successful systemd cleanup and all five owned units inactive with MainPID zero.
It had zero timing samples and therefore bypassed nonempty report serialization.

The earlier failed long-running session retained a full timing report. In a fresh
process, saving a real bounded 32,768 × 17 timing capture took 1.321 seconds first
call and 0.099 seconds warmed; the trace attributes 1.148 seconds to compiling
`PhaseTiming.save!(Capture)`. This is a measured shutdown cost, not proof of the
sole initiating cause of the earlier five-second expiry.

The existing preparation helper now precompiles that method before admission,
without calling it. An equivalent fresh-process full capture first save then
took 0.226 seconds, with compilation recorded before the save. Cold leaf methods
remain (about 76 milliseconds); zero compilation is not claimed. The two full
report documents match after removing the process-specific PID. The optional AOS
phase-timing selector passes all 21 assertions, including no files or consumed
samples during preparation. Independent review found no blocking correctness
issue in this change or the bounded native diagnostics.

Rendered-browser settings/rebuild/reconnect acceptance remains in progress.

## Local evidence

Detailed logs, compilation traces and private deployment receipts are retained
outside the repository under
`~/.local/state/pipewireao/rtc-simulator-fixes-20261031/`. Earlier browser failure
and cancellation evidence is under
`~/.local/state/pipewireao/browser-current-rtc-20261031/`.

Only test-owned CPU sessions are used. Scientific authoring is copied privately;
original instrument inputs and unrelated active sessions remain unchanged.
Functional software evidence does not establish numerical, hardware, cadence or
deadline qualification.
