# Julia calibration acquisition — 2026-10-08

Baseline: `6a040187bcc5b19697329241d6e8fe5135ddafc1`, initially clean.
Implementation branch: `codex/julia-acquisition-20261008`.
Exact inputs, commands, dependency identities and retained log hashes are in
[the receipt](receipt.json); findings and independent remediation checks are in
[the Astra review](REVIEW.md).

## Implemented

Fresh calibration exports now seal a Julia `bin/rtc-calibrate` entrypoint instead
of requiring an external Rust executable. Campaign and HEART adapter callers
use that entrypoint. The reusable driver executes prepared absolute figures
through native v1 Hold → Adopt → Settle → Collect → Restore → Release actions.
AOC still supplies probes and scientific estimation; WirePlumber owns session
admission and systemd owns process lifetime.

The driver checks clipping, figure identity, causal exposure evidence, correlated
completions, cancellation and finite recovery. Unknown transport outcomes stop
submissions. Saved v1 plans/stdout reports remain compatible; optional saved
completion journals are explicitly version 2. Live controls remain native SPA
PODs. Older sealed Rust commands retain their bytes. The obsolete runtime-refresh
helper was removed; its historical Copper receipt links the original revision.
See [API and usage](../../JULIA_CALIBRATION_ACQUISITION.md).

## Observed software results

| Check | Result |
| --- | --- |
| Complete Julia tooling suite | 2,980 assertions, 104 testsets; exit 0 |
| Native owner/server suite | 775 assertions, 41 testsets; exit 0 |
| Retained Rust acquisition tests | 19 tests; exit 0 |
| Classic/Copper-sized synthetic native owners | 60 assertions within the native suite; 277 commands, 376/3,600 measurements, three settling rules |
| Julia/Rust native success reports | 36 assertions within the native suite; complete stdout reports equal |
| Installer compatibility | 11 assertions within the Julia suite; selected Julia wrapper validation and unchanged legacy sealed bytes |
| Relocated fresh export | Julia wrapper runs from a path containing spaces and rejects an obsolete flag before connection |

Runs used Julia 1.12.7 on CPUs 14/15; independent discriminators used CPU 13.
CPU 0/1 were excluded. Native tests used disposable private cores from JLL
artifact `cee1f96f590a4ee6f4c25f6860648cda5d5ca225` and the source PipeWireAO.jl
SDK. The Rust oracle was built temporarily against `/opt/pipewireao`; its hash is
retained without retaining the build tree. Other repositories' source and
existing services were not modified or stopped.

## Failures and warnings retained

The first native executable test exhausted its initial cold-start admission and
binding deadlines. Test-only startup budgets were increased; production action
budgets were unchanged. The final native run passed. This was executable
qualification, not a latency experiment.

Independent review found and verified fixes for cancellation after Restore
suppressing Release (JAC-001), valid calibration budgets being capped at 30 seconds
(JAC-002), obsolete documented flags (JAC-003), and a consumed byte buffer in
saved-plan validation (JAC-004). The final valid-plan regression passed alongside
duplicate-field rejection checks. Earlier failed logs remain in the receipt's
bounded cache directory (about 131 KiB total).

The suite emits caught non-Git provenance diagnostics from synthetic copied
roots and the expected YAML duplicate-key diagnostic. The alternate SDK load
path also emits cache/version warnings, including a HIL precompile failure;
runtime assertions passed. Clean installed-package precompilation is not
established by this harness.

## Limits and remaining work

These are software/native interoperability results. Synthetic measurement
dimensions do not establish actual Classic/Copper graph calibration, scientific
matrix acceptance, HEART live calibration, a fresh full systemd installation,
frame allocation budgets, cadence, tail latency or hardware-loop qualification.
The direct Julia/Rust report comparison covers successful acquisition; failure
paths are covered by synthetic regressions, retained Rust tests and source review.

This completes the acquisition replacement increment. GUI client detachment,
shared package relocation and independent instrument projects remain in
[the maintained roadmap](../../roadmap.md#current-work).
