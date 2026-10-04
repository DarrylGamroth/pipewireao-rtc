# Julia operational calibration migration

## Delivery status

The selected operational migration is complete. Julia owns the four campaign
entry points and their installed export/supervision dependencies. The
[delivery record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md),
[evidence ledger](JULIA_CALIBRATION_MIGRATION_EVIDENCE.json) and
[independent review](JULIA_CALIBRATION_MIGRATION_REVIEW.md) bind verification
and limits. Scientific calibration remains partial under RTC-DEV-029. The
starting-state and implementation plan below preserve the original decision.

## Decision and starting state

User direction on 2026-10-03: scripts promoted to production must use Julia.
RTC-DEV-029 applies this boundary to operational calibration, including indirect
package-export and process-supervision dependencies. Starting RTC source:
`7aa7cbd`, clean main. This plan is prepared in a dedicated worktree on branch
`work/julia-calibration-orchestration-20261003`; no executable replacement was
implemented when this plan was written.

Julia already owns detector/DM acquisition, the completion-event server, probe
construction and numerical analysis. Python assembles packages, supervises
deployments, validates receipts and payloads, sequences stages and invokes
Julia analysis. Porting just a campaign entry point would leave transitive
Python dependencies in export and deployment helpers.

## Current allocation and selected scope

All paths below are relative to `deployment/`.

| Current files | Responsibility | Migration |
| --- | --- | --- |
| `hil/calibration_acquisition.jl`, `hil/calibration_server.jl`, `hil/calibration_owner.jl` | Endpoints, adopted probes, settling and exposure association | Reuse existing Julia modules |
| `hil/calibration_client.jl`, `hil/calibration_*_analysis.jl` | AOC probe bases and measured-response estimation | Reuse existing Julia modules; avoid a second estimator |
| `calibration_campaign.py`, `calibration_method.py` | Classic stage and method orchestration | Julia entry points with shared campaign code |
| `copper_reference.py`, `copper_quality.py` | Copper reference and amplitude pilot | Julia entry points with the same shared code |
| `export.py`, `export_hil.py`, `export_calibration.py`, `deploy.py`, `placement.py` | Transitive configuration, staging, supervision and placement | Migrate portions required by installed calibration; explicitly inventory remaining calls |
| `export_heart_hil.py`, `hil/heart_owner.py` | Selected HEART bridge export and supervision | Remove Python dependence before qualifying this production path; keep HEART unchanged |

Python qualification checks and independent NumPy audits may remain external
development tools. Their success does not establish an operational workflow
independent of Python. The Rust RTC runner and FGN/JFG execution owners retain
their current responsibilities.

## Contracts to preserve

Reuse standard SPA-JSON configuration, current versioned recipes and artifact
contracts, public control/calibration protocols, and Julia's existing JSON3,
Sockets, SHA and process facilities. Use shared Julia support with thin CLI
entry points; do not translate each script into an independent implementation
or introduce another bundle format, scheduler or scientific estimator.

Preserve parsed-value validation, represented Float32 probe intervals, units,
measurement order, profile shapes, row-major payloads and finite capacities.
New serialization may change hashes: bind new producer identities and artifacts
rather than relabeling historical evidence.

Keep one serialized session owner. Orchestration uses the public protocol;
PipeWireAO.jl endpoints stay in the acquisition owner. Preserve adoption versus
submission, completion-driven settling, exact run/request/exposure association,
whole-stage deadlines, clipping checks and ownership. Save and verify each
completed batch before advancing. Unknown outcomes retain hold or fault; partial
data cannot replace active calibration. Restoration, release, public stop/quit,
process reaping and owned-runtime removal remain observable gates.

Preparation, compilation, allocation, hashing and logging remain outside frame
callbacks. Reuse prepared analysis within a campaign where practical. Warmup
must not silently generate accepted exposures or change the probe sequence.

## Implementation order and validation

Complete the following stages in order.

1. **Shared Julia support.** Inventory calls reachable from all four campaign
   owners. Implement required staging, bounded control, deadlines and cleanup.
   Check valid fixtures, malformed settings, wrong identities/payloads,
   interruption, known rejection and unknown outcome against retained behavior.
2. **Julia campaign entry points.** Migrate Copper reference/quality, then
   Classic campaign/method selection through the same support code. Preserve
   CLI responsibilities and scientific APIs. Flat-mirror illumination
   qualification is an explicit scientific preparation step; language parity
   does not fix the dim Copper pilot or accept a matrix.
3. **Portable and installed parity.** Validate seals, manifests, payload layout,
   receipts and lifecycle failures. Compare reductions of identical retained
   inputs with existing analysis and independent audits. Run Classic/Copper
   FGN/JFG complete-frame sessions sequentially under documented placement,
   with normal detector noise/ADC. Require exact delivery, restoration, release
   and shutdown; distinguish changed stochastic inputs from calculation errors.
4. **Production packaging.** Qualify preparation and launch without a Python
   interpreter available to the operational workflow, including the selected
   HEART bridge. Check foreground and systemd user-unit entry points and their
   installed dependencies. Update usage/packaging before retiring Python
   campaign entry points; keep historical evidence identifiable.

Completion requires no reachable operational Python dependency, portable failure
regressions, installed Classic/Copper FGN/JFG acquisition/lifecycle evidence and
package launch evidence. Language migration establishes neither calibration
precision nor physical suitability, correction, GPU cadence or RTC latency.

## Risks and limits

The main risk is losing lifecycle/evidence invariants in duplicated export code.
Shared support and retained adversarial fixtures address that risk. Julia
startup and precompilation costs need separate measurement before claiming a
timing improvement. Copper has reference and pilot capture, not an accepted
full interaction campaign. Classic's accepted finite CPU results retain their
recorded scope. Preserve prior failed evidence. Numerical methods remain in
AOC; no external GPL implementation is imported or translated.
