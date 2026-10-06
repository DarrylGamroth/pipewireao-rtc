# Live control retirement audit

## Scope and evidence

Read-only source audit, 2026-10-06. No owner was launched, no build or scientific
test was run, and no production source was changed. Findings distinguish an
available ingress from a qualified deployment. Severity describes retirement
impact, not a demonstrated scientific failure.

[Issue #9](https://github.com/DarrylGamroth/pipewireao-rtc/issues/9) requires
retirement of replaced live JSON/socket/marker authority and fallback
selections. Persisted configuration, reports, provenance, artifact verification
and local rendering of native results remain allowed. The primary agent
adjudicated NRET-001 and NRET-002 as required retirements on 2026-10-06.

| Source | Revision and state inspected |
| --- | --- |
| RTC | `4cc6ad92eac04d9725f36ee9ee436b33d901596d`, clean dedicated audit branch |
| Canonical JuliaFilterGraph.jl | `f2f4cd4e269a63887c6d55f915d97d674fd18687`; unrelated untracked Python caches and `gmon.out` preserved |
| Canonical GUI | `f6b33b7019f4358646dcdda3797ecfa1e9872a93`; unrelated modified `docs/workstation-review.md` preserved |
| Native GUI integration worktree | `34588bf50239c044a90d37d50c774e58ce1ebed6`, clean |
| PipeWireAO.jl | `6e4e1eebf8bd160f01a532dcfc7284dec92de61b`, clean |
| Native PipeWire/PipeWireAO | `29da2d6699d24fff77a693d3988ad6432594ef81`, clean |

RTC references below are repository-relative. Sibling paths identify their
repository explicitly. This is an inventory of examined operational paths,
not a claim that every occurrence of JSON in those repositories was reviewed.

## Confirmed findings

### NRET-001 — Production runner still accepts JSON control sockets

**Retirement blocker; confirmed, high confidence; required removal.**

`src/main.rs:434` accepts `--control-socket PATH` and `:466` advertises it.
`run` (`:56–85`) selects `control_session`, which binds
`ControlSocketServer` (`:190`). `src/control_socket.rs:260` parses a JSON
`SocketRequest` containing `version/id/argv`; `:364` writes JSON responses.
Requests reach the existing serialized runner dispatcher. This remains a real
optional ingress, even though the public `control` subcommand uses the native
supervisor client and selected Julia deployment launches `--control-node`.
The parser forbids combining the two ingress modes; it does not retire the old
mode. This is not merely an archived client or a saved report.

Remove the flag, server and socket wire request type. Preserve console commands,
typed execution results and local JSON rendering. Native remote validation
currently imports `validate_socket_path` and `effective_uid` from this module
(`src/native_runner_endpoint.rs:45–48`); preserve those ownership/path checks
in a native filesystem helper before removing the module.

Compatibility breaks: direct socket clients, Python `deployment/deploy.py:652`
and explicit `--control-socket` invocations. Socket-specific unit tests in
`src/control_socket.rs:615–931` no longer qualify a supported transport.
Preserve owner-loop/nonreentrancy tests in `src/main.rs:532–667`; preserve or
transfer filesystem validation tests and native bounds/deadline/unknown-outcome
coverage. Add rejection tests proving the obsolete flag cannot select an owner
or create a socket. Do not delete the shared `control` module.

### NRET-002 — Public calibration library still exposes JSON endpoint API

**Retirement blocker; confirmed, high confidence; required removal.**

`src/lib.rs:4–5` exports `calibration_socket` on Unix without a test-only gate.
`CalibrationSocketEndpoint::new(UnixStream)` (`src/calibration_socket.rs:38`)
implements the public calibration endpoint trait; submission serializes JSON
(`:112`) and completion parses JSON (`:71`). External callers can select this
live adapter. The selected `rtc-calibrate` CLI instead imports
`NativeCalibrationEndpoint` (`src/bin/rtc-calibrate.rs:8,226`) and its test
rejects the old `--endpoint` selection (`:272`). No selected CLI fallback was
found; absence of that fallback does not retire the public library API.

Remove the export and implementation, preserving the transport-neutral
calibration coordinator and native codec/client. This breaks downstream imports
and `tests/calibration_socket.rs`, whose nine tests exercise socket submission,
identity, bounds, disconnect, expiry, fenced restoration and a complete session.
Keep those behavioral obligations represented in native tests; socket framing
fixtures cannot substitute for actual native completion qualification.

### NRET-003 — Python source entrypoints retain legacy operational code

**Scope decision required; confirmed availability, high confidence.**

`deployment/deploy.py:201` is a Unix JSON client, `:425` writes source control
requests, `:536` serves JSON operator requests, `:644` waits for preparation
files, and `:940` selects control through saved `state["socket"]`. Its direct
`__main__` remains (`:959`). `deployment/hil/heart_owner.py:383–424` publishes
and consumes marker/request/reply files and has a direct entrypoint (`:494`).
Python exporters/campaign/check tools retain these call paths; the campaign
also invokes the now-rejected Rust `rtc-calibrate --endpoint` option
(`deployment/calibration_campaign.py:498`). They are runnable source tools,
not unreachable archive text, but their full current HIL compatibility was not
tested and is not established by this audit.

Selected installed production wrappers execute Julia. In particular,
`ScienceExport.copy_deployment_runtime` (`deployment/julia/src/science_export.jl:68–98`)
excludes Python HIL resources and copies Julia entrypoints; `Deployment.install`
generates Julia launchers. RTC AGENTS classifies Python operational tools as
development references. Decide whether to remove/quarantine live legacy tools
or make their retired status fail closed. Existing Python socket/file fixtures
must be clearly legacy evidence if retained; their success is not native
deployment qualification. Do not remove offline input/export conversion merely
because its saved format is JSON.

### NRET-004 — Standalone JFG still offers lifecycle marker controls

**Sibling scope decision required; confirmed, high confidence.**

Canonical JFG `deployment/run_island.jl:35–38,182–191` accepts
`--quit-request`, `--connect-request`, `--prepared-event`, `--connect-reply`.
`wait_for_connect_request` (`:278`) and `monitor_quit_request` (`:314`) consume
file existence; `run_connected_service` (`:451–487`) signals preparation and
connection. The direct entrypoint calls `run_service(parse_arguments(ARGS))`
(`:500`). These are operational empty-file markers, not JSON wire records.

The documented captured DM supervisor (`docs/deployment.md:349`) actively uses
them: `deployment/DMControlPlane.jl:435–482` allocates/injects generation paths,
`:506` waits for preparation, `:585–587` requests/waits for connect, `:604,635`
consumes shutdown and requests quit. Fault approval also consumes a plaintext
operator reply token (`:708–711`). Retirement affects the captured supervisor,
its approval/lifecycle tests and direct island CLI callers; it requires an
explicit JFG authority decision, not deletion as unused fixtures.

The selected RTC wrapper `deployment/hil/jfg_owner.jl:52–59` includes the JFG
script for its graph definitions/parser, then calls `run_native_graph`, using
native bootstrap tickets rather than `run_service` or marker polling. Thus the
remaining standalone JFG path is not a selected RTC fallback.

### NRET-005 — Canonical GUI still selects the JSON socket adapter

**Integration gate; confirmed, high confidence.**

Canonical GUI `src/main/rtc_session.rs:39` calls `RtcAdapter::start(path)`.
`src/rtc_adapter.rs:4,12,121–195` includes the codec in production, connects a
UnixStream and writes/reads its records. `src/rtc_adapter/codec.rs:22,140`
serializes/parses JSON. The native GUI worktree at `34588bf` instead imports the
public RTC native session/supervisor API and gates that old codec with
`#[cfg(test)]` (`src/rtc_adapter.rs:3–9`). Integration into the canonical GUI is
still required before claiming the canonical operator surface is native.
Preserve the unrelated canonical documentation change during integration;
reconcile socket-specific UI text and retire socket live fixtures as operational
gates. The already qualified native candidate must not gain a socket fallback.

### NRET-006 — Documentation and inert compatibility names need reconciliation

**Maintenance debt; confirmed, high confidence; not proof of live JSON IPC.**

`docs/LIVE_CONTROL_INVENTORY.md:55–59,110–118` still describes multiple selected
paths that have since migrated. `docs/operations.md:994–1007` incorrectly says
installed acquisition profiles select the JSON calibration server and retain a
divergent Julia reply bound. GUI AGENTS still refers to a private Unix endpoint.
Update the inventory/specs against final integrated source and evidence rather
than declaring all entries retired from one successful native deployment.

Selected acquisition owner parsing still requires `--calibration-socket`
(`deployment/hil/calibration_owner.jl:21–78`), and exporters emit a path, but the
selected owner calls native `Actions.serve!` (`:204`; HEART owner `:892`), not
`CalibrationServer.serve!`. The stored path is unused after validation. Removing
this inert argument changes owner/export fixtures and sealed exported scripts.
Rust public `control --socket` is an alias for a native locator (`src/main.rs:131`),
not the live JSON `--control-socket` server. Retire misleading compatibility
names separately without changing locator authority or saved data formats.

## Examined selected paths and allowed saved artifacts

| Family | Current authority and disposition |
| --- | --- |
| Julia public supervisor/runner | `supervisor_controls.jl:14–38,184` uses native endpoint/client and typed requests; `deploy.jl:1346` selects native runner ingress. `fixture_socket_control`, `fixture_coordinate`, `fixture_serve_control` are explicitly fixture helpers; no production selection found. Keep or move behind a test seam, not a fallback. |
| Startup/shutdown/discovery | `deploy.jl:1446–1495` reads locator hints, then exact native connect/fresh Status; saved `state.json` contributes only listed artifact/configuration fields. `wait_final_report` reads once after the owned process exits; `shutdown` requests native stop/quit, observes exit, then verifies the final saved report. Private core socket existence is native core availability, not JSON control readiness. |
| Source/acquisition actions | SourceClient is native SourceControl V1. Native lifecycle/action adapters serve selected ordinary/calibration/correction owners. `owner_protocol.jl` legacy JSON `control!` and `calibration_server.jl:711–803` Unix framing remain helper/fixture definitions; no selected owner call was found. Preserve science/core action logic if removing framing. |
| Calibration campaign/capture | `calibration_campaign.jl:312–317` requires a native endpoint binding and rejects the old string socket API. `wait_completed_source` (`:389`) obtains fresh native completion/cursor before `completed_owner_report` (`:407`) verifies saved artifacts. Capture manifests/binaries and startup reports remain saved science/configuration evidence, not action dispatch. |
| HEART wrapper | Selected wrapper has native lifecycle/reset/status. `native_heart_client.jl:89–110` queries native Status before checking the named immutable generation report, SHA, generation and PID. Mutable status JSON/logs are diagnostics. Vendor HEART TCP command/stdio acknowledgements remain an explicitly separate unchanged interface, not this retired JSON wrapper IPC. |
| Offline conversion and scientific data | `legacy_export_input=true` is used by offline exporters, not deployment authority. SPA-JSON configurations, requirements, recipes/plans, frozen metadata, FITS/binary inputs, final reports, failure diagnostics, JSONL evidence and locally rendered native results are retained. Native calibration figures/parameters are typed POD/data payloads, not JSON tunneled through POD bytes. |
| Native GUI/SDK/PipeWire examined surfaces | Native GUI candidate uses the owner library. PipeWireAO.jl run-control serializers and examined native ndarray/source control interfaces use native POD/ABI. Generated SPA JSON configuration helpers and metadata tests do not establish a selected JSON request transport. This row is limited to the inspected surfaces. |

## Narrow implementation and validation plan

1. Remove NRET-001's production flag/server and `SocketRequest`, retain console
   dispatch/response rendering, and preserve native remote filesystem checks in
   a narrow helper. Reject obsolete selection before effects. Adjust Rust CLI
   tests and retire only transport-specific server/client fixtures.
2. Remove NRET-002's public export/adapter and socket integration tests. Check
   downstream API callers and preserve native coverage of bounds, exact
   identity, partial writes/expiry analogues, unknown outcomes and restoration.
3. Adjudicate Python and standalone JFG scopes explicitly; identify their active
   documented callers and replace/quarantine them before a cross-repository
   retirement claim. Integrate the native GUI candidate without discarding
   canonical changes. Remove inert calibration path options in a separate
   compatibility change if authorized.
4. Reconcile the maintained inventory/specs; then run requested Rust
   fmt/tests/Clippy and actual updated-runner/native foreground/service checks.
   Keep inclusive scientific allocation/numerical/latency evidence separate.
   This audit supplies no new runtime or scientific qualification evidence.

No production remediation is included here. No unobserved failure mechanism or
successful legacy deployment is inferred from static reachability.
