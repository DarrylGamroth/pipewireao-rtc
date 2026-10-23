# Launcher scheduling review — 2026-10-23

Source baselines: RTC `e66f93c`, instruments `ca96988`, initially clean.
Implementation used separate `codex/launcher-scheduling` worktrees under
`/home/dgamroth/workspaces/codex/worktrees/`. No scientific package, calibration
artifact, installed application or live service was changed.

## Decisions and review

Host authoring now declares native process contracts, named `data-loops` and
framework `workers`. The builder owns argument encoding, thread counts and native
context generation; source owners explicitly select JFG or AOS. No instrument
name, executable-string inference or CPU-binding map selects behavior.
The user selected `pacing_rate_hz`; physical sample rate, exposure and one-step
per accepted exchange semantics remain unchanged. Historical report keys remain
unchanged. Superseded configuration keys and CLI flags are rejected.

An independent Sol source review covered framework selection, CPU containment,
native contexts, observation CPU forwarding through warmup/reset and pacing math.
No remaining confirmed findings were reported. Primary inspection confirmed:

| ID | Finding | Disposition and verification |
| --- | --- | --- |
| LS-01 | Migrated host initially omitted JFG's native data loop | Corrected; native exact-loop and profile/build checks pass |
| LS-02 | Old examples assigned JFG thread one away from its leader, observation to the source CPU, and a session loop outside its envelope | Corrected explicit example assignments; launcher rejects conflicting worker declarations before launch |
| LS-03 | Obsolete optical CPU environment could arrive after adapter validation through host overrides | Adapter now runs after environment merge; same override regression rejects before export |

The historical validation host retained scientific worker ordering; its session
client now uses its own CPU/priority rather than the previous global binding.
This is an intentional correction, not a claim of identical old native contexts.

## Verification

Julia 1.13.2, local CPU SDK wrapper, private science environment
`launcher-scheduling-validation`, one Julia/BLAS thread for numerical selectors,
empty GPU visibility. Focused selectors:

- RTC `test/test_instrument_profiles.jl`: 40 assertions;
  `test/test_owner_scheduling.jl`: 18; `test/test_instrument_export.jl`: 128;
  `test/test_native_configuration.jl`: 39.
- RTC `test/test_aos_owner.jl`: 200; phase timing: 18;
  owner idle: 8, including zero bytes for 1/100/1000 idle polls.
- Instruments `test/profiles.jl`: 26; `test/hardware_profile.jl`: 35;
  `test/modes.jl`: 841. Comparisons retain scientific contracts and normalize
  intentional launcher argument changes; frozen receipts are not rewritten.
- CPU owner/settings: 14, including first 480-sample-pupil frame and atmosphere
  settings rebuild without GPU libraries.
- Example CLI build and `test/exported_core.jl`: pass, four isolated core/queue
  startup assertions. Repository format and whitespace checks pass.

One mode run encountered the source-immutability assertion while source README
edits were still being written; the unchanged rerun after source freeze passed
all 841 assertions. This was not a numerical mismatch.

Selectors were invoked with the CPU SDK wrapper and
`julia --startup-file=no --project=/home/dgamroth/workspaces/codex/worktrees/launcher-scheduling-validation`.
Each named test file above is independently runnable in that environment.
The instrument mode selector receives source, previous exported application and
host YAML arguments as documented in its header. The native-core selector receives
the fresh exported application. Formatting uses `julia --project=tools tools/format.jl --check`.

These are software, CPU simulation and private-core checks. They do not qualify
real-time scheduling, tail latency or physical hardware. Observation warmup/reset
CPU propagation was source-reviewed; a new full live observation restart cohort
was not run. The existing live RTC was not restarted or modified.
