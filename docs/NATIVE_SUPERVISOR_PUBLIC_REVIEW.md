# Independent public native supervisor review

2026-10-06. Reviewed `d7a711bf86db5c9da423de7186b4ab8f30afecd5` and its
Julia runtime/coordinator baseline in the clean worktree
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-supervisor-public-review`,
branch `review/native-supervisor-public-d7a711b`.

This review owns only this document. It covers the new Rust public client,
library exports and selected CLI, the Julia staged supervisor runtime and
coordinator, the changed negative Completion grammar, and combined reply
preflight. It does not re-review the author's separate Rust calibration endpoint.
Authorities are repository AGENTS, RTC-ARCH-024 / RTC-DEV-030, the
[supervisor contract](NATIVE_SUPERVISOR_CONTROL.md), and the common native
envelope. The earlier [foundation review](NATIVE_SUPERVISOR_CODEC_REVIEW.md)
remains historical evidence; this record addresses its NSCR-004 integration
gate within the current source/software boundary.

No confirmed production defect was found in this reviewed increment. The
conclusion does not close installed supervisor/source/HEART qualification,
production locator publication/removal, session-picker integration or scientific
and hardware gates. Root's subsequent DeploymentRunner constructor/discovery
work and corrected wait-state locator scope are separate changes.

| ID | Severity | Confidence | Disposition |
| --- | --- | --- | --- |
| NSP-001 | Informational | High | Exact public owner/controller proof and terminal selection verified |
| NSP-002 | Informational | High | Negative Completion preserves a known inner result without overall success |
| NSP-003 | Informational | High | Expanded combined failure reservation independently checked |
| NSP-004 | Integration gate | High | Staged owner source reviewed; actual private-core test and installed gates distinguished below |

## NSP-001 — Public Rust client binds one actual supervisor

`Binding` requires an absolute remote, bounded nonempty node name, positive PID
and incarnation. Optional expected UUID is canonical, nonzero and immutable.
Saved locator parsing is bounded to 4096 bytes, rejects unknown fields, wrong
profile/version, symlinks, nonregular or foreign-owned files; hints supply no
admission or scientific state. Actual connection separately validates the owned
socket and private parent directory.

The actual registry global ID and full-width serial are obtained for both owner
and exported controller. Bound NodeInfo requires no ports/error state, exact
protocol/profile/PID/incarnation and serial, and exact owner UUID. The callback
uses the public PROPS change bit, preserving property evidence across state-only
updates. Ambiguous or replaced registry identities, removal, proxy/core/filter
error and changed metadata cannot silently select a new owner. Retained
capabilities require the current exact controller global/serial/instance.

One caller-owned MainLoop drives the cold connection. Native values are copied
into bounded owned storage during callbacks; no background SCI worker or new
acquisition state machine is introduced. Resource field order drops listeners
before proxies and then their owning registry/core/loop. Connection failure drops
partly constructed resources. Unknown request outcome retires those resources;
subsequent calls cannot reconnect or retry the operation.

Each request uses one absolute deadline, actual owner incarnation, exact current
controller identity and a token above observed accepted completions. The matching
predicate includes operation and all identity fields. A bounded terminal observed
before subsequent retirement can resolve that request while the connection stays
unhealthy for future calls. Earlier retirement, fatal malformed/conflicting
terminal evidence, or a late reply cannot revive it. Matching republication
preserves the first observation time. BeforeSend and UnknownOutcome remain
distinct public errors; submission does not claim a matching completion.

The CLI parses into the existing typed commands, obtains live proof and fresh
Status, then sends an optional explicit command on that same connection and
within the same deadline. Local rendering is JSON for display, not JSON in a
POD. The compatibility `--socket` spelling denotes a native locator and does
not reactivate the former socket client, which is test-only. The standalone
legacy server remains separate migration scope.

**Independent validation:** All six new Rust client tests passed. Tests include
canonical UUIDs, malformed saved hints, terminal/removal ordering, late/fatal
and conflicting evidence, and truthful local rendering. The actual native CLI
binary hash was independently confirmed as
`f4f8adf29a28aea11a915d929b671ac1bffec0fbc569d6d4e3766aa5a228f430`.
That binary was not rebuilt by this review.

**Disposition:** No confirmed defect. Transport/coordinator evidence is separate
from actual subordinate scientific owner and application qualification.

## NSP-002 — Negative Completion retains only the known inner fact

Both languages use exact negative payload:

```text
Struct(Id phase, Bool admitted, snapshot or None,
       Struct(String field, String message, RunnerRecord or None))
```

Phase/admitted consistency and closed operation are checked. A partial inner
record requires Admitted and is decoded using the same outer operation with a
successful inner header. It retains the runner's checked lifecycle/outcome and
operation-specific fields. It cannot turn outer failure into success, accept a
result for a different operation, or use the prior negative grammar. Each error
string is bounded to 8192 UTF-8 bytes; snapshot, when present, retains owned-PID,
profile and nested Status identity validation. Independent admission Rejection
continues to carry no applied inner result.

The coordinator preserves a matched successful runner Start if source Resume
explicitly rejects it. The negative completion then truthfully reports the
Running/Completed inner fact with the source error and `ok=false`. It does not
invent rollback, retry or a fresh snapshot. A later Status reports the actual
runner/source facts. Exceptions after effects with unknown outcome publish Failed
when possible and retain the failure, rather than fabricating a known partial
result. Successful and Rejection fixture bytes remain unchanged by this prototype
negative-grammar refinement.

**Independent validation:** The Rust fixture test passed all 48 shared fixture
cases, including partial result, wrong phase/operation and old-grammar rejection.
The Julia codec suite passed 207 assertions. Both local renderers expose inner
state/outcome while preserving outer `ok=false` and error.

**Disposition:** No confirmed defect. A codec-consistent nested token alone is
not proof that a production owner supplied fresh status; integration supplies it.

## NSP-003 — Reservation includes the expanded failure alternative

Both checked size helpers reserve the common envelope, phase/admitted fields,
future snapshot bound and worst closed runner result. The negative alternative
adds its nested Struct, both maximum error strings and optional actual inner
record; it can exceed the successful alternative. Both implementations reject
arithmetic/capacity overflow at 64 KiB. They inspect borrowed variable catalogs
before materializing them and do not allocate dummy large result catalogs.

The production coordinator queries fresh before-state, validates admission,
and calls the combined preflight before the first source/runner mutation.
`future_snapshot_bound` reserves optional acquisition cursors/window, maximum
closed phase strings and bounded HEART report/child fields. Reviewed operations
do not change the loaded configuration or sink catalog; fixed-width counters and
source generations add no variable byte growth. Read-only catalog overflow
rejects rather than truncating.

**Independent validation:** Both Rust capacity/fixture tests passed. All mutation
variants reach exact 64 KiB reserve and reject one byte beyond their snapshot
bound in both languages. An additional independent actual serialization check
uses 42 distinct property rows, both 8192-byte errors, a valid Active inner
record and the full snapshot: **4 passed**, exact reservation and encoded
length both **20,392 bytes**. Decode retains all 42 Active generation rows. The initial external
fixture used unequal requested/active generations with Active=true and was
correctly rejected by existing result validation; that invalid fixture was
corrected and its log retained. No production change followed that fixture error.

**Disposition:** No confirmed reservation defect. The helper depends on the
owner supplying a proven future snapshot bound; it cannot infer arbitrary future
configuration or catalog changes.

## NSP-004 — Runtime remains the existing serialized deployment owner

The inactive no-port endpoint publishes Preparing on the private core before
owner preparation. Callback ingress stages only bounded commands. The existing
DeploymentRunner dispatches admission, fresh nested observations and coordination
outside callbacks. Preparing/retired phases admit only read-only Status; other
commands reject before effects. Fresh admitted snapshots use actual bound runner,
source/acquisition and HEART clients and currently owned processes.

Every available nested wait receives the accepted ticket deadline and supervision
check. Simulator SourceControlV1 retains its existing limitation: it cannot carry
that absolute deadline into its pre-existing inner HEART reset. The increment does
not claim full inner V1 propagation. Observations are sequential fresh queries,
not an atomic snapshot across processes.

Terminal Quit uses the pre-effect snapshot, publishes the matched result, and
synchronizes the terminal publication before endpoint withdrawal. Cleanup and
post-effect failure remain explicit; saved locator/status/report files do not
satisfy native completion or live admission. The common endpoint continues to
own one pending ticket, one retained completion and independent rejection.

**Required qualification:** Actual launcher/source/HEART bindings and owned
cleanup; production session-locator publication/removal; optional observation
absence; GUI/session-picker consumers; and separate scientific/resource gates.
The test's nested runner/source ledger is a fixture, not installed science.

**Independent actual execution:** The private-core fixture passed **63/63**
with the reviewed Rust CLI, plus **9 + 6 = 15/15** included coordinator checks.
It exercises actual controllers and exact UUID/PID/incarnation/profile proof,
Preparing admission, staged coordinator dispatch, duplicate/conflicting/busy/
malformed/stale requests, combined overflow before effects, accepted expiry,
controller removal and terminal Quit flush. The explicit source Resume rejection
preserves Running/Completed and later fresh Status reports paused source in
both Julia and Rust. The inner runner/source observations and effect ledger
are fixtures; this is actual native transport, not actual subordinate science.

**Disposition:** The NSCR-004 source/cold transport/coordinator obligations
within this increment are independently verified. Installed, publication and
consumer gates listed above remain open. No physical capability or timing claim
is implied by these checks.

## Reproduction and evidence limits

All independent execution used CPU 15, existing dependencies and one build job.
Rust used the shared Cargo target with incremental compilation disabled, the
installed PipeWire library/pkg-config paths and offline locked dependencies:

```sh
CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=1 \
CARGO_TARGET_DIR=/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target \
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
taskset -c 15 cargo test --locked --offline --features live --lib \
  native_supervisor -- --test-threads=1
```

Result: **8 passed**, 70 filtered. This compiles the reviewed library but does
not replace the retained CLI binary. Existing `proc-macro-error2` future
compatibility notice remained; no dependency code was changed.

Julia 1.12.7, one Julia/BLAS thread, from the immutable review worktree:

```sh
taskset -c 15 env JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  julia --startup-file=no --project=deployment/julia -e \
  'include("deployment/julia/test/test_native_supervisor_codec.jl")'

taskset -c 15 env JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 \
  LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
  SUPERVISOR_CLI_BINARY=/home/dgamroth/.cache/rtc-live-controls-20261005/native-filter-target/debug/pipewireao-rtc \
  julia --startup-file=no --project=deployment/julia \
  deployment/julia/test/native_supervisor_endpoint.jl
```

Results: **207 codec assertions** and **63 connected + 15 coordination
assertions**, all passing. The codec process reported the existing mixed
loaded/precompiled dependency-version notice and completed its suite. The
external serialization discriminator additionally passed **4 assertions**;
its script and retained invalid-fixture log distinguish a fixture correction
from a production defect.

Logs under `~/.cache/rtc-native-session-selection-review-20261006/`:
`supervisor-rust-review.log`, `supervisor-codec-review.log`,
`supervisor-negative-capacity.log`,
`supervisor-negative-capacity-invalid-fixture.log` and
`supervisor-connected-review.log`; investigative source is
`supervisor-negative-capacity.jl` in that directory.

The author's full 75-pass Rust library run, Clippy and adjacent Julia suites
were inspected in [the validation record](NATIVE_SUPERVISOR_RUNTIME_VALIDATION.md),
not relabelled as independent runs. No scientific core, installed launcher,
physical device or new target directory was used by this review. The final
review diff contains only this document; local links, trailing whitespace and
final newline were checked.
