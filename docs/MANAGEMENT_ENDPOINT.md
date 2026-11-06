# Local RTC management endpoint

Selected implementation contract, 2026-11-03. Implements the agreed RTC-owned
management boundary alongside RTC-ARCH-026 and RTC-DEV-030/031. Management is
local Linux IPC; all live controls/status remain on their existing typed native
interface. It is not a new session authority or remote gateway.

## Public identifiers and ownership

- `pipewireao-management`: RTC-installed native companion. systemd owns its
  lifetime independently of GUI connections and of any individual live session.
- `pipewireao-management.socket` and `.service`: per-user activation units.
  Default endpoint: `$XDG_RUNTIME_DIR/pipewireao/management.sock`, socket 0600
  inside owned 0700 directories. `PIPEWIREAO_MANAGEMENT_SOCKET` selects an explicit
  absolute local endpoint for clients/tests, never a program or store root.
- `pipewireao.management/1`: local transport envelope and receipt queries.
  Existing `pipewireao.configuration/1` and `pipewireao.simulator-settings/1`
  identify the unchanged request domains. Existing operations keep their names.
- `PipeWireAORTC.ManagementCLI`: owner-side dispatcher/installation tooling that
  reuses ConfigurationStoreCLI and SimulatorConfiguration; GUI never loads it.

These names are generic protocol/installation boundaries. Artifact, session,
configuration, job and receipt retain their meanings in architecture.md and
RTC-DEV-031. No scientific concept or native live-control operation is renamed.

## Framing and security

Use AF_UNIX SOCK_STREAM. Wire JSON is UTF-8, has at most 64 nesting levels
and excludes NUL codepoints to preserve the native string boundary. One request and one newline-terminated JSON response
per connection, with a fresh connection for each independent request. No retry
or replay. Both sides verify SO_PEERCRED UID equals their effective UID. Clients
also reject non-socket, foreign-owned, group/world-accessible or symlink endpoints.
The owner retains one exclusive state-root lock across its lifetime; another
instance using that root fails rather than create a second worker authority.

Request envelope (at most 64 KiB including its newline):

```json
{"protocol":"pipewireao.management/1","id":"32 lowercase hexadecimal digits","request":{"protocol":"pipewireao.configuration/1","op":"list","arguments":{"limit":50}}}
```

The owner rejects unknown domains/operations and client-supplied roots. Its
installation selects the configuration-store root and durable management state.
The default configuration root remains ConfigurationStore.default_root(). It
stores artifact catalog data; session-operation journaling is retired. Management
receipts remain in the separate management state root. Simulator jobs retain
their existing configured owner root. Live RPC operations such as
Start/Stop/Reset/Status are not admitted through management.

For `register`, client opens the bounded regular FITS input before submitting and
attaches exactly one SCM_RIGHTS descriptor to the first request byte. The path is
removed from its JSON arguments. The owner substitutes its own retained descriptor
path for the existing handler. It never opens a browser/client-supplied path.
Other operations reject descriptors. Reading a bounded descriptor retains inode
lifetime across client unlink/exit; conversion/registration remain owner work.

Reply:

```json
{"protocol":"pipewireao.management/1","id":"same request id","ok":true,"result":{}}
```

An explicit owner rejection has `ok:false,error:STRING`. A worker loss, deadline
or malformed reply after dispatch uses `ok:false,error:STRING,unavailable:true`;
clients retain Unknown for potentially mutating work. Before any request bytes
are sent, connection/input failure is Not sent. Replies verify protocol and exact
request identity. A verified peer may reject before reading a request at the
connection limit using `id:"",ok:false,admitted:false,error:STRING`, without
`result` or `unavailable`; this sole unmatched-ID sentinel means Not sent. All
other identity mismatches remain Unknown. Simulator replies are bounded to 1 MiB; configuration replies to 16 MiB,
including framing. Receipt-query replies are bounded to 16 MiB + 4 KiB, allowing
a retained configuration response plus its identity/receipt wrapper. This does
not widen the original simulator response limit. No artifact payload bytes use JSON.

## Admission, execution and retention

At most 16 connection handlers, no application request queue, one admitted
management operation at a time. Saturation gives explicit Busy before admission;
a slow/malformed client has a ten-second input/output timeout. Existing native
session controls remain available through their separate interface. A response
may consume at most its domain limit; a slow reader cannot accumulate multiple
large owner responses.

The companion owns one cached worker for both management domains. By default it
runs the configured tooling environment with `using PipeWireAORTC;
PipeWireAORTC.ManagementCLI.serve()`. Only explicit management work starts that
worker. The owner retires it after 60 idle seconds following a complete reply.
No operation is interrupted by idle expiry. Ordinary viewing creates no Julia
work, and opening a second GUI does not create a second private runtime.

Generated worker commands use `--heap-size-hint=256M` to collect temporary
compiler/validation allocations sooner. The pinned description subprocess uses
`--heap-size-hint=128M` with its existing `-O0`; compilation remains enabled.
These are soft GC targets, not process limits. Actual memory includes code, native
libraries and live allocations. Backend preflight and independent rebuild jobs
retain their normal compilation and heap policy.

Operation deadline: 60 seconds, except simulator `describe` at 120 seconds for
cold verification plus its pinned description worker. Trusted installation/test
configuration may shorten deadlines/idle grace; it cannot be supplied by clients.
Timeout/loss kills and reaps only the companion worker process group before
releasing input descriptors. Independently accepted systemd rebuild jobs survive.
Shutdown retires that worker group, not any RTC/scientific service.

The owner retains materialized bytes under the existing ConfigurationStore rules;
there is no new automatic materialization garbage collector. Native adapters
continue making/retaining their owned staged payload for native submission,
including uncertain outcomes. Management completion, client disconnect, worker
idle or service restart is not permission to reclaim a potentially consumed
payload. Stored materializations are not connection-scoped.

## Durable receipts and uncertainty

Before dispatching `register`, `get` or `start_rebuild`, reserve the fresh request
ID in an owner-only durable receipt under its state root. Retain at most 256 such
records; capacity exhaustion rejects new mutations, never deletes recovery data.
Write acceptance before dispatch; write the complete worker reply durably before
publishing success. Receipt writes use atomic replacement with file and directory
synchronization. Duplicate IDs reject without redispatch, even after restart.
Read-only list/describe/job and receipt lookup do not consume retained receipt
capacity. These durable management receipts are separate from the retired RTC
session-operation history.

A service restart marks interrupted accepted records Unknown. Worker loss or
possible effect followed by a lost reply remains Unknown; the service never
re-executes it. A client disappearing does not cancel an admitted operation.
The owner closes its input descriptor only after execution is finished or its
worker group has been reaped. A rebuild's own durable job/attempt records and
2,400-second systemd lifetime remain independently authoritative. For an endpoint
`start_rebuild`, the companion injects its accepted ID into the trusted worker
request. ManagementCLI passes it as the owner's `request_id` keyword, and the
job uses that same ID for its durable directory/unit. Direct legacy tooling
retains random UUID job IDs. Thus an explicit `job` read using the original
management ID can recover an accepted job even if the companion dies before
recording its completion reply; neither lookup re-executes the rebuild.

Explicit receipt lookup uses a fresh envelope ID and nested request
`{"protocol":"pipewireao.management/1","op":"receipt","arguments":{"id":"original id"}}`.
It returns the original request identity/domain and `state` (`accepted`, `complete`
or `unknown`), plus `response` only when recorded. This read never replays work or
proves live readiness. SO_PEERCRED limits access to the owning user; the browser
bridge retains its narrower attachment/capability checks and does not expose
arbitrary receipt lookup to network clients. Record IDs are local recovery
identifiers, not mutation authorization. Unknown GUI errors include their owner
request ID for deliberate recovery through owner tooling.

## Installation and compatibility

The RTC owner installs/activates units; GUI clients never run systemctl or a
helper command.
When upgrading an existing installation, select its existing configuration and
simulator roots in `ManagementCLI.install`; the configuration root selects the
artifact catalog, while the management state root holds durable operation
receipts. Former GUI root overrides are not migrated or merged
automatically; root selection and any reconciliation are owner operations. The native companion accepts trusted owner options (`--socket`, `--state-root`,
`--configuration-root`, `--worker-argv`, `--operation-timeout`,
`--describe-timeout`, `--idle-timeout`) for socket,
worker argv, store/state roots and deadlines. Worker argv is a JSON argument
array supplied by the owner, never a client field. Production installation uses
the current Julia executable and selected tooling project. Reuse existing native
GIO/WirePlumber JSON facilities; do not revive the retired Rust RTC coordinator.

The legacy Julia stdio CLIs remain supported for direct owner tools. Migrated GUI
clients use only the endpoint and ignore the former helper command/root variables;
there is no automatic fallback. Missing/incompatible endpoints make optional
management unavailable while native observation/control remain independent.

Acceptance covers two clients sharing one worker; native endpoint/UID/mode and
malformed/bounded admission; slow/oversized I/O; dropped acknowledgements;
receipt lookup and restart without replay; FD input retention; materialization
persistence; idle retirement; and exact existing owner behavior. Effects and
fault injection use test-owned services only. Installed scientific, real-time,
physical and remote qualification remain separate gates.
