# Remaining live JSON control transports

Read-only source inventory, 2026-10-05. RTC worktree:
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-live-controls`, HEAD
`57337d6d52db7e23d27a55d58e358995f235b3d7`, with the current uncommitted native
source-control changes included. No source edits, tests or GPU work performed.
File references below are relative to that RTC worktree.

This is the historical starting inventory, not a claim that the removed worktree
is still active. Follow the maintained [migration design](NATIVE_CONTROL_MIGRATION_DESIGN.md)
for current implementation status. A 2026-10-05 read-only recheck of the HEART
wrapper and callers at `e57b2e5403bd8b90b6a2ebbaa7fbefe6c4ccfada` confirmed that
reset/status files and health-report reads below remain live migration debt.

The subsequent [runner endpoint](NATIVE_RUNNER_ENDPOINT_VALIDATION.md) and
[supervisor client](NATIVE_RUNNER_CLIENT_VALIDATION.md) replace the historical
supervisor-to-runner JSON socket hop below. Focused CPU lifecycle tests use the
actual launcher and native endpoint. The public operator broker, HEART wrapper,
calibration controls and readiness/status-file authority remain unmigrated;
the original inventory below preserves their starting interfaces.

## HEART boundary recheck

No HEART source change is needed for this migration. Our `heart_owner.jl`
wrapper will supply the new native endpoint, and our exporter, simulator,
calibration and correction callers consume it. The wrapper's vendor TCP command
client and SPA Standard WFS/DM UDP bridges remain their existing interfaces.

The wrapper reset still stops the old child, starts and initializes its
replacement, verifies ingress configuration and thread placement, and publishes
the new child PID/generation only after preparation. Calibration initially
requires generation 1; correction reset requires exactly the previous generation
plus one and fences old child/telemetry before admitting another exposure. These
are child lifecycle semantics, not merely graph numerical reset.

`heart-owner-status.json` is currently consumed as live authority by both
`heart_calibration_owner.jl::require_usable` and
`heart_correction_owner.jl::require_active`. Native fresh queries must preserve
PID/generation, child liveness/error and configured/observed ingress checks.
Startup also verifies configuration/executable/input evidence and command logs.
Saved immutable evidence may remain files; mutable report reads must cease to
authorize acquisition. Flag verification currently proves command SUCCESS
acknowledgements, not effective flag readback; migration must retain that limit.

## Observed live paths

| Path | Exact entrypoints and callers | Current wire fields | Native alternative / dependency |
| --- | --- | --- | --- |
| Operator → Julia supervisor, `control.sock` | `deployment/julia/src/deploy.jl:236` `control`; CLI `:1229`/`:1239`; server `:626` `serve_control`, coordinator `:577` `coordinate`; listener `:980`. `state.json` is consulted by the CLI at `:1236`. | Request `{version, id:String, argv:String[]}`; reply `{version,id,session_id,state,result,ok,error:{field,message}}`, optionally source snapshot. 16 KiB request, 128 argv fields, 64 KiB reply. | A supervisor-owned public PipeWire control endpoint is needed; none currently replaces this socket. Encode typed lifecycle/group/control/query operations in versioned standard Props, preserving correlation, supervisor incarnation, state, outcome/rejection, and source/native combined observations. Generic SPA serialization exists; the supervisor request/completion schema does not yet exist. |
| Julia supervisor → Rust lifecycle runner, `native-control.sock` | `deploy.jl:571` `native_control` calls the same JSON socket client; startup `:963`/`:966`/`:975`, coordination `:577`, cleanup `:794`/`:799`. Rust `src/control_socket.rs:202` receives, `:258` parses, `:362` serializes replies, `:542` `send_request` is the client. Rust CLI `src/main.rs:144`; server selection `:168`. | Same request/reply shape (`src/control.rs:63`/`:72`). Commands at `src/control.rs:98`: session start/stop, group start/stop, source-ended, reset, quit, status/groups, property queries/updates, ndarray parameter replacement. Results preserve submitted/requested/completed/active distinctions (`:308`). | Despite the field name `native_socket`, this hop is JSON over Unix sockets. The graph-facing operations already use native APIs: reset `src/live.rs:1181`, run requests `:1706`, scalar Props `:1260`/`:3939`, generation observations `:670`/`:701`, ndarray publisher `:1476`. A runner endpoint must preserve its serialized lifecycle dispatcher; direct node writes alone do not replace session/group coordination, quit, or aggregate status. |
| Supervisor → separate calibration/correction source owners, request/reply files | `deploy.jl:456` selects file control for a source without the native ad; `:507` `source_file_control` writes `{version,id,operation}` and polls the reply. Export intentionally removes native source ads: `deployment/julia/src/calibration_export.jl:232` `calibration_source_control!`; owner replacement `:258`; HEART export invokes it at `deployment/julia/src/heart_calibration_export.jl:299`. Consumers: `deployment/hil/calibration_owner.jl:149`, `heart_calibration_owner.jl:813`, `heart_correction_owner.jl:588`, all through `owner_protocol.jl:119` `control!`. | Request version 1, positive increasing Int64 id, operation resume/pause/reset/status. Reply version/id/operation/state/sequence/completed/ok/error (`owner_protocol.jl:110`). Calibration owner reset deliberately rejects: new instance required (`calibration_owner.jl:158`). Restoration/admission/report behavior belongs to these owners. | Reuse native run/reset serializers and a separate prepared source-query/snapshot contract where semantics agree, as the ordinary simulator now does. Add owner-specific acquisition/restoration readiness, fault/held/released state and report cursor; preserve explicit unsupported reset behavior. Merely retaining the ordinary simulator's native ad would be incorrect before these consumers are implemented. |
| Calibration coordinator → Julia acquisition server, `calibration.sock` | Rust `src/bin/rtc-calibrate.rs:173` connects and drives `CalibrationSocketEndpoint`; `src/calibration_socket.rs:92` submits and `:66` parses completions. Operational Julia capture client: `deployment/julia/src/calibration_campaign.jl:308` `endpoint_connect`, `:315` `request!`; capture action sequence `:505`/`:511`; noncapture coordinator subprocess `:556`. HEART pilot reuses that Julia endpoint at `deployment/julia/src/heart_calibration_export.jl:396`; full plan uses `rtc-calibrate` at `:511`. Server `deployment/hil/calibration_server.jl:274` parses, `:600` executes, `:642` encodes, `:694` serves; scientific owner calls `:173`, HEART owner `heart_calibration_owner.jl:853`. | Version/run/serial/relative timeout/action and version/run/serial/result. Request ≤16 KiB; actual shared server/Rust completion bound 128 KiB (`calibration_server.jl:8`, `calibration_socket.rs:20`), Julia capture endpoint reads ≤64 KiB (`calibration_campaign.jl:326`). Detailed fields below. | Requires a new versioned calibration native control/completion contract on the exact acquisition owner, plus bounded native POD payloads for figures/responses and bounded acquisition/exposure metadata. Native run/reset alone cannot represent Hold/Adopt/Settle/Collect/Capture/Restore/Release or their acquisition evidence. Implement shared server and both coordinator clients together. |
| Simulator → supervised HEART wrapper, `heart.control.request` / `.reply` | `deployment/hil/simulator.jl:34` `reset_controller!` writes reset and checks ACK; `deployment/julia/src/heart_export.jl:166` wires wrapper file options and `:173` wires simulator controller paths. Wrapper shim `deployment/hil/heart_owner.jl:3` calls `HeartOwner.main`; real handler `deployment/julia/src/heart_owner.jl:371` `control`, polling loop `:407`/`:420`. | Request version/id/operation (reset or status). Reply uses the owner eight-field shape, paused/sequence0/notcompleted (`heart_owner.jl:366`). Reset stops/restarts HEART child (`:393`), rather than merely resetting a graph numerical object. | Publish wrapper-owned native reset completion/status with child PID, child generation, ingress/placement readiness and wrapper incarnation. Preserve the actual restart meaning and failure semantics. Wrapper needs a public control node or endpoint; currently it has no equivalent Props control surface. HEART's own vendor TCP command client is a separate interface, not this JSON transport. |

## Calibration fields that must survive migration

Authoritative implemented schemas: `src/calibration_socket.rs:204` through `:370`,
`deployment/hil/calibration_server.jl:204` through `:286` and `:520` through `:628`.

- Request envelope: version, positive run, positive strictly advancing serial,
  finite relative timeout, action kind. Client absolute deadline stays authoritative;
  a relative server budget must not extend it.
- Hold/Release: no extra request fields. Hold completion includes cursor;
  Release completion has no extra result fields.
- Adopt: probe index and absolute Float32 figure (277 commands); completion
  has actual figure, clipped flag and adoption cursor.
- Settle: probe, exact previous cursor, settling rule. Rule is immediate,
  discard-exposures with frame count, or model-time with duration. Completion
  includes settled cursor.
- Collect: probe, previous cursor, measurements and frames. Completion has
  averaged Float32 values, every contributing exposure identity and valid flag.
- Capture: probe, previous cursor and frames. Completion has cursor, relative
  manifest reference, SHA-256, frames, payload bytes and metadata bytes. This
  completion is live control; the immutable manifest and payload are saved artifacts
  (`calibration_server.jl:472`/`:497`/`:514`). Rust's current WireAction does not
  implement Capture; the operational Julia endpoint handles it.
- Restore: absolute Float32 reference figure plus settling rule; completion
  has actual figure and clipped. Release requires confirmed restoration.
- Failed: reason cancelled/endpoint/invalid_evidence/probe_clipped.
- Cursor: domain, generation, sequence, model_ns. Exposure: domain, generation,
  sequence, start_model_ns, duration_ns. Preserve full acquisition-domain mapping,
  units, strict integer identity and exposure association; these are not Header PTS.
  Current wire types include UInt64. Prepared scalar Props support signed SPA Long;
  full-width unsigned identity representation/range must be explicitly resolved,
  without silently truncating to SPA Id or signed Int64.
- Bounded single pending action, restoration fencing, retained hold/fault on
  disconnect and unknown outcome, no reconnect/retry, readiness/capacity limits,
  and current Classic/Copper validity behavior must remain observable.

`deployment/hil/calibration_client.jl` is **not** the live endpoint transport:
`:151` prepares plans, `:188` writes saved plan JSON, `:216` validates coordinator
results, and `:289` writes scientific artifacts. The transport clients are the
Rust `CalibrationSocketEndpoint` and Julia `CalibrationCampaign.Endpoint` above.

## Runtime observations and bootstrap markers

- `heart-owner-status.json` is also a live health authority, not solely an
  audit report: wrapper writes it at `deployment/julia/src/heart_owner.jl:186`/`:196`;
  HEART acquisition reads it during every `require_usable` at
  `deployment/hil/heart_calibration_owner.jl:54`/`:61`, and initial hold at `:205`/`:209`.
  Native replacement needs generation/child PID, child liveness, error, ingress
  mode and observed environment, preparation/placement readiness; keep the full
  thread/config/command evidence as a saved report if useful.
- `state.json` is a mutable supervisor status/discovery record: CLI `deploy.jl:1236`,
  `wait_state` `:1050`, shutdown `:1065`. Native owner identity/status discovery
  should become authoritative for live coordination; a saved diagnostic mirror
  can remain. Do not confuse its current `socket` field with a native endpoint.
- Prepared and connected markers contain JSON version/state/sequence, but the
  supervisor currently checks only file existence (`deploy.jl:955`/`:958`). Connect
  and quit markers are empty files (`:957`, `:811`). Owners publish JSON readiness
  at `simulator.jl:427`/`:469`, `calibration_owner.jl:126`/`:169`, and corresponding
  HEART owners. These are lifecycle IPC adjacent to live JSON control. A native
  readiness/shutdown migration must address early preparation when the source
  stream/control endpoint has not yet been created, and failures before publication.
  Existing process supervision remains necessary in that bootstrap interval.

## Saved JSON that is not live request transport

Retain the distinction for deployment/session configs and provenance; recipes,
plans, method declarations and frozen input identities; captured immutable
manifests and ndarray files; final/prefix/sustained reports and evidence ledgers;
native telemetry snapshots, command-result logs, JSONL evidence and failure
records. Examples: `calibration_client.jl:188`/`:289`,
`calibration_server.jl:497`, `simulator.jl:324`/`:325`,
`heart_calibration_owner.jl:137`/`:291`/`:404`/`:448`.
Some saved reports are currently polled for completion by campaign tools; migrate
the readiness authority to native cursor/completion while preserving artifact
verification. CLI rendering of an already-native response as JSON is an output
format, and need not make JSON the live interprocess transport.

## Migration dependency order (derived from callers)

1. Specify shared versioned request/completion schemas and endpoint identity for
   runner/supervisor, calibration, and HEART wrapper. Preserve typed errors,
   operation outcomes, exact owner incarnation, unsigned identities, budgets,
   ndarray payload/metadata and authoritative fresh query semantics. Standard
   Props/POD serialization is available; these remaining schemas are not implemented.
   Current `docs/operations.md:976` explicitly describes calibration JSON and
   needs an intentional contract update with the user-selected migration.
2. Expose native control/status endpoints in the Rust lifecycle runner and HEART
   wrapper, reusing their existing serialized owner dispatch and graph native
   run/reset/Props/ndarray operations. Establish preparation and failure-before-node
   behavior before changing supervisory discovery.
3. Migrate calibration/correction owner admission controls and HEART controller
   reset/health reads. Then migrate supervisor → runner controls, including startup,
   shutdown and failure cleanup; file/socket fallback must not silently return.
4. Implement the native calibration action server plus Rust coordinator endpoint
   and Julia capture/pilot endpoint together. Keep acquisition ownership,
   restoration fencing, exact exposure association, capacity bounds and artifact
   commits intact; migrate live figure/response payloads to bounded native SPA arrays. Larger
   payloads require a separate reviewed public ndarray exchange contract.
5. Replace the public Julia supervisor socket/client and remaining live
   state/readiness polling with native discovery/control. Update CLI callers,
   exporters/installers, lifecycle markers and documentation; preserve saved JSON
   artifacts and optional CLI output independently.

This order identifies dependencies, not an approved new endpoint/key schema or
an implementation/qualification claim. Native source controls already in place:
`deployment/hil/source_control.jl:14`/`:18`/`:26` (query/snapshot/rejection),
`deployment/julia/src/source_client.jl:209`/`:354` (client),
`deploy.jl:456`/`:468` (supervisor native-source selection/preparation).
