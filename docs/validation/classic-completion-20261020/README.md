# Classic completion evidence — 2026-10-20

The selected profile is Classic on CUDA with a CPU JFG controller. The
[acceptance table](../../CLASSIC_REGISTERED_DEPLOYMENT.md#classic-completion-for-review--2026-10-20)
tracks the final disposition. This is bounded software/simulation verification;
physical calibration, convergence and a 500 Hz wall-clock guarantee are separate.

Raw commands, logs, payloads, initial failures and independent reviews are retained
locally at `/home/dgamroth/workspaces/codex/worktrees/classic-completion-20261020/`.
Paths below are relative to that evidence root. Compact retained receipts and
their source hashes are indexed in [retained-evidence.json](retained-evidence.json). Failed attempts remain available
and are superseded only for the specifically corrected check.

## Source and dependency identity

The independent application is `../revolt-classic-rtc`, commit `c52ceb5`.
It contains sealed configuration, GUI bindings, Project/Manifest and the retained
16 FITS inputs. It contains no copied executable implementation or source override.
The application selects released AOS 0.2.1, shared HIL 0.2.2 and PipeWireAO 0.6.18;
RTC 0.1.9 and Classic 0.2.1 are immutable **private review candidates**, not new
public releases. The Julia validation runtime is 1.13.2.

| Package | Candidate/release source | Immutable tree |
| --- | --- | --- |
| AdaptiveOpticsSim 0.2.1 | `bd4a866e44d120899ba11e50bfe7160e1fd1288a` | `1a809e78c898ce01a58915b7f4fb71dc92d4711e` |
| AdaptiveOpticsSimPipeWireHIL 0.2.2 | `87375e8d2fb1d0f63f279f20e4c445bdae517aa1` | `b86b36d35bf428be1f9b5bbf98eaf288302d2789` |
| PipeWireAORTC 0.1.9 | `b2c64dcd394653a625746b017ed2bb3994431bca` | `5c9ab53b7ac546b164865b012de75ec71ede49ba` |
| REVOLTClassicSim 0.2.1 | `cb0298ea5e8061bc2dba1a88b301836846a17990` | `4f895de09c12a49e9034b95cf87ee734ebdad09c` |

Later RTC test commits culminate in `965aef03`; they do not alter the candidate's
runtime tree. The isolated registry is commit `1754b50`; its depot shares existing
package/artifact/precompile caches. [Final relocation](relocation.toml) validates the seal before and after cached
instantiation. The 27 scientific/runtime inputs and descriptor runtime fields
match finite replay run 012 exactly. Relocation is not a fresh-cache qualification.
The selected native prefix is
`/home/dgamroth/.local/opt/pipewireao-classic-review-20261020`.
It contains the WirePlumber `ce2dc766` link-loss policy correction, preserving the
previous prefix and unrelated running cohort.

## Checks and scope

| Check | Evidence | Result and practical scope |
| --- | --- | --- |
| Managed lifecycle | `managed-session-003` | 68/68: held Ready, Start/Stop, stopped Reset/new generation, invalid-control survival, gain/offset adoption and restoration, eight-stream progress, orderly Quit and exact cleanup |
| Actual ADC transport | `classic-adc-transport-002.log` | 44/44: UInt16 row-major pixels, identities, micrometre-to-metre command mapping and next-frame causality on the actual CUDA boundary |
| Finite composed replay | `finite-replay/run-012` and `.log` | 1,318/1,318: 16 accepted exchanges each with no, normal, slow and detach/reattach observation; every ADC/demanded/adopted result exact across modes; ordinary CPU JFG replay exact |
| Installed observation | `review-session-001/observation-lifecycle.json` | Eight products finite and advancing; matching Acquisition identity across WFS-correlated products through normal/slow/full-client detach/reattach; applied has no Acquisition identity and focal runs independently; numerical trajectory comparison selects detector and demanded command only |
| Required link loss | `fault-link-002.log` | 41/41, policy fault, unknown-hold emergency shutdown, exact cleanup and fresh admission; no fabricated held acknowledgement |
| Controller exit | `fault-controller-001.log` | 40/40, policy fault, exact cleanup and fresh admission; unrelated cohort preserved |
| Calibration lineage | `science/CALIBRATION_REVIEW.md` | All five typed plant configurations and 16 FITS retained; actual 16-dark/16-training/16-qualification campaign provenance and current estimator replay verified |
| Resource characterization | `review-session-001/resource-summary.json` | 32,768 warmed rows; 429.023 Hz over 76.376 s; 5,421 skipped future release slots; 160 whole-process allocated bytes per adjacent exchange and zero process GC-time delta |
| Independent review | `review/REVIEW.md` and `review/finite-and-resource-independent.json` | Source, payload hashes, non-circular replay, observer scope and resource arithmetic independently checked |

All application capacity-one copy/drop-oldest exports remain installed during
observer comparisons. Reliable validation recorder branches are held constant
across finite scenarios. This verifies selected functional invariance; it is not
queue-disabled performance evidence or all-product numerical invariance.
Resource counters cover the whole simulator process, not callback allocations.
The retained matrix/reconstructor is hybrid and offsets are transferred from the
recorded magnitude-0.5 operational campaign to the magnitude-2 plant. No gain,
threshold, calibration or physical-model tuning was made from these comparisons.

## GUI and interactive configuration

The GUI uses egui/eframe 0.37.0 and egui_tiles 0.18.0. egui_dock is removed.
Inspection/MCP support is opt-in. `gui-egui/props-validation.md` and
`gui-live/props-live-comparison.json` record indexed read-only Props projection,
its post-write readback repair, and all 21 actual owner fields matching the
rendered panel. GUI closure leaves the RTC Running; explicit native Stop with
the GUI absent reaches Ready; reconnecting restores the real scientific views.

The Simulator navigation title is **Status**. Its ten source-snapshot fields are
in the main display; eleven startup configuration facts are in Settings. These
remain read-only facts, grouped in Configuration, Metadata and Details using
the shared collapsible section layout. The agreed future editing workflow is edit, apply and
restart; ordinary Stop/Start resumes the already prepared model and does not
adopt a changed exposure. The [maintained guide](../../CLASSIC_REGISTERED_DEPLOYMENT.md#simulator-settings-and-restart)
records the preparation and calibration requirements.

The grouped layout is committed at GUI `2fe96e1`. Production GUI `97e2999`
fixes the stale RUNNING header after actual native control endpoint loss: a
nonblocking read-only native callback pump publishes generation-bound loss,
invalidates cached lifecycle and disables controls without sending Status or
inferring Stopped. The [actual live regression](rtc-idle-loss.json) passes while
the separate PipeWire observer is still connected. Queued completed replies
retain their order; old-generation loss cannot disconnect a new selection.
[Independent replay](gui-focused-review.json) passes 24 focused tests.

GUI `b0fa8b3` adds a test-only example module missing after the egui migration.
All-target inspection verification passes **874 tests**, with 30 explicit live
tests ignored. The retained executable is the exact production `97e2999` build,
SHA-256 `61942cb383c8031c30417ca0c82a2b29ecac235bf5425eab55a39c7d2cd6051c`.
Final grouped-layout screenshot: `gui-live/classic-settings-grouped-running.png`.
The prior stale-header and example-build failures remain retained.

## Retained operator review

[Final handoff](handoff.json) records fresh held Ready, explicit GUI Start and
separate native Running confirmation for session
`5ee74331-974c-4546-91fb-6c06eae3e5d9`. The unit is
`pipewireao-session@e3ea2343257c.service`, invocation
`c8febbbffefb408a9c97ad59b71168ae`. The GUI remains attached with the grouped
Status/Settings and real SHWFS/DM views verified. Review-session-002 cleaned up
completely; the original unrelated cohort remains active with its original PID
and invocation. [Independent review](REVIEW.md) accepts the selected gates.
Its relative raw-evidence paths refer to the original evidence directory, not
this compact archive.

After replacing a cohort, use Connect to session, Refresh and select the new
entry. Old discovery hints remain non-authoritative and are rejected when their
exact native endpoint is gone. Ordinary Stop/Start pauses/resumes the prepared
simulation; orderly shutdown instructions are in the independent application.

The implementation and evidence are committed locally for review. These private
candidates have not been promoted to new public releases by this verification.
