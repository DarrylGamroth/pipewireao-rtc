# RTC session discovery integration handoff

Read-only reconnaissance for RTC issues #4 and #8, 2026-10-06. The discovery
contract and fixture module are present on `work/session-discovery-20261006`;
this note identifies the remaining integration boundary. Line references refer
to the inspected `work/native-control-planes-20261005` source unless stated.

## #8 prerequisite: supervisor native endpoint

Issue #4 selection cannot be live until issue #8 supplies a public native
operator endpoint owned by the existing `DeploymentRunner`. The minimum
contract is one cold, no-port endpoint on the supervisor's existing private
PipeWire remote, with a fresh, correlated, read-only status query and an
advertised deployment-supervisor authority. Its identity/status must expose
stable session UUID, supervisor PID, endpoint incarnation, the exact remote
and node name, lifecycle, observed global ID and `object.serial`, and the
positive token of the newly processed status query. The native client must
validate the remote, owner process and endpoint incarnation. A listing record
is only a locator; it must never substitute cached state for this query.

The common envelope alone is insufficient: `docs/NATIVE_CONTROL_ENVELOPE.md`
lines 4-6 says operation schemas are separate and the header confers no
authority. The supervisor status/query operation and its identity payload,
correlation, timeout, and failure semantics need a reviewed #8 owner contract.
The migration design `docs/NATIVE_CONTROL_MIGRATION_DESIGN.md` lines 277-282
puts supervisor internal controls in phase C and public operator controls in
phase F. It explicitly retains the legacy public broker temporarily at lines
279 and 290-291; phase F is therefore the prerequisite for the discovery
selection callback, even if phase C has moved internal runner communication.

## Exact supervisor integration sites

`deployment/julia/src/deploy.jl` already has the sole lifecycle owner:

- `DeploymentRunner` and its `record`, runtime, and runner-client fields are
  declared at lines 301-324. Add discovery state to this owner, not a new
  service, polling broker, or independent lifecycle owner.
- `_run_locked` creates the private core/remote at lines 954-987, establishes
  the actual UUID only indirectly today (runtime basename at 967), starts the
  runner and waits for fresh `Ready` at 999-1017, then processes
  `session-start` and marks admission at 1018-1029. Publication belongs after
  the supervisor endpoint exists and its status identity is coherent; do not
  publish a claim that the not-yet-implemented native endpoint cannot verify.
  The contract's record needs a stable UUID and endpoint incarnation generated
  for that endpoint lifetime; the runtime basename is not that UUID.
- `native_control` at 573-583 is currently specifically the Rust runner client.
  `coordinate` at 585-646 forwards the public operator command to it and
  composes source controls. Do not treat the runner endpoint as supervisor
  authority or route discovery selection around `coordinate` to source owners.
- `serve_control` at 648 onward and public broker setup at 1022-1033 are the
  current public ingress. They remain legacy until phase F. The future native
  supervisor endpoint needs to publish its own fresh status while preserving
  `DeploymentRunner` as the executor of `coordinate`.
- `stop` begins at 913; shutdown and record finalization are in
  `_run_locked` from 1034 and `main`'s `atexit` handler at 1322-1335. Remove
  the locator by matching UUID, PID, and incarnation during ordinary owner
  cleanup, after endpoint withdrawal/stop is known. The remover must not
  delete a replacement incarnation's record.

`deployment/julia/src/native_session_discovery.jl` already provides the bounded
record codec and filesystem contract: publication/removal are at lines 256-286,
listing at 309-319, and verifier-driven exact-record selection at 328-349.
Selection checks stable ID, PID, incarnation, remote, node name and
`:deployment_supervisor` authority at lines 321-349. It deliberately injects
the verifier; no production native-client adapter currently exists. Its line
references are in the discovery worktree.

## Fresh selection and CLI/UI work

The deployed Julia CLI is local-runtime-centric today. `main` reads
`state.json`, checks `admitted`, and calls the Unix socket at
`deployment/julia/src/deploy.jl:1306-1316`; `wait_state` and `shutdown` also
read mutable state files at 1088-1129. Add an explicit list/select path that
uses `list_sessions` for hints and `select_session` with the production native
status verifier for a user-selected entry. On success, retain the returned
global ID, `object.serial`, and query token as the selected native identity;
subsequent controls must go through that verified supervisor endpoint and
normal operator coordination. On failure report inaccessible/replaced and
require a new explicit selection. Do not silently fall back to state JSON or
retry a mutation.

The GUI session picker is a separate consumer/integration gate, not part of
this repository's existing RTC GUI implementation. The contract explicitly
leaves the GUI adapter and picker open (`docs/NATIVE_SESSION_DISCOVERY.md`
lines 104-110). Any picker should list unverified labels, perform fresh
read-only verification on explicit selection, display fresh lifecycle, then
route later operator actions through the selected supervisor. Listing or
selection must not launch, mutate, acquire, or create a gating observer.

The existing GUI issue documented here is issue #1, a recorded-FITS restart
discard-counter caching correction, closed and integrated under
RTC-DEV-004/011/022 (`docs/README.md:28-31` and
`docs/UI_RESTART_ISSUE_1.md:1-10`). It is a distinct completed defect; do not
expand #4/#8 discovery into another restart-caching change. No GUI picker code
or session-selection issue is identified in the inspected RTC repository.

## Pending gates

- #8: agree and implement the supervisor endpoint's operation-specific fresh
  status contract and owner-native client; the existing common envelope is not
  enough.
- #8: create stable session UUID/incarnation and publish/remove records from
  `DeploymentRunner` at lifecycle-safe boundaries while keeping the supervisor
  the only lifecycle owner.
- #8: replace public broker/state-file control and readiness authority as
  specified by migration phase F; ensure timeout/removal/replacement are
  explicit failures.
- #4: implement the production verifier against the exact remote and endpoint;
  verify process PID, authority, UUID/incarnation and registry identity, and
  issue a new matching status query.
- #4: wire the Julia CLI list/select surface and a separate GUI picker, then
  qualify cross-process selection and stale/replaced/inaccessible cases.
- Current discovery module tests validate only codecs, filesystem rules and an
  injected verifier fixture. They do not demonstrate any of these integrations.
