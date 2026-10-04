# Julia operational calibration migration review

## Scope and revision

Independent review of RTC-DEV-029 migration against RTC-DEV-020 through RTC-DEV-028 and the [migration plan](JULIA_CALIBRATION_MIGRATION.md). Baseline commit: `395c8bfdc417bcd04d6e47776d731176aef0e5ae`. Worktree: `/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-julia-calibration`, branch `work/julia-calibration-migration-20261003`. Production implementation was uncommitted and changing during review; the service template already had changes and Julia implementation files were untracked. The reviewer owns this report only and made no production source changes, commits, sibling modifications or live deployment.

The selected operational boundary starts with an existing sealed scientific base package. The original scientific benchmark asset generator remains development input. This review does not demand migration of that generator or numerical estimator replacement. Required installed preparation resources and transitive export/supervision dependencies are within scope.

**Current disposition: the selected Julia operational migration is qualified within the exact implementation versions, dependency bytes and functional CPU scope recorded below. All confirmed code findings are remediated; JMR-007 is closed for this selected scope.** Independent review verified portable corrections, installed Classic/Copper FGN/JFG acquisition evidence, unchanged HEART exchange, cold preparation, restricted executable-path launch, actual systemd lifecycle and active-session SIGINT cleanup. Scientific calibration acceptance, physical validation and timing guarantees remain outside this closure; RTC-DEV-029 scientific work remains partial. See the [delivery record](JULIA_CALIBRATION_MIGRATION_VALIDATION.md).

## Findings and adjudication

| ID | Severity | Confidence | Evidence class | Disposition |
| --- | --- | --- | --- | --- |
| JMR-001 | High | High | Observed | Deadline correction independently verified; final v7 portable suite and installed stage timing records verified |
| JMR-002 | High | High | Observed | Corrected; independent 17-task affinity check passes |
| JMR-003 | Medium | High | Observed | Corrected; same independent overflow probes reject |
| JMR-004 | Medium | High | Source behavior; remediation observed | Cold resources corrected; relocation and four final v8 cold exports independently verified |
| JMR-005 | Medium | High | Source behavior; remediation observed | HIL source identity seal corrected; method copy collision corrected |
| JMR-006 | Medium | High | Source behavior; remediation observed | Installation preserves sealed entrypoint bytes; independent install fixture passes |
| JMR-007 | Release gate | High | Observed evidence boundary | Closed for selected scope: eight acquisition cells, final terminal checks, four v8 HEART routes and active SIGINT verified |
| JMR-008 | High | High | Observed | Corrected; independent exited-owner descendant cleanup passes |
| JMR-009 | High | High | Derived from finite cleanup bounds | Corrected shared 300-second allowance; analytical bound and installed active-session SIGINT cleanup verified |
| JMR-010 | High | High | Observed | Exact JSON numeric parsing corrected and independently verified |
| JMR-011 | Medium | High | Observed | Corrected; independent backwards-chronology fixture rejects |
| JMR-012 | High | High | Observed credentials plus documented manager policy | Corrected; sender credentials and actual Classic/Copper main-PID user-service readiness verified |
| JMR-013 | High | High | Primary installed-run observation; retained result independently read | Public PID API corrected; installed readiness/acquisition pass-after verified |
| JMR-014 | Medium | High | Primary/worker cold-template replay | Instrument-specific sections corrected; final Classic/Copper cold exports and four live bridge routes verified |
| JMR-015 | High | High | Independently reproduced | Control and terminal endpoint flush corrected; identical independent fail-before/pass-after probes pass |
| JMR-016 | Medium | High | Independently reproduced | Supervised child stdout/stderr explicitly inherited; actual spawn probe passes |
| JMR-017 | Medium | High | Independently reproduced | Strict JSON token/grammar admission corrected; malformed-input probes reject |
| JMR-018 | Medium | High | Installed cold-preparation failure plus independent fixture | Staged replacement independently verified; actual Classic/Copper v7 cold exports and seals pass |
| JMR-019 | High | High | Source-only installer and generated-service fixtures independently reproduced | Resources, seals and generated service policy corrected; identical relocated-unit probe passes |
| JMR-020 | High | High | Native compact/pretty counterfactual; independent emitter validation | Dedicated SPA writer corrected; native probe and four final installed HEART lifecycles pass |

### JMR-001 — Unsigned subtraction defeats the whole-stage deadline

Affected code: `deployment/julia/calibration_campaign.jl`, `stage_remaining`, `run_stage`, failure cleanup grace. All four owners share `run_stage`.

Observed before correction: Julia `time_ns()` returns `UInt64`; the stage deadline was also `UInt64`. Once expired, `deadline - time_ns()` wrapped to a large positive value. The direct call `stage_remaining(time_ns() - UInt64(1_000_000_000), 30)` returned `30.0` for a deadline already one second past. The positivity guard therefore permitted later work and repeated full request budgets instead of rejecting expiry. This violates RTC-DEV-029 finite whole-stage acquisition deadlines.

Remediation: use signed/widened arithmetic or a safe elapsed-time comparison consistently, including the recovery grace calculation. The worker changed the deadline and subtraction to `Int128`, including late endpoint-completion comparison. The same independent expired-deadline call now throws `calibration stage deadline expired`.

Required validation: already-expired and near-boundary deadlines, elapsed startup consuming the acquisition budget, expiry after saved capture and before next adoption, and separately bounded recovery. Initial fail-before and focused pass-after behavior is demonstrated; installed stage timing remains a separate gate.

### JMR-002 — Julia supervisor helper threads retain unrestricted affinity

Affected code: `deployment/julia/deploy.jl`, `run`; installed and source launch entrypoints.

Observed: `run` used `taskset -pc CPU getpid()` after Julia had started, which changes only the leader. An independent Julia process using the same call had eleven native tasks. The leader changed from CPUs `0-15` to CPU `2`; the remaining ten tasks, including `iou-sqp-*` and Julia runtime threads, retained `0-15`. The supervisor is not included in the owned-child placement snapshots. This defeats the maintained exclusion of CPUs 0/1 and makes foreground placement differ from inherited systemd CPUAffinity.

Remediation: constrain all existing supervisor tasks and ensure future tasks inherit the intended housekeeping affinity, or establish affinity before starting Julia. Record and verify the actual supervisor task set. Explicit Julia thread settings alone do not account for all native runtime/helper tasks.

Correction observed: `Placement.pin_supervisor` applies `taskset -apc` and verifies every native task. An independent Julia `--threads=4` process had 17 native tasks; after spawned Julia work, GC and a subsequent task census, all 17 had only CPU 2. Foreground installed and service evidence remains required.

Required validation: foreground and service startup with deliberately broad inherited affinity, inspection of every `/proc/PID/task/TID/status`, and observation after late runtime tasks are created. Do not change worker FIFO or scientific-owner placement contracts while fixing the supervisor.

### JMR-003 — Fixed-width arithmetic admits invalid export bounds

Affected code: `deployment/julia/science_export.jl`, `validate_parameter`; `deployment/julia/hil_export.jl`, `finite_payload`; `deployment/julia/heart_export.jl`, `readout_interval`.

Observed: `ScienceExport.validate_parameter` accepted an empty file declared `F32_LE` with shape `[1 << 62]`, because `prod(shape) * 4` wrapped to zero. `HeartExport.readout_interval("copper", 1 << 62, 4)` returned `4611686018427387904`, because the rate product wrapped to zero and passed the less-than-95-percent test. Retained Python uses arbitrary-precision integer products and rejects these cases. The same unchecked shape-product pattern exists in `finite_payload`.

Remediation: validate positive integer dimensions and use checked/widened arithmetic with explicit finite capacity before reading a payload. Check HEART readout bounds without an overflowing multiplication. Keep represented numeric limits and the original strict 95-percent inequality.

Correction independently verified: shared `payload_bytes` uses widened integer arithmetic before file reading; HEART readout multiplies in `Int128`. The same huge-shape and readout probes now reject.

Required validation: zero/negative/Boolean dimensions, extent/product overflow, incorrect byte lengths, valid boundary shapes, and readout just below/at the limit plus large overflowing inputs. The discriminator cases above are portable and do not need live deployment.

### JMR-004 — Installed cold preparation omits resources used by exporters

Affected code: `ScienceExport.copy_deployment_runtime`; `HILExport.export_package`; `HeartExport.export_package`; installation entrypoints.

Observed source behavior: copying `deployment/julia` and the service template alone does not include `deployment/templates/client-simulator.conf.in`, which HIL export reads, or `benchmark/profiles/ryzen-6800h-classic.cpu` and `.threads`, which HEART export reads. Installed entrypoints initially exposed the launcher only. Relocated launch therefore does not establish relocated preparation through the selected campaign/export surfaces.

Remediation agreed with primary: package cold templates, HEART placement assets and Julia CLI entrypoints; resolve assets relative to the installed Julia runtime. Preserve the selected existing sealed-base input boundary. HIL helpers and `hil/Project.toml` are also reachable cold inputs and must stay in the installed package.

Correction independently verified: cold templates and seed HIL environment/helpers now reside below `julia/assets/deployment`, with HEART placement assets under `julia/assets`. Copying the runtime preserves an existing deployed `hil/plant.toml` and dependency directory. A relocated runtime then loaded its own resource root and recursively copied a second runtime successfully. A transient remediation that replaced the whole deployed HIL tree was rejected during review and is not the final implementation.

Required validation: prepare from an installed/relocated package using existing sealed base and explicit scientific dependencies, with source checkout paths unavailable. Exercise HIL, calibration and HEART exports and the four campaign entrypoints. Trace executed programs or provide an equivalent restricted-path discriminator before claiming no Python dependency.

### JMR-005 — Classic campaign identity inventory omitted reused Julia helpers

Affected code: `CalibrationCampaign.orchestration_sources`, `campaign`; `CalibrationMethod.method` frozen-source copy.

Observed source behavior: the initial inventory contained `deployment/julia/*.jl` and its project files but omitted `deployment/hil/*.jl`. Classic analysis executes a helper directly from that omitted directory, and calibration export copies endpoint helpers from it between stages. Consequently the source-invariance comparison could miss a changed executed analysis/helper implementation. Copper had a separate helper snapshot, but the shared Classic inventory did not.

Remediation: shared inventory now includes non-test HIL Julia helpers and available HIL project/manifest files. An independent query confirms `hil/calibration_campaign_analysis.jl` is in the hash map. Expanding the inventory introduced duplicate `Project.toml` basenames in method source copying; the worker preserved `julia/` and `hil/` hierarchy and recursively seals the result. Worker reported a successful 32-file copy smoke check and complete cold Classic method preparation using the retained analysis/client helpers. Worker focused tests report Campaign 70/70 and Copper 31/31; these are worker evidence, not independently rerun totals.

Required validation: alter a copied or executed helper and prove campaign admission/advancement rejects its changed digest. Confirm method preparation and reduction use the same preserved hierarchy and seal. Freeze exact final source identities before installed evidence is recorded.

### JMR-006 — Installation rewrote a sealed Julia entrypoint

Affected code: `Deployment.install`.

Observed initial source behavior: installation overwrote `julia/deploy_cli.jl` without the original shebang, then validated the unchanged exported artifact hashes. Exported packages seal this file, so installation would reject the changed bytes. The small initial install test had sealed only its session file and could not detect this.

Remediation observed during review: installation now preserves an existing entrypoint and launcher. An independent fixture copied the real Julia runtime, sealed `julia/deploy_cli.jl`, installed it, and completed successfully. The fixture ran after the concurrent correction; the pre-correction defect is established by source behavior, not a claimed observed failed install.

Required validation: installation, relocation and reinstallation using real exported artifact inventories; no silent hash resealing of existing artifacts. New generated install files must be clearly separated from sealed producer evidence.

### JMR-007 — Installed qualification gate (closed for selected scope)

This is an acceptance gate, not a newly inferred code defect. At initial review, the delivery record identified installed parity, Python-independent preparation/launch and service checks as pending. Portable unit results do not qualify those surfaces.

Required evidence: sequential installed Classic/Copper FGN/JFG acquisition and restoration/release/shutdown; retained numerical-input parity; installed unchanged HEART bridge exchanges and reset/child-failure cleanup; restricted operational executable path or exec trace; service readiness, SIGINT/atexit cleanup, child reaping and owned-runtime removal; relocated preparation/launch/reinstallation. Bind the exact source/package/binary/settings identities. Finite CPU exchange does not establish correction, physical operation, scientific precision, GPU cadence or hard real-time guarantees.

### JMR-008 — An exited owner can leave its native descendants alive

Affected code: `Deployment._owned_wait`, all cleanup paths that call it for detached owner groups.

Observed: `_owned_wait` signals the owned process group only while the group leader is `process_running`. A portable detached shell fixture spawned `sleep 30` and exited successfully. Calling `_owned_wait(owner, 0)` then returned while the known descendant was still alive (`kill(descendant, 0) == 0`). The reviewer terminated only that fixture descendant. An abruptly lost HEART Julia owner can similarly leave the native HEART child running and holding its listener, despite a deployment cleanup record/runtime removal. This pattern is inherited from the Python supervisor; the selected RTC-DEV-021/028 owner-loss cleanup contract still requires it to be resolved.

Remediation: terminate and verify the owned process group even when its leader has exited, preserving ownership and finite cleanup bounds. Account for group descendants and process reaping; do not signal unrelated processes. Record cleanup failure if living owned descendants cannot be removed.

Correction independently verified: the launcher enables Linux child subreaping, retains each owned group ID, checks adopted living descendants in that exact session/group, and terminates/reaps those descendants after leader exit. The Base.Process leader is excluded from manual `waitpid` to preserve libuv ownership. Repeating the independent detached-shell fixture now reports `descendant_alive_after_cleanup=false`.

Required validation: detached owner exits normally or is killed while its child remains; cleanup removes the living descendant, observes finite completion and preserves an unrelated control process. Also repeat normal HEART owner shutdown/reset and service stop to ensure the stronger cleanup does not break graceful behavior.

### JMR-009 — Campaign abort can kill its launcher before owned cleanup completes

Affected code: `CalibrationCampaign.run_stage` final cleanup, `Deployment.stop` and owned process cleanup bounds.

Derived: the Julia campaign sends SIGINT and waits only 10 seconds before SIGKILL of the launcher. Its cleanup may legitimately require source pause (8 seconds), native control operations (up to 8 seconds each), and per-owner graceful/TERM/KILL waits. Each scientific owner is a separate detached process group. Consequently a campaign can kill the launcher while it is still performing authorized bounded cleanup, leaving groups outside the launcher's own process group. Unknown endpoint outcomes use this final path directly. The retained Python campaign allowed 45 seconds, so the new 10-second grace also reduces the prior cleanup allowance.

This is a source-derived budget mismatch. The reviewer has not claimed a measured live campaign orphan caused by this path. JMR-008 independently establishes the adjacent descendant-cleanup defect with a portable fixture.

Remediation: use one explicit cleanup bound shared by supervisor and campaign, with enough time for the bounded shutdown protocol and a safe fallback for owned descendants. Keep cleanup grace separate from successful acquisition deadlines and report cleanup failures. Avoid extending an expired acquisition allowance.

Correction reviewed: campaign and deployment now share `CLEANUP_TIMEOUT_SECONDS = 300`, equal to service `TimeoutStopSec`. The primary selected cold-cleanup headroom above a reviewed explicit-wait bound of 148 seconds for at most four owners. The maximum source-failure branch sums pause 8 + native controls 24 + RTC 18 + source 18 + fallback groups 20 + final six groups 60 = 148 seconds. Successful earlier group waits make later waits immediate; incompatible branches must not be double-counted. Filesystem/proc/syscall/JIT overhead is outside this analytical sum, so it is not a hard operating-system deadline claim. This is analytical evidence; no independent delayed whole-campaign abort execution is claimed.

Required validation: a portable delayed-cleanup fixture whose completion exceeds 10 seconds but is inside the declared supervisor bound; unknown-outcome abort; subsequent owner-group reaping and owned-runtime removal. Observe final failure evidence without falsely setting restoration/release confirmation.

### JMR-010 — Generic typed JSON parsing changes numeric values and types

Affected code: `Common.read_json` and typed `JSON3.read(..., Dict{String,Any})` in deployment, HEART owner and calibration receipts.

Observed before correction: `{"x":4611686018427387903}` parsed as integer `4611686018427387904`; `{"x":9223372036854775805}` parsed as `Float64`. Both typed and untyped default JSON3 parsing interpreted `1.0` and `1e0` as integer `1`. The retained Python parsed-value checks distinguish integer and floating tokens; the Julia conversion could silently change large request/run identities or admit a floating token where the protocol requires an integer.

Remediation: one shared `Common.parse_json` uses public JSON3 RawType/RawValue and StructTypes interfaces for grammar parsing while preserving numeric tokens. Integer tokens parse exactly as Int64 or UInt64; out-of-range integers reject; decimal/exponent tokens remain finite Float64. Recursion has an explicit 64-level bound. Production typed-Any reads were routed through this shared parser.

Independent pass-after: nested values `4611686018427387903`, `18446744073709551615`, `1.0`, `1e0` retain respectively the exact Int64, exact UInt64 and two Float64 values. This confirms value and type preservation. No alternative scientific JSON format or estimator is introduced.

Required validation: recipe and protocol admission using literal floating identities, UInt64 boundaries, large distinct IDs, nested arrays, malformed JSON, nonfinite values and unsupported nesting. Existing domain-specific integer/finite validators must still reject invalid numeric categories after parsing.

### JMR-011 — Exposure-end overflow can admit backwards capture chronology

Affected code: `CalibrationCampaign.verify_capture` next-exposure and final-cursor arithmetic.

Observed: a valid two-exposure fixture was changed to first exposure start `typemax(Int) - 4095`, duration 5000 ns, second exposure start 0, duration 5000 ns, and completion model cursor 5000. The startup exposure was 5 μs and the manifest was correctly rehashed. `verify_capture` accepted this backwards chronology because adding the first exposure duration overflowed signed Int and made the next-start lower bound negative. This is a portable malformed-evidence discriminator, not an observed live model clock wrap.

Remediation: widen sequence and model-time additions before comparing; require derived cursor values to stay within the declared UInt64 domain. Do not permit modular overflow to establish exposure ordering.

Correction independently verified: sequence comparisons and exposure-end addition now use Int128, and final model time must fit UInt64. The same backwards-time manifest now rejects with `capture is not consecutive`.

Required validation: the same malformed manifest must reject; valid high-range chronological metadata must either preserve exact values or reject explicitly at a documented bound; ordinary Classic/Copper fixtures must continue passing.

### JMR-012 — Helper-process notifications do not satisfy NotifyAccess=main

Affected code: `Deployment.notify`; `deployment/pipewireao-rtc@.service.in`.

Observed: the launcher invoked `systemd-notify --pid=<launcher> --ready`, while the unit declares `NotifyAccess=main`. The installed systemd-notify(1) manual states that sending with another PID requires sufficient privilege and that an unprivileged invocation falls back to its own PID. A portable Unix datagram server enabled SO_PASSCRED and observed actual sender PID 1705715 (helper), requested/payload MAINPID 1705714 (parent), UID/GID 1000, and helper exit 0. Passing the parent PID in the payload therefore does not make the sender the main process. The main-only manager policy rejects this notification; startup cannot be qualified by helper exit status.

The credential probe used `--no-block` to avoid needing a service-manager barrier responder. This does not change the sender-identity issue. No actual user service was started by the reviewer.

Remediation: send through a launcher-owned public systemd notification interface, for example `sd_notify` in the launcher process, while retaining the sole-owner notification policy. If changing NotifyAccess instead, explicitly reassess notification ownership and attribution rather than assuming MAINPID changes credential checks.

Correction independently verified: `Deployment.notify` calls public `sd_notify` through libsystemd in the launcher process. A fresh SO_PASSCRED receiver observed sender PID 1706874 equal to the Julia process PID, UID/GID 1000, exact READY/STATUS payload and exit 0.

Required validation: a portable SO_PASSCRED receiver must observe the launcher's own PID; actual user-service readiness and clean stopping must work under NotifyAccess=main and ordinary user credentials.

### JMR-013 — Launcher identity check used a nonexistent Process field

Affected code: `CalibrationCampaign.run_stage`, readiness PID association.

Observed by the primary during first installed foreground validation: after approximately 54 seconds the launcher reached READY, then campaign admission failed because the new identity check accessed `process.pid`, which is not a field of Julia `Base.Process`. This happened before accepted exposures. The retained failed run is identified as `fgn-reference-v2`; it must remain failed evidence. The reviewer independently read `~/.cache/rtc-julia-calibration-migration-20261003/fgn-reference-v2/dark-evidence/stage-result.json`: it records the Process FieldError, all three confirmation flags false and launcher exit 0. Stage-result SHA-256 is `5f1d5f35f770bc25bda2292d98e543aa82ab320bb4d00ef8419dfaa25b5fabc3`; sibling deployment-log SHA-256 is `2230bf74507f553b948544d0314f31ec34173b9d4322a42ee3fcd7c749b27963`. The primary observed launcher SIGINT exit 0 and removal of its owned runtime instance.

Remediation source-verified by the reviewer: the comparison now uses the public `getpid(process)` API while retaining the positive integer/current-launch identity check. A successful installed repeat is required before marking the behavioral gate passed. This finding also demonstrates why utility/module tests and CLI loading alone cannot replace execution of the complete stage orchestration path.

Required validation: retained fail-before stage result/log, successful same-path installed readiness association and acquisition, and a portable fake-launcher regression exercising `run_stage` rather than only its helper functions.

### JMR-014 — Copper HEART configuration incorrectly required Classic TELOFF

Affected code: `HeartConfiguration.prepare_heart_configuration` required section admission.

Observed by the primary/worker while replaying an actual retained Copper template: the new shared required-section list included `TELOFF`, which that maintained Copper template does not contain. The retained Python Copper path did not impose that Classic section requirement. Small synthetic emitter tests therefore passed while real Copper cold preparation rejected the maintained input.

Remediation source-verified: required sections are now declared per instrument; Classic retains TELOFF while Copper does not require it. Two focused regressions encode that distinction. Complete cold preparation of both actual maintained templates and the installed unchanged HEART exchanges remain the relevant behavioral gates.

Required validation: retain the original Copper template identity; successful Classic/Copper preparation without scientific/controller changes; native parser/owner/bridge validation through the declared installed route.

### JMR-015 — Redundant socket flush races an immediately closing peer

Affected code: `Deployment.control`, `CalibrationCampaign.request!`; the same unnecessary flush pattern was also removed from `serve_control` replies.

Observed: the control protocol permits the native peer to reply once and close. With Julia 1.12, unbuffered socket `write` completes the payload write; a following `flush(::LibuvStream)` issues a separate zero-byte `uv_write`. If the peer has already replied and closed, that second write can fail with EPIPE before the client reads the valid reply. The retained `heart-cold/control-phase-probe-result.json` shows the complete 72-byte request received and replied to within 0.2 ms of accept, successful client payload write, then failure specifically at `flush`. Holding the peer open for 500 ms avoids the failure. Its SHA-256 is `e24c6f02163ee40d6197ddcce75fcb1861e47779bd620c4c9b43e613eb4d1cf4` under `~/.cache/rtc-julia-calibration-migration-20261003/`.

Independent discriminating replay: a separate Python Unix-socket peer immediately answered and closed. A fresh Julia process using the retained phase probe failed its first call at `flush` with EPIPE. A fresh process using the identical probe with only flush omitted completed both calls. The corrected actual `Deployment.control` then completed eight consecutive immediate-close requests. No native owner or live data path was started by the reviewer.

Remediation: remove the redundant flush on these unbuffered one-request control sockets while preserving bounded reply reads, correlation checks and the unchanged protocol. The reviewed source implements this correction. An additional independent probe then established the same defect in `CalibrationCampaign.request!`: an independent peer received a complete release request, sent a correctly correlated `released` completion and closed; the actual client failed with a nested EPIPE at `calibration_campaign.jl:291` in `flush`. The maintained `calibration_server.jl` closes immediately after terminal release, so this close behavior is part of the existing protocol. The worker removed the endpoint flush. The reviewer reran the identical `/tmp/jmr_endpoint_flush.py` probe against current source: it received the same complete request and the client accepted the correlated `released` result. This establishes independent fail-before/pass-after evidence for the terminal endpoint as well.

The retained native diagnostic `qualification-control-io.trace` (SHA-256 `9eb500691176d6befc614069123b4fb5a8a7389d15543139f2ffee58f3a9276d`) shows connect at 1791082307.115351 and the full request write at 1791082307.115649, followed by a zero-byte write at 1791082307.136648. It does not establish the previously considered two-second request-read timeout explanation. That diagnostic run intentionally had no calibration client and later reached the endpoint accept timeout; it is not successful functional exposure evidence.

Required validation: fresh-process immediate-close regression and successful installed control/admission plus cleanup on the newly sealed source. Portable fail-before/pass-after evidence is complete; installed qualification remains separate.

### JMR-016 — Asynchronous process launch discards child diagnostics

Affected code: `Deployment.spawn`.

Observed: Julia `Base.run(command; wait=false)` defaults child streams to `devnull`, unlike retained Python `Popen`, which explicitly discards stdin but inherits stdout/stderr. The initial Julia spawn therefore lost native and owner diagnostics from the supervisor's retained log. Julia 1.12 `base/process.jl` documents and implements `spawn_opts_swallow` for the asynchronous branch. An independent shell-sentinel experiment using the old call returned exit 0 with both captured streams empty.

Remediation: launch through `pipeline(...; stdin=devnull, stdout=stdout, stderr=stderr)` while retaining asynchronous execution, placement, detached process groups and PID ownership. The reviewer inspected the focused source change and exercised actual corrected `Deployment.spawn` in a temporary private directory: exact `review-stdout` and `review-stderr` sentinels were retained on their respective streams and the child exited 0. This restores existing diagnostics; it introduces no new data-path logging.

Required validation: actual spawn stdout/stderr capture regression and retained installed owner errors/shutdown diagnostics. Portable fail-before/pass-after evidence is complete.

### JMR-017 — Exact numeric JSON parser admitted invalid JSON token syntax

Affected code: `Common.parse_json`, following JMR-010's numeric-preservation correction.

Observed independently against the sealed v4 Common source (SHA-256 `b5c657b7faaa4fd17bc0de5b800cc80bdfb6b6c9287e4e0d1651e101a1036ae7`): `+1` parsed as integer 1, `01` as float 1.0 and `true garbage` as true. The delegated parser's permissive scalar behavior and prefix consumption weakened the original standard-JSON admission contract. This is a distinct grammar defect; JMR-010's demonstrated exact integer preservation remains valid.

Remediation: enforce full top-level token consumption with the public JSON3 RawType interface, admit only JSON ASCII whitespace, use strict integer/decimal/exponent syntax, and handle literal/string tokens explicitly while leaving structural parsing to JSON3. The current source does so without adding an independent structural parser.

Independent pass-after: 18 malformed scalar, nested, trailing-data and whitespace inputs rejected, including all three original cases. Additional malformed structure probes rejected trailing commas, missing separators, unquoted keys and an unescaped control character. Valid JSON whitespace, UInt64 maximum, decimal/exponent floating tokens and arrays of literals/strings still parse with the expected values/types.

Required validation: retain malformed scalar/nested/trailing-data regressions beside exact-number tests and run the shared parser through installed control/endpoint exchanges. Portable fail-before/pass-after evidence is complete; installed evidence must identify the corrected source.

### JMR-018 — Cold HIL export cannot replace dependencies already present in the sealed base

Affected code: `HILExport.export_package`, package dependency copying.

Observed during the primary/worker installed cold preparation: maintained Classic/Copper bases already include `hil/packages/AdaptiveOpticsCalibration/src`. HIL export first copies that base into isolated staging, then `copy_package` tries to copy the selected package's `src` into the existing destination. `ScienceExport.copy_tree` correctly refuses the existing destination, so cold preparation fails before the output package is published. Retained fail-before evidence is `~/.cache/rtc-julia-calibration-migration-20261003/heart-cold/v6-prep/classic-fgn-hil-cpu.stderr.log`, SHA-256 `3c6344b80a9291f2e3f9bfbb1b9fb1f9ddae2005864215d7b3c0f6ea94c8c912`; the reviewer independently read the stack trace through installed v6 `hil_export.jl:771`.

Remediation: replace only the dependency inside the newly created staging tree before copying the selected source. The original sealed base and external source must remain unchanged, and stale files from the old dependency must not survive. Current `replace_staged_package` is called only from the isolated export staging path for the six declared dependency names.

Independent discriminating fixture: copy a sealed base containing an old dependency into a private temporary staging directory; the original `copy_package` call rejects its existing `src`. The corrected staged replacement succeeds, contains the selected new file, removes the stale old file, and preserves the original sealed base and selected source bytes. `/tmp/jmr_hil_reexport_probe.jl` passed without launching any native owner. Full installed cold export of the actual maintained bases remains required after resealing the corrected runtime.

### JMR-019 — Direct source install omits the cold preparation resource closure

Affected code: `Deployment.install` fallback for a sealed science package with no Julia runtime, `ScienceExport.copy_deployment_runtime`, module include order.

Observed by the primary on a maintained science base: direct installation from the checkout succeeded but lacked `julia/assets/deployment/{hil,templates}`. The source-only installer fallback copied `deployment/julia` itself, whereas those resources originally live beside that source directory and are added only by the shared packaging helper. An independent fixture reconstructed the pre-fix source-only runtime from the immutable installed v6 source, omitting its generated resource snapshot to match the checkout layout; installing a minimal sealed non-Julia package succeeded with both cold-resource checks false.

Remediation: use `ScienceExport.copy_deployment_runtime` for that missing-runtime fallback, with `copy_service=false` so sealed root service bytes remain intact. Include ScienceExport before Deployment and import it explicitly. Preserve a descriptor-sealed `bin/pipewireao-rtc@.service.in` instead of overwriting it, and revalidate the relocated profile. The changes affect cold packaging and module assembly, not runtime process ownership or acquisition algorithms.

Independent pass-after: the same non-Julia package installs with HIL Project.toml and core template resources present, relocates to a path containing spaces, and reinstalls successfully through its own installed Julia module. A second fixture seals deliberately distinct root and bin service-template comments; both survive install and relocated reinstall byte-for-byte. Existing runtime entrypoint bytes remain covered by JMR-006. No native owner or live data path was started by these probes.

Follow-up observed before final freeze: preserving the original service files is insufficient. On relocated reinstallation, the installer selected the sealed package-root service template ahead of a runtime-bound policy template. An independent fixture sealed root/bin templates with `Type=simple`, `KillSignal=SIGTERM` and `TimeoutStopSec=7`. Initial install preserved the input bytes/resources; relocated reinstallation generated that obsolete policy and failed the required `Type=notify` assertion. `/tmp/jmr_generated_service_probe.jl` reproduces this gap. The required correction is an immutable service template inside the runtime resource snapshot and explicit installer precedence for that version-bound template. Preservation of sealed historical files and generation of the current runtime unit are separate checks. The worker added the service template to `julia/assets/deployment/` even when historical root service copying is disabled; both runtime copying and unit generation prefer this trusted SDK resource. The reviewer inspected those focused changes and reran the identical probe: relocated reinstallation now generates `Type=notify`, `NotifyAccess=main`, `KillSignal=SIGINT` and `TimeoutStopSec=300`, resolves all launcher/prefix/FITS/CPU placeholders, preserves both obsolete sealed input templates and carries an SDK service-template SHA-256 identical to the current source template. This is direct fail-before/pass-after evidence for generated unit policy, beyond historical file preservation.

Required validation: complete installed cold export and entrypoint loading without checkout resource fallback, unchanged descriptor hashes for previously sealed files, relocated/reinstalled runtime, and final installed service qualification. Portable direct-install/resource/relocation checks pass; the final installed operational closure is still assessed separately.

### JMR-020 — Compact JSON emission is incompatible with the selected native SPA module parser

Affected code: HIL core and HEART core/client configuration emission.

Observed during the first final v7 Classic HEART foreground attempt: the private PipeWire core exited 254 before frame admission, reporting malformed `context.modules` and then missing `spa-node-factory`. Earlier FGN/JFG acquisition reused copied core configurations and therefore did not exercise this newly emitted HEART core path.

The worker's controlled native probe used equivalent compact and indented parsed configurations, apart from intentionally distinct private `core.name` values. The reviewer independently compared every decoded field: module arrays, arguments and other properties are equal. Compact emission exited 254 within two seconds with the same parse error; Python indent-two emission remained alive for two seconds and exited 0 after owned SIGINT. Retained report `heart-cold/v7-prep-02/core-format-probe/report.json` SHA-256 is `b9c3f7c8c9332cd9283979e44bec215412c4e46186cf0c2b0f8555727db06daf`. This establishes a formatting interoperability defect for the selected native parser. It does not require changing native PipeWire or HEART source.

Remediation: dedicated `ScienceExport.write_spa_config` validates finite values, emits JSON3 indent-two configuration with a final newline, and checks parsed value equality before writing. Exactly three call sites use it: HIL core, HEART core, and HEART RTC client. Compact machine-artifact/session/protocol serialization remains unchanged.

Independent correction checks: the reviewer emitted the actual retained compact core object through the new helper, verified exact parsed-object equality and separated module-array delimiters, and confirmed nonfinite input rejects before overwriting the valid configuration. The worker's actual Julia-emitted native probe also remained alive for two seconds and exited 0 on owned SIGINT; the reviewer read `julia-pretty.probe.json`, SHA-256 `2609701a5b52da12deb7c6b298f3a621b87f7f8e9f2c6984c015151469975b56`. The reviewer did not launch a native core. Final installed v8 HEART foreground/systemd runs use freshly emitted configurations and pass, as independently verified below.

## Review coverage and limits

| Area | Inspection result / evidence boundary |
| --- | --- |
| Transitive Python calls | New Julia orchestrators call shared Julia exporters, existing Julia analysis/AOC, native parser/RTC/HEART and ordinary system utilities. `.py` mentions found in runtime modules refer to removing legacy installed files. Existing benchmark generator and Python audits remain development inputs. Final cold exports and foreground runs have no-Python execution traces; service evidence uses the same sealed launcher under restricted PATH. |
| Recipe, Float32 and measurement contracts | Classic/Copper recipe bounds, represented Float32 conversion, Copper interval collapse checks, actuator ordering, capture channel sizes/layout/hashes and units inspected. Integer overflow findings are tracked as JMR-003. |
| Scientific estimator authority | Existing `calibration_client.jl` and analysis helpers continue to call AOC. The migration adds orchestration and export rather than a second estimator. No coefficients or calibration acceptance decisions changed by the reviewer. |
| Endpoint outcomes | Request version/run/serial and expected completion shape are checked. Unknown timeout/disconnect/malformed outcomes clear `can_restore`; known `invalid_evidence` rejection permits bounded restoration. Restored reference must match represented Float32 coordinates without clipping before release. |
| Capture advancement | Copper multi-batch path copies and verifies completed capture before the next batch adoption. Capture manifests bind generation, exact next sequence, settled model time, exposure duration, channels and hashes. Corrupted fixture and full live acquisition remain distinct evidence. |
| Source controls and lifecycle | Serialized broker coordinates source pause before consumer stop and reset only after stopped native state. Source ACK identity/state and regular-file ownership checked. Unknown coordination faults admission. Native owners use private runtime and detached owned process groups; final finite foreground/systemd SIGINT cleanup is independently checked below. |
| Placement and resource admission | Child affinity/thread policy, inherited RT/memlock rights and QoS descriptor handling inspected. Supervisor affinity has JMR-002. CPU checks do not qualify scheduler latency. |
| HEART | New parser/configuration transport and owner retain unchanged HEART executable invocation, required runtime flags, bounded command acknowledgements, child-owned listener check and reset restart. Final actual native parser, two-generation exchanges and owner cleanup are verified below; flags have command acknowledgements without effective readback. |
| Package identities | Export seals graph, payload and runtime assets; Classic helper omission and install mutation tracked above. Dynamic runtime JLL override uses private depot and selected installed library directory. Relocation fixtures and final installed cold preparation pass with their source identities bound. |

## Remaining hypothesis for fault qualification

SIGINT arriving while the launcher is already executing `stop()` (for example after spontaneous owner loss) could interrupt the cleanup body before the unconditional final runtime removal. This race has not been established by a discriminating experiment and is not represented as a confirmed finding. A targeted interrupted-cleanup fixture, or bounded cleanup with interrupt masking, can resolve it before broad interruption claims.

## Portable independent observations

Review probes were temporary files under `/tmp` and were not installed or committed. No live owner or native data path was started.

- Deadline probe: one-second-expired `UInt64` deadline returned `30.0` before correction; identical call threw after correction.
- Affinity probe: exact leader-only placement left ten additional native tasks on CPUs 0-15; corrected all-task placement constrained all 17 tasks in an independent `--threads=4` process after spawned work and GC.
- Export bounds probe: empty huge-shape payload and huge wrapped HEART readout accepted before correction.
- Installation probe: real runtime entrypoint sealed in fixture; corrected install succeeded without modifying its bytes.
- Descendant probe: exited detached shell owner left its known sleeping child alive before correction; corrected subreaper/group cleanup removes it. No live deployment was involved.
- Notification probe: unprivileged helper sent its own SCM_CREDENTIALS PID despite the parent MAINPID payload; corrected direct sd_notify sends the Julia/main process credentials.
- Exact JSON probe: corrected shared parser preserves large Int64/UInt64 identities and lexical floating-token types.
- Cold-resource probe: package HIL sentinels survive runtime copying; relocated runtime can recursively copy another runtime from its own assets.
- Capture chronology probe: signed exposure-end overflow admitted a backwards timestamp sequence before correction; the same fixture now rejects.
- Control socket probe: original flush fails after an immediate peer reply/close; identical no-flush probe and eight actual corrected control calls pass.
- Child diagnostic probe: asynchronous default streams discard sentinels; actual corrected spawn retains exact stdout/stderr.
- JSON grammar probe: sealed v4 source admits three malformed scalars; corrected source rejects the same inputs and broader malformed cases.
- Helper inventory query: corrected shared map includes `hil/calibration_campaign_analysis.jl`.

## Reviewed source snapshot

Snapshot UTC: `2026-10-04T02:45:08.833799+00:00`. These 47 files identify the implementation reviewed after the reported corrections. Aggregate SHA-256: `508cb5f6c6531618b3ff87cf4408c41bc6b195f374cf8e740f63d5a8dbee17b6`. The aggregate hashes sorted UTF-8 records of `relative-path`, NUL, lowercase file SHA-256 and newline. Unchanged reused acquisition/analysis helpers are included explicitly.

This is the initial code-review snapshot, not a claim that all later installed evidence used it. Final qualification must bind its own exact source/package identities and perform a focused independent review of changes after this snapshot. Earlier runs must retain their original identities.

| File | SHA-256 |
| --- | --- |
| `deployment/calibration_campaign.jl` | `436b35f2eb9f68bcbc8599ee22d5ed6603fa169ed208ab0864f947ddc215ede6` |
| `deployment/calibration_method.jl` | `c7bffa763318fcb6e0c75bc3582ce4aa540d42ede44e71554ba5fdcfce82f2e8` |
| `deployment/copper_quality.jl` | `de6a718b50a100d9b06ac1a5e416b8f756e0f1ac7825376ded0f5bcf199591a2` |
| `deployment/copper_reference.jl` | `18515d50cafb3d8d1269df3165b4d3b90ea15310c0d347fdec9bb20b37f00047` |
| `deployment/deploy.jl` | `41bc3b6cd7b73e06edd941ef069cf7fe5d35e55250975a9ec94c2043de72e8b5` |
| `deployment/export_calibration.jl` | `056b8b475b5767e8afdb96b6bbba6f6769142c196bfa2afab225ca16187db1ca` |
| `deployment/export_heart_hil.jl` | `d7cbfd1e1ed5bada0c8aa7428de2ecb02f207af37969656301478e876fbfe070` |
| `deployment/export_hil.jl` | `d1abed6d9079afd20d58763f6c4b4f710c2681f15db549b7227904bac21fa347` |
| `deployment/hil/Project.toml` | `8ef5a246a2d72463c0a077fb22e1336b51758f12977bffe426e753acbd245cad` |
| `deployment/hil/analyze_correction.jl` | `0107322ba291c9853d9784a08f11d24d3ad11fe09446ebfb9bf706107760db5e` |
| `deployment/hil/calibrate_detector.jl` | `1fd91b3ff71549e48ae671f83e57aba31b5d4dc91163f5fafbbfbd7645cdfae1` |
| `deployment/hil/calibration_acquisition.jl` | `393160d71c0a0096e630852a02cbf6adeae1dcc1325e26388a9ba3aa8187a8ca` |
| `deployment/hil/calibration_campaign_analysis.jl` | `a0997f6c414b6860d8aa8cd0eb3b1ef91cda5c04a614482826030ade2d0f8412` |
| `deployment/hil/calibration_client.jl` | `0625169579554d9afcf52ed04b29ba0110d484a9b11c6a51289c7c8adde20174` |
| `deployment/hil/calibration_method_analysis.jl` | `d27274c5b55e8d5a4cd9b231405e719163cca629c35cafaa773fab2ee1bba71c` |
| `deployment/hil/calibration_owner.jl` | `f9554d4ee617541f456bb803f513721a1d7369c1ab48efc320fd053097b8a32c` |
| `deployment/hil/calibration_quality_analysis.jl` | `813c4355c423dcfc310ce39df19f3a6db646eb2a5c65c99f9fbb247d1ffd6fb2` |
| `deployment/hil/calibration_reference_analysis.jl` | `ce51e54b71140a628d36c96b99c056a469bdde568a10be18b8b3a6384f135201` |
| `deployment/hil/calibration_server.jl` | `095c91ad77c20ed80b75c2882afff9b391c5aee7048fc399ea0f3742e4be4fc7` |
| `deployment/hil/correction_truth.jl` | `598484d85d05d38cf517ac46a8705aaea79452555aff852b3f6c396140fe9835` |
| `deployment/hil/heart_owner.jl` | `57636d32145132d81eb1b5cfba04d9411f1b8a1f4c6d61c9189d8f9cbdeb8de5` |
| `deployment/hil/owner_protocol.jl` | `3542bef6ec26f35b7eb77373783ce78ca58c7b4112efd81fc2839fe72af438e9` |
| `deployment/hil/simulator.jl` | `0be5fcef8d4040d0836eb884d90144ac661b9c02cca3d8fb1842a7196da7c2cb` |
| `deployment/julia/Manifest.toml` | `7dd1fe3fe00c84d75f3c22e7ac8d0bc133a012baaa6075904060278d44da44b3` |
| `deployment/julia/PipeWireAODeployment.jl` | `b6892a408045e37fb8d689ab76c42d97d8848d8fa60f832768794d52e1ac6d26` |
| `deployment/julia/Project.toml` | `7d02ad297a9a8e0c2da263fe55b1f0ddae94312f68ec63f4342f7dbfea4ba050` |
| `deployment/julia/assets/ryzen-6800h-classic.cpu` | `ea699f6cec246867e0b6be95af91730e1c77bfb93afb00736b5ef68782b92cd1` |
| `deployment/julia/assets/ryzen-6800h-classic.threads` | `c654a6827748d09557fdb2fd5753e265d3de2022b4e03de44e03cee03d3b00e7` |
| `deployment/julia/calibration_campaign.jl` | `cdb280c565727f0e77f3a1e240c25e11cb96da08ad0aa6812ebb4840355c1ab7` |
| `deployment/julia/calibration_export.jl` | `0aa85b0fec2f7aa9808c858386a19965c8d8562cda84994553ea1f45d9abbea7` |
| `deployment/julia/calibration_method.jl` | `62005ff4c53333497e5e552c3fd4bacc58715d27c642cccf5d441f1651daa7a3` |
| `deployment/julia/common.jl` | `b5c657b7faaa4fd17bc0de5b800cc80bdfb6b6c9287e4e0d1651e101a1036ae7` |
| `deployment/julia/copper_quality.jl` | `91e0b54136daf4b1de75e3637e4d341d85fe9f46b37665f8777c9d9fb677ee8a` |
| `deployment/julia/copper_reference.jl` | `c43fdd754576a5973392651959d65f4f4e275acae1fe83a6a6a2c19f05ebf633` |
| `deployment/julia/deploy.jl` | `cfb09b6d50e69e3ace1ac654b43f59fdd84c9a249bdf5e945b8b33cdbca52c49` |
| `deployment/julia/deploy_cli.jl` | `f29f0e184dbf389ccdce36da48631c73468685a27892edb98b638bcf6cd00219` |
| `deployment/julia/heart_configuration.jl` | `bb2e6e5b8a06948a9c6258b07c9c401307b6e6fc0c4ca7702b04f80d8f801264` |
| `deployment/julia/heart_export.jl` | `5be549dca88c25d6fbba29dc9bc14ad99391130eca596a4caa442783f2b8c030` |
| `deployment/julia/heart_owner.jl` | `c4639985009c7b6ccd1c2f4a48ae503af0c4aa57764c7c2401919c5e997e9390` |
| `deployment/julia/hil_export.jl` | `2ef9b6af16bf12186832477040532df094444abec9e26d3b6900e0c5ac0d8c79` |
| `deployment/julia/placement.jl` | `e011bec3b7a437596b06e51381beb0b902eb660f0bb7590a5f004cad0cbacec5` |
| `deployment/julia/science_export.jl` | `150957cd6cc1af0eb244581c080951bb147949cf3b8d60c27f8ae2b3aeb6a2f4` |
| `deployment/pipewireao-rtc@.service.in` | `14474212156609ae312aa27619621167098bf641c7294360165f0fa7726199d8` |
| `deployment/templates/client-julia.conf.in` | `550444041f0f3f871882c60be24876928ae440bad949b5d9de238c02b55ee3cc` |
| `deployment/templates/client-rtc.conf.in` | `940781ad9a9b8cc117078e6d67fd71b5c36f43f61bfea800a230d98248f89d22` |
| `deployment/templates/client-simulator.conf.in` | `a16f83e8279f71c28c64b44a67c43761813ee970d25038361ee9c32cfac8f719` |
| `deployment/templates/core.conf.in` | `1641fa5f4bc5d47e397a13f82e813a09148ad9aa08cf3fc9eb9ead7fa9b8aa42` |

## Targeted follow-up source snapshot

Snapshot UTC: `2026-10-04T03:02:48.609175+00:00`. The same 47-file inventory now has aggregate SHA-256 `31529925e67393a92d9dfdc955c72bb29d3921c076edc1ce71c30145b8a14a82`. Only the following production files differ from the initial snapshot above; both focused diffs were independently reviewed. Earlier installed v4 evidence keeps its own source identities and is not relabeled as qualification of these corrections.

| Changed file | SHA-256 |
| --- | --- |
| `deployment/julia/common.jl` | `aeaf603fce95c25c166279947d946ef9e207a16f37f200d7e083863647dad328` |
| `deployment/julia/deploy.jl` | `fb66d572555466d30320254ece701ec0d5474b57cce80003b94a2df4e21860f7` |

## Terminal endpoint correction source snapshot

Snapshot UTC: `2026-10-04T03:11:47.506865+00:00`. The same 47-file inventory has aggregate SHA-256 `3bf4bbf34cf4fd4aa25947d0878d9b1c15f538899856f8941ceae4eb702bcfa1` after endpoint correction. `deployment/julia/calibration_campaign.jl` now has SHA-256 `30671f0f12c7a67dd872f7f9498e58cb2ac117f4662b1bf88d78e6ff0c11be94`; its sole production change since the prior snapshot removes the redundant endpoint socket flush. All other files retain the prior snapshot identities. The identical terminal-release probe passes. Prior v5 installed runs remain evidence for their own frozen identities; they are not relabeled v6.

## Independent retained Copper numerical audit

The reviewer performed a cold Julia audit of all three eight-exposure stages in new `fgn-reference-v4` and `jfg-reference`, plus prior `~/.cache/rtc-copper-reference-20261003/{fgn-candidate-v2,jfg-candidate}`. No new acquisition was launched. Audit outputs are under `~/.cache/rtc-julia-calibration-migration-20261003/independent-review/`:

- `numerical_audit.jl`: SHA-256 `9df3440f1df8f20c225a95c5f8e6fad1e487e25ec42c3633c1310881a04dd0bb`.
- `numerical-audit-paired.json`: SHA-256 `e5ec2cd854334ea65d5c0df630c52a05ec4cb96e030a328c1947d123e947295e`. It binds the script and every audited recipe, stage result, analysis report, manifest, capture channel and product by SHA-256.

The script reads saved channels in linear row-major wire order, independently calculates Float64 coordinate means and two-pass descriptive sample variance with divisor N−1, and compares published products. It does not call the production AOC reducer. It also verifies capture/product hashes against the producing reports and confirms the retained restoration/release/shutdown flags and stopped result for each stage. These record checks do not independently observe process cleanup.

| Comparison | Published product byte identities | Captured channel byte identities |
| --- | --- | --- |
| New FGN versus prior FGN | 5/5 identical | 72/72 identical |
| New JFG versus prior JFG | 5/5 identical | 72/72 identical |
| New FGN versus new JFG | 5/5 identical | 72/72 identical |
| Prior FGN versus prior JFG | 5/5 identical | 72/72 identical |

Direct calculation gives these maximum absolute differences, identical for all four runs: dark Float32 mean exactly equal; dark Float64 sample variance 4.440892098500626×10⁻¹⁶ ADC²; training Float64 sample variance 6.938893903907228×10⁻¹⁷ normalized-pixel²; qualification Float64 mean 2.7755575615628914×10⁻¹⁷ normalized pixel. The direct Float32-rounded training mean differs at four of 3600 coordinates, at most one Float32 ULP (1.862645149230957×10⁻⁹). A separate exact-rational probe confirms all four direct means lie exactly halfway between adjacent Float32 values, and a scalar reconstruction of the existing offset-Welford mean reproduces the published rounding. This is present identically in prior and migrated outputs, not a migration difference; no estimator change is proposed.

The direct independent-seed qualification comparison gives maximum absolute residual 0.4097371995449066, RMS 0.09839779975433038 and relative norm 0.08880739336786186. Those reproduce the published descriptive metrics within 2.78×10⁻¹⁷. These are measured-candidate consistency results; they do not establish scientific acceptance, independent samples, a confidence interval, interaction/inverse quality, correction performance or operational cadence.

Exact-midpoint supporting artifact `midpoint_audit.jl` SHA-256: `84a8414d7741946c93dc826153a24630c67f8ac08ae4d7a43da0c113b2496fd7`.

Exact-midpoint supporting artifact `midpoint-audit.json` SHA-256: `df803092e7b857a861f567d57944a532326bd572e53552b0aa6a458150ab8546`.

## Cold HIL dependency correction source snapshot

Snapshot UTC: `2026-10-04T03:18:01.622406+00:00`. The same 47-file inventory now has aggregate SHA-256 `6e08f3c952b664b081b1c2cece82f2d5f277fa9f00d07be29dfa1db897710e29`. Since the terminal endpoint correction snapshot, `deployment/julia/hil_export.jl` changed to SHA-256 `e6c00aa841ffd80d901a59886cd863b4d52c5fb1bf150c387b395d79bc402c6c` for JMR-018; the focused helper/call-site change was independently inspected and the staged-copy fixture passed. Earlier installed evidence retains its original source identities.

## Direct-install resource correction source snapshot

Snapshot UTC: `2026-10-04T03:22:44.444911+00:00`. The same 47-file inventory now has aggregate SHA-256 `49e97b1b9ae0a5c20282d9bb330433507c5ab0dbd00ee3f093f1e6011a897599`. The following JMR-019 files changed since the preceding snapshot and were independently inspected:

| Changed file | SHA-256 |
| --- | --- |
| `deployment/julia/PipeWireAODeployment.jl` | `ec510fe44a12f4fc5c5c6e2b46fcde548298620466c2c5da4885b4e0fde30aa4` |
| `deployment/julia/deploy.jl` | `06bbca4570cc2076ebcd351591b7fffc52e1de7e0ca914842ed2e396a84b5dac` |
| `deployment/julia/science_export.jl` | `b860f8ef22a1aced490af2820db89b89bfbd83b3cb12cac403fa412fab81c3e5` |

A bounded final verification may compose the recorded v5 acquisition matrix with later targeted evidence only while the exact subsequent changes remain the reviewed terminal-flush removal and cold packaging fixes. The final runtime must pass the portable suite, real terminal release and stage cleanup, affected cold exports, source-independent installation, HEART and service routes. Scientific helpers/settings/payload identities must remain bound and unchanged where parity is claimed. This is not a claim that every matrix cell ran on the final revision; any further runtime ownership, configuration or scientific-input change requires renewed impact review.

## Generated-service precedence correction source snapshot

Snapshot UTC: `2026-10-04T03:25:50.439741+00:00`. The same 47-file inventory has aggregate SHA-256 `f2adeebf1c964059450e4e3b63737c6931b15f8c3eef2d069fdb8aed1a528194` after the final JMR-019 precedence correction. The focused changed files are:

| Changed file | SHA-256 |
| --- | --- |
| `deployment/julia/deploy.jl` | `a849a08b0df3534912a21523090a8ec0029f96571c781feb76afd0daccfde6f0` |
| `deployment/julia/science_export.jl` | `bf8a21b5452ce349608c05c3cd09497e986d7f0ad09733088338b1205b34ff6e` |

The service-template source remains SHA-256 `14474212156609ae312aa27619621167098bf641c7294360165f0fa7726199d8`. Independent installed/relocated/reinstalled fixture checks establish that the runtime resource copy has this exact identity and that generated unit policy matches it. Actual manager lifecycle remains a separate installed qualification gate.

## Installed evidence reviewed before final HEART closure

The reviewer independently read and rehashed the completed evidence while the primary retained ownership of live execution:

- `portable-tests-v7.json` records all seven suites exiting 0; corresponding logs show 338 passing assertions. The later final v8 portable record is independently checked below.
- Eight completed acquisition cells comprise Copper reference/quality on FGN/JFG, Classic full campaign on FGN/JFG, and Classic selectable method on FGN/JFG. Copper's four cells and Classic FGN campaign ran the sealed v5 SDK; Classic JFG campaign and both selectable-method cells ran v7. All 18 constituent stage results report restoration, release, public shutdown, exit 0 and stopped/unadmitted state without failure or cleanup errors. Available request receipts correlate version/run/serial. The recorded owned runtime instances are absent. Interaction/method CLI evidence retains ordered responses rather than every individual wire request receipt; this limitation is explicit in the audit.
- `final-v7-stages/qualification.json`, SHA-256 `d9c3e5d1412af7d744bfc155878527e6245d8b4c5ccd2af4f4594fd307bca045`, contains successful FGN/JFG real terminal-stage checks using v7. The reviewer checked all six held/adopted/settled/captured/restored/released completions, stage lifecycle flags, stopped results, absent instances, and the two eight-frame capture payload/hash sets.
- `heart-cold/v7-prep-02/report.json`, SHA-256 `d7dc95ab7d69df9c47307c450a716b46e9738c283bad9f6512aa423478f9c6c4`, covers actual Classic/Copper HIL then HEART cold preparation. The reviewer rehashed all 1757 declared artifacts across the four packages and checked their four descriptor identities. The retained execution traces contain respectively 28/27 HIL and 6/6 HEART execve records with no Python executable. These successful cold exports did not establish native parser compatibility; JMR-020 records the subsequent live failure.
- `audit/audit.json`, SHA-256 `3fff61bd51f9e700c4800065decdb2eeede92d1548560a4b71f19fd90250c857`, binds the primary's Julia reduction/provenance audit. The reviewer rehashed 79 evidence files referenced by that report, checked its script hash and inspected its numerical reconstruction. Independently calculated Python Float64 secants for both new 376×277 physical matrices reproduce its maximum published-matrix residual of 1.82442509544245×10⁻⁷. The new FGN/JFG retained responses yield 737 differing matrix coordinates, maximum absolute secant difference 0.915253182841536 and relative Frobenius difference 0.03320433618126661. The calculations explain the published matrix difference from the retained responses; the cause of the response variation remains unestablished. This does not establish scientific calibration acceptance.

The v5-to-v7 production diff was independently checked: only module assembly order, redundant endpoint-flush removal, isolated cold dependency replacement and direct-install/resource/service-template handling changed. Installed v7 Julia source bytes matched the reviewed checkout. Scientific acquisition/analysis helpers and other selected algorithm modules were unchanged. The v7-to-v8 delta is limited to the dedicated SPA writer and its three configuration call sites. Compositional verification remains bounded to those changes; earlier matrix evidence retains its exact revision, and final native configuration/HEART/service checks must use v8.

The failed initial Classic JFG interaction startup remains failed evidence: loader ENOENT occurred before readiness or endpoint requests while cold preparation overlapped. Local Julia source exposes cache enumeration followed by an unguarded open and global-cache pruning at ten entries; separate traces show private owner compilation and concurrent shared-cache preparation. Existing traces lack deletion events, so external-pruner attribution remains a hypothesis. The later serialized v7 campaign succeeded; that does not prove the original deletion's cause.

The HEART lifecycle harness was reviewed without launching it. It checks two sixteen-frame exchanges separated by stop/reset/restart, native-child generations, exact retained payload hashes, PID/starttime identities, foreground cleanup, and systemd main PID/result/journal plus manager-owned RuntimeDirectory removal. Service no-Python evidence is explicitly the same sealed launcher under restricted PATH; foreground child execution is traced. At that historical boundary, successful final live outcomes had not yet been reviewed. The subsequent final evidence and disposition are recorded below.

## Reviewed v8 source snapshot after SPA writer correction

Snapshot UTC: `2026-10-04T04:08:59.139596+00:00`. Complete current 47-file inventory, aggregate SHA-256 `e813aa3f612515a360379c7f8d5b7c93c3414412f20775cd525da3dc8048244f`. Aggregation uses the same sorted path/NUL/digest/newline rule. Earlier snapshots and installed runs retain their own identities.

| File | SHA-256 |
| --- | --- |
| `deployment/calibration_campaign.jl` | `436b35f2eb9f68bcbc8599ee22d5ed6603fa169ed208ab0864f947ddc215ede6` |
| `deployment/calibration_method.jl` | `c7bffa763318fcb6e0c75bc3582ce4aa540d42ede44e71554ba5fdcfce82f2e8` |
| `deployment/copper_quality.jl` | `de6a718b50a100d9b06ac1a5e416b8f756e0f1ac7825376ded0f5bcf199591a2` |
| `deployment/copper_reference.jl` | `18515d50cafb3d8d1269df3165b4d3b90ea15310c0d347fdec9bb20b37f00047` |
| `deployment/deploy.jl` | `41bc3b6cd7b73e06edd941ef069cf7fe5d35e55250975a9ec94c2043de72e8b5` |
| `deployment/export_calibration.jl` | `056b8b475b5767e8afdb96b6bbba6f6769142c196bfa2afab225ca16187db1ca` |
| `deployment/export_heart_hil.jl` | `d7cbfd1e1ed5bada0c8aa7428de2ecb02f207af37969656301478e876fbfe070` |
| `deployment/export_hil.jl` | `d1abed6d9079afd20d58763f6c4b4f710c2681f15db549b7227904bac21fa347` |
| `deployment/hil/Project.toml` | `8ef5a246a2d72463c0a077fb22e1336b51758f12977bffe426e753acbd245cad` |
| `deployment/hil/analyze_correction.jl` | `0107322ba291c9853d9784a08f11d24d3ad11fe09446ebfb9bf706107760db5e` |
| `deployment/hil/calibrate_detector.jl` | `1fd91b3ff71549e48ae671f83e57aba31b5d4dc91163f5fafbbfbd7645cdfae1` |
| `deployment/hil/calibration_acquisition.jl` | `393160d71c0a0096e630852a02cbf6adeae1dcc1325e26388a9ba3aa8187a8ca` |
| `deployment/hil/calibration_campaign_analysis.jl` | `a0997f6c414b6860d8aa8cd0eb3b1ef91cda5c04a614482826030ade2d0f8412` |
| `deployment/hil/calibration_client.jl` | `0625169579554d9afcf52ed04b29ba0110d484a9b11c6a51289c7c8adde20174` |
| `deployment/hil/calibration_method_analysis.jl` | `d27274c5b55e8d5a4cd9b231405e719163cca629c35cafaa773fab2ee1bba71c` |
| `deployment/hil/calibration_owner.jl` | `f9554d4ee617541f456bb803f513721a1d7369c1ab48efc320fd053097b8a32c` |
| `deployment/hil/calibration_quality_analysis.jl` | `813c4355c423dcfc310ce39df19f3a6db646eb2a5c65c99f9fbb247d1ffd6fb2` |
| `deployment/hil/calibration_reference_analysis.jl` | `ce51e54b71140a628d36c96b99c056a469bdde568a10be18b8b3a6384f135201` |
| `deployment/hil/calibration_server.jl` | `095c91ad77c20ed80b75c2882afff9b391c5aee7048fc399ea0f3742e4be4fc7` |
| `deployment/hil/correction_truth.jl` | `598484d85d05d38cf517ac46a8705aaea79452555aff852b3f6c396140fe9835` |
| `deployment/hil/heart_owner.jl` | `57636d32145132d81eb1b5cfba04d9411f1b8a1f4c6d61c9189d8f9cbdeb8de5` |
| `deployment/hil/owner_protocol.jl` | `3542bef6ec26f35b7eb77373783ce78ca58c7b4112efd81fc2839fe72af438e9` |
| `deployment/hil/simulator.jl` | `0be5fcef8d4040d0836eb884d90144ac661b9c02cca3d8fb1842a7196da7c2cb` |
| `deployment/julia/Manifest.toml` | `7dd1fe3fe00c84d75f3c22e7ac8d0bc133a012baaa6075904060278d44da44b3` |
| `deployment/julia/PipeWireAODeployment.jl` | `ec510fe44a12f4fc5c5c6e2b46fcde548298620466c2c5da4885b4e0fde30aa4` |
| `deployment/julia/Project.toml` | `7d02ad297a9a8e0c2da263fe55b1f0ddae94312f68ec63f4342f7dbfea4ba050` |
| `deployment/julia/assets/ryzen-6800h-classic.cpu` | `ea699f6cec246867e0b6be95af91730e1c77bfb93afb00736b5ef68782b92cd1` |
| `deployment/julia/assets/ryzen-6800h-classic.threads` | `c654a6827748d09557fdb2fd5753e265d3de2022b4e03de44e03cee03d3b00e7` |
| `deployment/julia/calibration_campaign.jl` | `30671f0f12c7a67dd872f7f9498e58cb2ac117f4662b1bf88d78e6ff0c11be94` |
| `deployment/julia/calibration_export.jl` | `0aa85b0fec2f7aa9808c858386a19965c8d8562cda84994553ea1f45d9abbea7` |
| `deployment/julia/calibration_method.jl` | `62005ff4c53333497e5e552c3fd4bacc58715d27c642cccf5d441f1651daa7a3` |
| `deployment/julia/common.jl` | `aeaf603fce95c25c166279947d946ef9e207a16f37f200d7e083863647dad328` |
| `deployment/julia/copper_quality.jl` | `91e0b54136daf4b1de75e3637e4d341d85fe9f46b37665f8777c9d9fb677ee8a` |
| `deployment/julia/copper_reference.jl` | `c43fdd754576a5973392651959d65f4f4e275acae1fe83a6a6a2c19f05ebf633` |
| `deployment/julia/deploy.jl` | `a849a08b0df3534912a21523090a8ec0029f96571c781feb76afd0daccfde6f0` |
| `deployment/julia/deploy_cli.jl` | `f29f0e184dbf389ccdce36da48631c73468685a27892edb98b638bcf6cd00219` |
| `deployment/julia/heart_configuration.jl` | `bb2e6e5b8a06948a9c6258b07c9c401307b6e6fc0c4ca7702b04f80d8f801264` |
| `deployment/julia/heart_export.jl` | `978ae9c1b98877cfc11df1cf7bc6a14302179a048271841a3e876aa9e04b4f79` |
| `deployment/julia/heart_owner.jl` | `c4639985009c7b6ccd1c2f4a48ae503af0c4aa57764c7c2401919c5e997e9390` |
| `deployment/julia/hil_export.jl` | `b929b3ffa57df3827fc2f5756f6e9978fc08a63542b1b8522f30ecf0f79eb796` |
| `deployment/julia/placement.jl` | `e011bec3b7a437596b06e51381beb0b902eb660f0bb7590a5f004cad0cbacec5` |
| `deployment/julia/science_export.jl` | `0978a20a83a6260142089a80cd6ef260bb4cfef8fc45d5d08b8a655c8a5c95db` |
| `deployment/pipewireao-rtc@.service.in` | `14474212156609ae312aa27619621167098bf641c7294360165f0fa7726199d8` |
| `deployment/templates/client-julia.conf.in` | `550444041f0f3f871882c60be24876928ae440bad949b5d9de238c02b55ee3cc` |
| `deployment/templates/client-rtc.conf.in` | `940781ad9a9b8cc117078e6d67fd71b5c36f43f61bfea800a230d98248f89d22` |
| `deployment/templates/client-simulator.conf.in` | `a16f83e8279f71c28c64b44a67c43761813ee970d25038361ee9c32cfac8f719` |
| `deployment/templates/core.conf.in` | `1641fa5f4bc5d47e397a13f82e813a09148ad9aa08cf3fc9eb9ead7fa9b8aa42` |

## HEART dependency-tuple qualification boundary

The final v8 configuration writer passed actual private-core startup, after which the first Classic HEART foreground attempt failed before admission while importing the selected adapter. The embedded adapter revision `39efcf5c2a6a25d65c27433e13ab0f765bc5d056` declares a `PreparedPipeWireCalibration` type bound requiring `AdaptiveOpticsSim.AlgorithmGraphs.PreparedGraphCalibrationBoundary`; the selected AOS package, recorded as revision `d30db3f78d7fad77d0d5e9212b3eee1a34d86244`, lacks that API. The reviewer independently read the offending type bound and failure trace. This is an observed dependency incompatibility, not evidence of a remaining SPA writer defect. No production source or scientific coefficients were changed to hide it.

Retained evidence is `heart-cold/v8-prep/live-classic-foreground/deployment.log`, SHA-256 `bec7a51f21ab6bcfa3dc4f0b20397672f5604436e72e3e3ec623a7196d148edf`, and `result.json`, SHA-256 `e7bd34aa2918c9eb67ceb7e90f320b44d4b4af47b3a60a04cb2a51609a74c8b9`. The record says `passed=false`, launcher exited before the requested state, and final state `failed`/`admitted=false`; cleanup error records are preserved. It must not be relabeled as a successful functional bridge run.

The prior accepted Classic/Copper HEART packages identify adapter revision `277d822979f7709abb55769c76291937868f3e0b`, which does not contain the new missing-API reference. They record the same AOS commit identifier, but **their embedded AOS bytes are not identical to the new package**: the reviewer found 156 versus 157 source files, one added `calibration/map_control_matrix.jl`, and eleven changed files across calibration, control and WFS. Their PipeWireAO Julia revisions also differ. Therefore revision labels alone do not establish reuse of the exact previously qualified dependency tuple.

The primary selected a cache-local checkout of the prior adapter revision for fresh package preparation and full foreground/systemd requalification against the actual selected dependencies. Final acceptance must bind the new package file hashes and be limited to that tested tuple. The adapter39/AOSd30 combination remains known unsupported; broader compatibility and reconciliation of the upstream AOS API are separate work. Scientific calibration acceptance cannot be inferred from language-migration or finite HEART-exchange qualification. The final new live outcomes are reviewed below.


## Final installed HEART evidence independently verified

The final source remains the 47-file v8 snapshot with aggregate SHA-256 `e813aa3f612515a360379c7f8d5b7c93c3414412f20775cd525da3dc8048244f`. The reviewer rehashed all 47 source files, inspected all seven final portable logs, and confirmed 343 passing assertions: common 32, deployment 86, HEART configuration 29, HEART owner 19, exports 71, campaigns 75 and Copper 31. No production source changed after the SPA writer correction.

The final evidence root is `~/.cache/rtc-julia-calibration-migration-20261003/heart-cold/v8-compatible-prep`. Its four cold exports use the installed v8 SDK and actual selected dependencies. The reviewer independently rehashed 2644 sealed artifact entries across those four packages and the two installed HEART packages; compared 1204 scientific-source file bindings and 204 SDK/helper instances; checked all recorded final foreground/cold execution traces for Python executables; and checked 73 file/size/hash bindings in the delivery ledger. The HIL execution projects contain generated dependency selections; original seed project files remain byte-identical in the SDK assets. Executed reused Julia helper files are byte-identical to the reviewed sources.

| Final live result | Result SHA-256 | Independently checked outcome |
| --- | --- | --- |
| `live-classic-foreground/result.json` | `381f1343dfaf546cc1c0c4dca31326d19328f9cad672c49fb306e7d9e896cc50` | Two 16-frame/16-command batches; generation 1 → 2; stopped and unadmitted; cleanup complete |
| `live-copper-foreground/result.json` | `16038a51481088924f71c24433f506fc9c6f446816ec2d9657ade233ec3f455a` | Two 16-frame/16-command batches; generation 1 → 2; stopped and unadmitted; cleanup complete |
| `live-classic-systemd/result.json` | `27149b781010ec73e94701879b1bb9e351bfb2a1e00a13ecc7058365db94311f` | Same exchanges/reset; direct main-PID readiness; manager success and cleanup complete |
| `live-copper-systemd/result.json` | `928701d5bf37ae902a575a5cf49ed5753dd0bb276fe464f83bf52ab69bdaa656` | Same exchanges/reset; direct main-PID readiness; manager success and cleanup complete |

For each result the reviewer checked exact retained frame/command file hashes and byte lengths, sequence 1–16, successful public stop/reset/restart, distinct native children with generations 1 and 2, and placement-validation results. All 32 recorded PID/starttime identity entries are absent at independent inspection, as are the four owned runtime directories and instances. Some identity entries intentionally repeat the same native child. Installed descriptor, launcher, harness, SDK, native HEART executable and command-client hashes match their records.

Both saved service units match the retained versioned templates and contain `Type=notify`, `NotifyAccess=main`, `KillSignal=SIGINT` and `TimeoutStopSec=300`. Actual ready Julia supervisor PIDs equal `ExecMainPID` (Classic 1760079; Copper 1761227). Final manager results are inactive/dead, success, exit status 0 and MainPID 0. Invocation-scoped journals contain readiness; their error-priority files are empty. Native warning text remains present in the full journals, so this is not a claim of warning-free logs. Foreground runs have execution traces with no Python executable. Service no-Python evidence is the same sealed launcher under restricted PATH, without replacing its actual main process with a tracer.

The final source-binding report, SHA-256 `d99300a84f5f587578577db3768ebfa91d8310c500a68e5d4fe0e916f5361b4d`, explicitly records the dirty AOS source tree. Its aggregate is `ff8da8ff89ad12c49ad1568d66602df6d3c145a50c75cc8de267c518dcd94d99`; the selected adapter `277d822979f7709abb55769c76291937868f3e0b` has aggregate `b57958659ae9c312466a7e33e6acb393f435725f2fd2f63abcc3165a86b0e3e7`. Current selected source files and all six package copies match those recorded bytes. This qualifies the new actual tuple and does not retroactively equate it with the older accepted packages or support the incompatible adapter39 tuple.

The four-export report has SHA-256 `3d0b167b3dae13691d93e601706faa544338fb1243670ce148edadc1a0d639cb`; the final worker audit has SHA-256 `14ccfd49b7528979bcf7e3e8324a470d2fa7f2116353569e006dac713f6476d3`. Independent verification script `independent-review/final_evidence_check.py` has SHA-256 `260e249c2690e31e444d8a0381ce569c3eb8874d73df4185a5f0eb90bb983c3b`; its result `independent-review/final-heart-verification.json` has SHA-256 `6dbe4219ece5568b346a9a3f21166bbdb86ea0a2343eab6496531173c00a56e8`, relative to the enclosing migration cache. These are read-only inspections of retained/live-completed evidence; the reviewer did not launch the RTC.


The reviewer also inspected the final migration plan, delivery record and evidence ledger. Their implementation-version allocation and scientific limitations agree with the inspected evidence. Six known test-unit symlinks are absent, their exact target templates are preserved, and the cleanup record binds inactive/MainPID-zero state before unlinking. No other service modification is inferred from that scoped record.


## Active-session interruption and final adjudication

The additional installed Classic HEART active-session SIGINT check uses the same sealed v8-compatible package. Its result is `heart-cold/v8-compatible-prep/live-classic-active-interrupt/result.json`, SHA-256 `090df3bb77f802f663f1b17fb5b0a976ea993b76202177dbde598afa051e3f58`. The reviewed cache-only harness has SHA-256 `ffe1171994e02f82e35356fb42cb4d86bab431c498763b3f9c357a5c3e1d18f6`. It verifies direct tracer-child ownership and PID/starttime identity before signaling the Julia supervisor.

The source resume acknowledgement records running/incomplete state. The last pre-signal report has zero frames; the report retained after the signal contains one frame and one command, still incomplete with no failure. Its publication timestamp is later than the recorded signal timestamp. The traced launcher exits successfully; final state is stopped/unadmitted without error or cleanup errors. The reviewer independently checked all six owned PID identities are absent, instance/runtime paths are removed, the package/SDK/harness hashes match, and the execution trace contains no Python executable. Trace SHA-256 is `d47cc074209831f4f08943a163c276cb1c7e03a02e70e105ca2d04e1ad0d7b75`.

This establishes graceful interruption of an admitted active source before its finite batch completed. It does not establish that an exposure was in flight at signal delivery, exercise all 300 seconds of cleanup allowance, prove a hard wall-clock bound, or resolve the separately stated hypothesis about SIGINT during an already failing cleanup. JMR-009 is closed through the corrected shared allowance, analytical explicit-wait bound, portable failure/outcome checks and actual finite multiowner interruption evidence, with those limits retained.

JMR-007 is closed for the selected operational migration. The independent reviewer found no remaining confirmed blocking defect after the listed corrections and final evidence checks. The accepted verification composes exact v5/v7 acquisition results with reviewed narrow source deltas, final v7 terminal-stage checks and final v8 portable/cold/native-HEART/service/interruption checks; it does not relabel all matrix cells as final-v8 executions. Scientific analysis/helpers remain unchanged across those migration deltas. Final HEART dependency bytes are separately sealed and freshly qualified.

The remaining work is explicitly outside this closure: unexplained Classic response variation, scientific candidate acceptance and correction, physical or accelerator timing validation, compatibility of adapter39 with the selected AOS source, and broad adversarial interruption/fault qualification beyond the actual probes. HEART flags are acknowledged by native commands without effective-state readback. The shared Julia cache deletion attribution remains a hypothesis. RTC-DEV-029 scientific calibration is not complete.
