# Native calibration action wire inventory

Source snapshot: RTC commit `8179871b09628fadaf0e53ddb4f15e792d85166a`
(2026-10-06), in `work/calibration-action-inventory-20261006`. This is a
read-only inventory for native-control migration phase E; it records the
existing JSON contract and Rust/Julia call surfaces. It does not assign native
property or operation identifiers.

## Current request contract

The Julia server is authoritative for the current accepted JSON requests:
[`parse_request` and validators](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L192-L290).
Every object rejects unknown/missing fields. Requests are newline-delimited
JSON, with newline included in the request byte limit.

| Request fields | Current accepted types/ranges and meaning |
| --- | --- |
| `version`, `run`, `serial`, `timeout_ns`, `action` | Required top-level fields only. `version`: unsigned integer exactly 1 (`UInt8` typed parse); run/serial: `UInt64` in 1…2⁶⁴−1; timeout: positive integer ≤ `Int64` max nanoseconds. Maximum encoded request including newline: 16 KiB. Julia does an untyped validation pass then typed parse of original bytes, preventing float/exponent tokens being accepted as integer identities. |
| `action.kind = hold` or `release` | Only `kind`. |
| `adopt` | `probe` unsigned integer 0…16,383; `figure`: nonempty array of finite values representable as finite `Float32`. Owner requires exactly its `command_count` (default 277). |
| `settle` | `probe`; `after` cursor; `rule`. Cursor fields `domain`, `generation` positive `UInt64`; `sequence` nonnegative `UInt64`; `model_ns` 0…`Int64` max ns. Rules: `immediate`; `discard_exposures` with `frames` 1…4096; `model_time` with positive `duration_ns` ≤ `Int64` max ns. |
| `collect` | `probe`, `after`, `measurements` 1…131,072, `frames` 1…4096. At execution, measurements must equal owner contract; response is average of all acquired response vectors, with corresponding exposure records and aggregate validity. |
| `capture` | `probe`, `after`, `frames` 1…4096. Requires configured capture store and sufficient reserved-byte budget; profile-specific per-frame payload is Classic 250,252 bytes or Copper 22,596 bytes. Emits immutable files and manifest completion metadata. |
| `restore` | `figure` as above and `rule` as above; figure length must equal command count. |

Cursor/exposure time fields are model-clock nanoseconds, not host arrival time.
An exposure is `{domain,generation,sequence,start_model_ns,duration_ns}` with
unsigned integer fields. Exposure `duration_ns` must be positive; its end is
checked against the acquisition cursor. This is enforced in
[`exposure!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L292-L341); public Rust
types are in [`calibration.rs`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/0fadb2a116f360df7f7d601b8e7f2bea02d809f9/src/calibration.rs#L152-L179).

## Current results and effect behavior

The outer reply is exactly `{version,run,serial,result}`. Julia encodes it as
JSON plus newline; maximum reply including newline is 128 KiB. Success result
shapes from [`effect!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L472-L598):

| `result.kind` | Fields (besides `kind`) | Semantics |
| --- | --- | --- |
| `held` | `cursor` | Hold acquisition/session and return current cursor. |
| `adopted` | `cursor`, `figure` (`Float32[]`), `clipped` (`Bool`) | Adopt commanded probe, return actual figure and cursor. Unclipped actual figure must bit-match requested figure. |
| `settled` | `cursor` | Complete configured settling from the requested cursor. |
| `responses` | `values` (`Float32[]`), `exposures` (exposure objects), `valid` (`Bool`) | `collect`; values are means across requested frames. Quality-invalid but complete exposures remain evidence (`valid=false`). |
| `captured` | `cursor`, `manifest` (relative path), `sha256`, `frames`, `bytes`, `metadata_bytes` | `capture`; payload files and manifest are committed before success. Campaign verifies artifacts separately. |
| `restored` | `figure` (`Float32[]`), `clipped` (`Bool`) | Reference adopted and settling completed. Clipping faults owner. |
| `released` | none | Session released only after held and restored. |
| `failed` | `reason` string | Reasons emitted: `cancelled`, `endpoint`, `invalid_evidence`; coordinator also recognizes `probe_clipped`. Unknown reason maps to invalid evidence in Rust. |

The collect reply preflight is `512 + 16 * measurements + 180 * frames <=
131072` bytes before acquisition begins, followed by exact encoded reply-size
check. These constants are a bound for finite Float32 tokens and UInt64
identities, not a count of every actual field byte. Capture has a separate
payload reservation (`frame_bytes * frames <= maximum_bytes - reserved_bytes`)
and metadata bound `16 KiB + 4096 * frames`; capture does not return the payload
through the socket. References: [`collect!`/`capture!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L350-L518),
[`encode_reply`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L628-L633).

### Rust compatibility surface

[`CalibrationEndpoint`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/0fadb2a116f360df7f7d601b8e7f2bea02d809f9/src/calibration.rs#L687-L713) is currently:

```rust
fn submit(&mut self, effect: &CalibrationEffect) -> Result<(), CalibrationFailure>;
fn receive(&mut self, deadline: Instant) -> Result<Option<CalibrationCompletion>, CalibrationFailure>;
fn fault(&mut self, failure: CalibrationFailure);
```

`CalibrationSocketEndpoint::new(UnixStream) -> io::Result<Self>` implements it
([`calibration_socket.rs`](../src/calibration_socket.rs#L22-L185));
`acquire_calibration<E: CalibrationEndpoint>(endpoint: &mut E, run: u64,
plan: CalibrationPlan) -> Result<CalibrationCoordinator, CalibrationError>`
drives the existing completion semantics. Rust request/effect types are
[`CalibrationRequest` (`run`, `serial` as u64), cursor/exposure/batch, actions,
evidence and completion](https://github.com/DarrylGamroth/pipewireao-rtc/blob/0fadb2a116f360df7f7d601b8e7f2bea02d809f9/src/calibration.rs#L145-L248).

Rust currently serializes `hold`, `adopt`, `settle`, `collect`, `restore`,
`release`; it deserializes `held`, `adopted`, `settled`, `responses`,
`restored`, `released`, `failed` ([wire DTOs](../src/calibration_socket.rs#L203-L420)).
Its serde decoder denies unknown result/cursor/exposure fields but not
unknown top-level reply fields. **Observed contract difference:** no Rust
`Capture` action/evidence exists, while Julia campaign uses `capture` for the
interaction/HIL artifact path. The campaign client also has its own endpoint
record schema that accepts `captured` and does not implement `collect`
([`Endpoint`/`request!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/calibration_campaign.jl#L299-L367)).
This must be resolved as a phase-E interface mapping; this inventory does not
select its native representation.

## Callers and replacement seams

| Current caller / seam | Exact source interface and scope |
| --- | --- |
| Julia server framing | `parse_request(payload::AbstractString)` → typed request; `execute!(owner::Owner, request; started::UInt64=time_ns(), check_connection=()->nothing)` → reply NamedTuple. `effect!` and acquisition helpers implement the operational behavior. Keep effect/session implementation semantics at these seams while replacing parse/encode/dispatch framing. See [`calibration_server.jl`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L274-L290), [effect and execute](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L520-L633). |
| Julia transport lifecycle | `serve_connection!(owner, socket; io_timeout_ns, should_stop, service_control, admission_enabled)` accepts one client/run; `serve!(owner, listener; accept_timeout_ns, ...)` admits one client; path overload publishes/removes socket. See [connection/accept](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L695-L793). |
| Rust runtime | `rtc-calibrate` connects `UnixStream::connect(endpoint_path)`, wraps `CalibrationSocketEndpoint::new`, then calls `acquire_calibration`; replace construction/endpoint adapter in [`rtc-calibrate.rs`](../src/bin/rtc-calibrate.rs#L173-L185), preserving plan parse/output and coordinator call. |
| Campaign client | `CalibrationCampaign.endpoint_connect(path,run,timeout_ns)` → `Endpoint`; `request!(endpoint::Endpoint, action, expected)` sends and validates one request/result. Caller in `run_interaction` issues hold/adopt/settle/capture/restore/release; see [endpoint and request](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/calibration_campaign.jl#L299-L367), [campaign actions](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/calibration_campaign.jl#L495-L555). |
| HEART pilot client | `HeartCalibrationExport.run_pilot` directly uses `endpoint_connect` and closure calling `request!`; hold/adopt/settle/capture/restore/release; see [`heart_calibration_export.jl`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/src/heart_calibration_export.jl#L384-L428). Search indicates HEART full-plan path also connects with `CalibrationCampaign.endpoint_connect` and consumes capture manifests in `heart_calibration_export.jl` around lines 467–554. |

## Identity, deadlines, and inactivity boundaries

**Observed current JSON representation:** identities and times are unsigned
decimal JSON integer tokens. Julia validates then converts run/serial to
`UInt64`; Rust serde fields are `u64`; campaign client stores run/serial and
timeout as Julia `Int` (thus signed machine range) and checks reply identity
against sent fields. Cursor `domain/generation/sequence` support full UInt64,
while cursor `model_ns`, request timeout and settling duration are bounded by
Int64 max. Probe/count/frame fields are small unsigned integers, constrained
as above. Figures and responses are Float32. No binary wire representation is
currently used.

**Owner session/controller behavior:** owner construction requires
`normal_controller_absent=true`, positive command/measurement counts, valid
profile contract, and finite max timeout. `hold` is initially the only normal
entry action. Adopt/settle/collect-or-capture are sequenced under hold; restore
holds if needed, clears probe association, adopts reference and settles before
ack; release requires confirmed restore. Once an effect has begun, errors
fault the owner and preserve hold. `execute!` rejects wrong run, non-increasing
serial, over-limit timeout, or unsupported initial action before running it;
the deadline is based on server `started=time_ns()` and checked around effects.
References: [`Owner`/fault](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L101-L188),
[`execute!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L600-L633),
[`effect!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L520-L598).

**Accept and inactivity:** after listener readiness the owner waits for
`admission_enabled()` before starting the finite accept timer; accept timeout
closes listener and enters `fault!`. It accepts one client only. Once connected,
the server begins a request reader immediately; each next reader is started
after the prior record is parsed. I/O reader has `io_timeout_ns`; a timeout,
EOF, pipelined arrival before prior reply, stop request, or broken connection
causes endpoint failure/fault and therefore retained hold. Per-request timeout
starts at record completion (server `started`) and bounds effect and reply.
While admission is disabled, ordinary actions return `cancelled`, but restore
and release remain admitted. References: [`serve_connection!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L695-L741),
[`serve!`](https://github.com/DarrylGamroth/pipewireao-rtc/blob/3101c5a/assets/deployment/hil/calibration_server.jl#L743-L793).

## Phase-E replacement inventory (recommendations)

1. Replace the JSON framing adapter around `parse_request`/`execute!`, retaining
   `effect!`, cursor/exposure checks, session calls, fault/restore/release
   ordering and artifact commit behavior.
2. Implement a native `CalibrationEndpoint` alongside the current Rust adapter,
   then switch `rtc-calibrate` endpoint construction. Keep `submit` nonblocking,
   `receive` deadline-bound, and `fault` prompt as the trait contract requires.
3. Migrate `CalibrationCampaign.Endpoint` and its HEART pilot/full-plan callers
   to the corresponding native owner interface. Preserve campaign artifact
   verification and result/report behavior.
4. Resolve the existing `capture` versus Rust `Collect` abstraction gap before
   claiming the entire phase-E contract. Native identifiers and exact field
   encodings remain a root-level design decision.

No builds, tests, simulations, runtime campaigns, or rate measurements were
performed for this inventory.
