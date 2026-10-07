# WirePlumber realization review

2026-10-07. Independent architecture, source and receipt review of the selected
WirePlumber realization integration. The reviewer changed only this document
and ran no tests, builds or runtime processes. The chronological findings below
retain fail-before evidence and are followed by the final bounded acceptance.

## Revision and scope

RTC baseline: `8886d6ac35c41f71b532f610a15c36f4f63c40be`, branch
`work/wireplumber-realization-20261007`, worktree
`/tmp/rtc-wireplumber-realization-20261007`. Review began with other agents'
changes present in `src/live.rs` and untracked realization policy, test, design
and Rust helper files. Those changes were preserved. This review applies to the
working candidate, not just the baseline commit.

Reviewed source SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `deployment/wireplumber/realization.lua` | `1b03ef4fb26dbd9f90d69e90502ad6ae12bddddd5a1c82419387b06507fa0ed8` |
| `deployment/wireplumber/test_realization.lua` | `4dbb9ccf1351e27fc202fd47a4b2401aca5d1305280d4049f34cabb3478bee19` |
| `deployment/wireplumber/test_realization_links.jl` | `74ec4c1084827859a489ef7636e91b2b8da37cad5abd9103839d4342abcc6661` |
| `deployment/julia/test/native_control_private_core.jl` | `78153f6ddc3577e7b7b67a388da801c07114bbc35e81b2e68cdba72eb77b7777` |

WirePlumber source inspection used
`/home/dgamroth/workspaces/codex/pipewire/wireplumber`, HEAD
`bdc17eb2c419cbe41dbb248cf20cbe93370ee2f7`. This identifies inspected source;
it does not establish the binary revision used by each experiment.

Authorities are the accepted workstation boundary in
[architecture](../../architecture.md), RTC-DEV-003/004/013/030 in
[operations](../../operations.md), and AAR-01/02/04/09 in the
[architecture review](../../APPLICATION_ARCHITECTURE_REVIEW.md). The
[candidate design](../../WIREPLUMBER_REALIZATION_DESIGN.md) does not itself
change normative ownership or qualify a production transfer.

## Decision

The ephemeral inactive Filter and monotonic typed phase are an acceptable
conditional design for the selected trusted private core. WirePlumber creates
and withdraws external links; RTC retains scientific readiness, source hold and
release, reset, admission and failure handling. The projection introduces no
second caller mailbox or scientific lifecycle.

Node serial and actual node/client provenance remain RTC checks before
projection, before READY and during required-object monitoring. WirePlumber
checks exact port and client identities and each port's parent node ID. It does
not independently prove that a supplied client owns the supplied node. Separate
typed ObjectManagers avoid mistaking a port for a client and avoid scientific
Node Props subscriptions: Lua ObjectManager requests all supported features.
Documentation must preserve this precise allocation.

The selected FGN and JFG clean deployments now have passing receipts, reviewed
in the latest qualification section below. Each covers two acquisitions, native
Stop/Reset/Resume, actual manager-owned links and complete captured-group
cleanup. The separately inspected loss, held adapter retry and fresh-deployment receipts
close the selected gates below. See the final acceptance section for the exact
qualified scope and exclusions.

## Findings

### WPR-01 — Creator proxy destruction does not cover registry removal

**High severity; high confidence. Confirmed native failure and source mechanism.**

Affected code: the captured Link listeners and `removed()` in
[realization.lua](../../../deployment/wireplumber/realization.lua).
Upstream `lib/wp/proxy.c:proxy_event_removed()` only traces the event; it does
not emit `pw-proxy-destroyed`. Thus the earlier destruction listener did not
establish detection of an externally destroyed Link global.

Observed evidence: `/tmp/rtc-wp-realization-links-20261007-attempt5.log` and
the corresponding `receipt.json` and `wireplumber.log`. The experiment reaches
the fifth realization, the registry snapshot contains its marker and no Link,
and the ten-second acknowledgement/zero-links wait expires. The first four
cases are recorded; the external-destruction case is not recorded as passed.
Attempt 6 also fails this wait. A later `runtime-removed` log during teardown is
not evidence that Link removal itself was handled.

Remediation: retain creator failure/destruction listeners and add a Link
ObjectManager. Capture each created proxy's bound ID and withdraw its scope
when that Link global is removed. The reviewed source implements this path.
Within a live scope, the first removal of a captured ID must remain terminal;
later ID reuse cannot restore the scope. This map is local removal correlation,
not the full identity proof used by RTC admission.

Required validation: rerun the same external `destroy_global!` case and show
marker acknowledgement, zero correlated links, no replacement creation and
successful explicit fresh realization. Cover removal while activation is
pending as well as after links become usable.

Pass-after evidence: `/tmp/rtc-wp-realization-links-20261007-attempt7.log`
reports 33/33 passing assertions. Its `wireplumber.log` records
`RTC_REALIZATION_WITHDRAW 18:24 link-removed` followed by acknowledgement.
Its receipt records generation 5, `external_link_destroy=true`, marker
`[18,24]`, Link `[19,25]` and zero remaining links, with overall success true.
The receipt identifies build `/tmp/wp-ao-pilot-20261006/build`; the experiment
does not itself establish that build's complete provenance.

**Disposition:** verified correction for the isolated external removal of a
usable Link. Cold pending-removal case present; native pending-activation and
deployed failure qualification remain open.

### WPR-02 — Initial ObjectManager cache absence was treated as endpoint loss

**Medium severity; high confidence. Confirmed source behavior.**

The separate marker, port and client ObjectManagers populate independently.
The earlier `advance()` failed immediately when a port was not yet cached,
even though that port could already exist on the server.

The reviewed `advance()` first waits for the complete declared port/client
cohort within its finite admission timer, then sets `scope.captured`.
`removed()` still fences explicit removal of a declared endpoint, including
before complete capture, and treats missing endpoints after capture as loss.
An unrelated removal no longer converts initial cache absence into failure.

Required validation: present the marker before a required port's discovery;
show no creation or premature withdrawal, then creation when discovery
completes. Missing endpoints must time out. Removing a declared endpoint must
remain terminal even if a replacement appears.

**Disposition:** source correction reviewed; the cold suite contains delayed
discovery and declared-removal cases. Native asynchronous-discovery coverage
remains to be attached.

### WPR-03 — Rejection acted before marker authority was established

**High severity; high confidence. Confirmed source behavior, corrected.**

Earlier `inspect()` could withdraw and destroy malformed or wrong-runtime
markers before checking the selected manager. It also ignored changed manager
identity before comparing an already accepted immutable snapshot.

The reviewed code ignores an unrecognized initial marker, checks exact manager
and runtime client identity plus marker profile and creator client ID before
acceptance, and checks immutable mutation before handling a new snapshot of an
accepted marker. An accepted malformed or mutated intent withdraws its own
scope. The cold suite contains wrong-manager, wrong-creator, malformed and
immutable-mutation cases.

Required validation: an unowned marker must survive without created links;
accepted manager/cohort mutation must remove the old scope without allowing a
replacement manager to adopt it. A self-declared profile/name is not a general
security boundary against untrusted clients on a shared core.

**Disposition:** corrected in reviewed source; restricted to the declared
trusted private-core deployment, with deployed authority gates still required.

### WPR-04 — Endpoint provenance checks needed an explicit allocation

**High severity if claimed as complete; high confidence. Adjudicated design.**

`endpoint_present()` validates exact port/client lookup, port direction and
numeric parent node ID. It does not compare the node serial or establish the
node/client ownership relation. The earlier single object catalog also allowed
an arbitrary indexed object to satisfy a client lookup.

Separate port/client catalogs correct the interface-type issue. The agreed
allocation retains node serial and ownership validation in RTC before
projection and admission, followed by ongoing required-object monitoring.
WirePlumber need not subscribe to scientific Node Props to duplicate those
checks. Wrong node serial or forged client provenance must therefore be
rejected by RTC admission; the Lua policy alone does not provide that proof.

The standard Link factory accepts endpoint IDs without atomic serial
comparison. Neither this allocation nor custom correlation properties prevent
every transient link during endpoint replacement. Required behavior is held
ingress, rejection before admission and bounded withdrawal.

**Disposition:** accepted conditional allocation; requires integrated RTC
negative tests and accurate documentation before enablement.

### WPR-05 — Native filtering is not strict envelope equality

**Medium severity; high confidence. Partly corrected, explicit limitation.**

The reconstructed typed `params` Struct rejects primitive tag substitutions:
SPA property filtering compares the Struct's typed bytes. The earlier decoder
nevertheless accepted extra outer properties and did not check the object ID.
The reviewed decoder now requires object ID `Props` and only the outer `params`
property.

WirePlumber Lua `parse()` maps object properties into a Lua table and overwrites
duplicate keys. The current check consequently does not establish rejection of
duplicate outer properties. The cold suite substitutes `filter()` with a stub,
so it is not native type-validation evidence. Passing attempt 7 records the
native wrong-phase-type case as generation 4, acknowledged with zero links.

Required validation: native wrong primitive types, wrong object ID, extra
properties and nested arities; bound the encoder's payload. Preserve the sole
trusted RTC encoder assumption. Supporting arbitrary publishers would require
strict native property inspection or an equivalent validated decoder.

**Disposition:** outer-envelope source correction reviewed; duplicate-property
limitation retained, not represented as complete hostile-input validation.

### WPR-06 — Withdrawal must fence pending activation before acknowledgement

**High severity; high confidence. Source obligations reviewed; native gate open.**

Upstream Lua activation supplies no cancellable. Public
`wp_object_deactivate()` acts on currently active features and does not cancel
queued activation. Merely clearing Lua references is also insufficient because
ObjectManagers can retain Link objects.

The reviewed policy sets a terminal flag, retains every Link, counts pending
callbacks, deactivates a captured Link again when its late callback arrives,
and acknowledges only after pending count zero, explicit deactivation and a
successful manager-side `Core.sync`. Unknown activation-submission outcome
retains its pending count. Sync failure produces no acknowledgement. RTC's
deadline must turn missing acknowledgement into cleanup failure rather than
successful OFFLINE or automatic retry.

`scope.creating` and per-Link `advanced` prevent unrelated discovery events
and repeated usable-state signals from creating duplicates or advancing twice.
The cold suite exercises these orderings. Native asynchronous cancellation and
failed intermediate negotiation remain required; cold callbacks do not prove
server event ordering or removal semantics.

**Disposition:** source safeguards reviewed; native cancellation/drain evidence
and integrated bounded failure handling remain qualification gates.

### WPR-07 — Boolean intent cannot distinguish preparation from withdrawal

**High severity; high confidence. Derived ambiguity, design corrected.**

Snapshot observation can coalesce Realize followed by Withdraw. An initial false
Boolean could mean either preparation or withdrawal and cannot safely choose
between ignoring the marker and acknowledging it.

Use monotonic typed Id phases Prepared = 0, Realize = 1, Withdraw = 2. A first
observation of Withdraw fences and acknowledges without creating links.
Prepared does not authorize creation. Once Realize publication was attempted,
even with uncertain outcome, RTC must publish Withdraw and await its fence;
owner-local dropping is allowed only when Realize was definitely never sent.

**Disposition:** accepted design and reviewed implementation; cold case present.
Passing attempt 7 records the first-observed-Withdraw native case as generation
3, acknowledged with zero links. Arbitrary native coalescing schedules remain
beyond that single case.

### WPR-08 — Isolated test core disabled passive links

**High severity for transfer; high confidence. Confirmed test-configuration defect.**

Attempt 5 reports a failed passive assertion using registry properties.
Attempt 6 checks public Link Info properties and still observes `false` for
declared `true`. Both attempts report 28 passed, one failed and one errored.
Changing the observation surface alone therefore did not establish parity.

The isolated helper loaded the standard Link factory without enabling
`allow.link.passive`. PipeWire's `src/modules/module-link-factory.c` documents
the default as false and explicitly removes `link.passive` when it is disabled.
The inspected helper change introduces `allow_passive=false` as an optional
keyword, preserves the previous default for other callers and passes that value
to the factory. This probe explicitly selects `allow_passive=true`. The existing
`deployment/templates/core.conf.in` already enables passive links.

Attempt 7 retains the same Lua Boolean projection and verifies public Link Info:
generation 1 reports `link.passive=false`; generation 2 reports
`link.passive=true`. Both withdraw to zero links and the full suite passes.
This supports the factory-configuration explanation; no Lua Boolean conversion
change is credited. The test-configuration correction is separate from the
policy source fix in WPR-01.

**Disposition:** verified for the isolated passive/non-passive native cases.
Failed attempts remain failed; selected deployed scientific passive behavior
is not qualified by this receipt.

## Validation and promotion limits

The temporary experiment paths above are evidence locators, not durable
repository receipts. The primary agent must preserve the logs/receipts and bind
any later results to their actual source and dependency revisions. Later
verification should append dispositions to these stable IDs rather than erase
failed attempts.

This review does not qualify CPU FGN/JFG with CUDA AOS deployment, source
revocation timing, manager/runtime/core death, endpoint ID reuse, native pending
cancellation, multi-link rollback, same-runtime RTC unload/retry, scheduling,
allocations, latency or hardware behavior. The isolated native source/sink
experiment is distinct from the selected scientific deployment. Cold test
doubles do not establish native serialization or registry-event semantics.

Before production enablement, RTC-DEV-003/013 must allocate link ownership
explicitly, RTC-DEV-030 must document the narrow typed intent projection, and
RTC-DEV-004 must retain successful-cleanup requirements. Readiness always
requires the actual exact link cohort and current endpoint provenance; a log,
marker, process state or successful factory call cannot release acquisition.

## Integrated implementation review

The subsequent review covered `src/live.rs`, `src/live/{wireplumber,
realization,realization_marker}.rs`, `src/main.rs`, the Julia session-manager
launch integration, the opt-in package preparation script and the deployed
qualification coordinator. Other agents were editing these files concurrently;
the reviewer changed only this document. The source observations below are not
a production acceptance or a claim that the selected deployments passed.

Additional evidence inspected:

- [Current native run](native-current/test.log): 33/33 assertions pass; this is
  the refreshed isolated mechanism run, separate from deployed RTC admission.
- [Delayed callback run](native-pending/test.log) and
  [receipt](native-pending/receipt.json): 12/12 assertions pass. The loaded policy
  uses a test wrapper to delay delivery of the public activation completion by
  500 ms. The marker remains present while the policy considers activation
  pending, and acknowledgement follows delayed delivery with zero links.
  This verifies that callback schedule; it does not delay the server's actual
  negotiation or establish worst-case cancellation latency.

The integration preserves several reviewed constraints: default connections
retain RTC link creation; selected WirePlumber links are borrowed observations
and report `owned_links = 0`; endpoint validation includes node/port/client
serials and actual node/client provenance; the required-removal map fans out to
all overlapping snapshots; Link Info endpoint/passive/lifetime/Format checks
run before admission and in monitoring. Partial Link Info notifications retain
previous Format or properties only when their corresponding change-mask bit
is absent. The scientific Node Props subscription surface is not broadened.

Julia pauses the native source before starting the required manager and starts
that manager before spawning the runner. Exact client discovery is tied to the
spawned process. The new role participates in existing process checking,
placement and cleanup. The package preparation script copies to a fresh
destination, preserves the sealed scientific artifacts and records replacement
binary/resource hashes. These source facts still require installed-package
and selected deployment evidence.

### WPR-09 — Prior marker loss could be mistaken for withdrawal acknowledgement

**High severity; high confidence. Confirmed source defect, corrected in source.**

The first integrated `withdraw_wireplumber()` accepted any observed marker
removal plus zero currently correlated links. If the marker disappeared while
RTC remained alive and the manager still had a pending activation, cleanup
could treat that earlier disappearance as its new withdrawal acknowledgement.
Current zero links alone does not prove the other client has drained work.

The revised code synchronizes before checking marker presence, records
acknowledgement eligibility only when a live marker receives successful
Withdraw publication, and retains that eligibility across bounded cleanup
retries. A prior observed disappearance cannot create eligibility. Unknown
cleanup retains the session and marker handles; a later load must cross the
same fence. Exact manager disappearance plus zero correlated links remains the
separate creator-lifetime fence.

Reviewed correction SHA-256 for `src/live/wireplumber.rs`:
`2ea4fbe5772c0e7123d3c4682ec5d70cb4dead7f23b2bb172494c32058c859d9`.
The focused `withdrawal_fenced` test distinguishes ineligible removal, valid
acknowledgement, manager revocation and remaining links. That helper test does
not establish native event ordering.

Required validation: unexpectedly remove the marker while an activation is
pending and the manager remains alive; cleanup must remain unknown and must
not permit a fresh same-runtime realization. Demonstrate normal acknowledged
withdrawal and eventual manager-loss cleanup separately. The private-core
authority assumption still excludes an unrelated actor impersonating the
manager's destructive acknowledgement after Withdraw publication. In
particular, arbitrary external destruction of the marker after publication is
outside this acknowledgement guarantee: observing removal cannot identify the
actor that requested it.

**Disposition:** narrow source correction reviewed. The latest qualification
section records the subsequently passing integrated native negative case;
same-runtime lifecycle qualification is a separate obligation.

Additional native evidence inspected:
`/tmp/rtc-wp-realization-marker-loss-20261007-attempt1` and its adjacent test
log report 12/12 assertions passing. With public activation completion delivery
delayed by 500 ms, owner-side marker removal is followed by manager drainage
after the delayed callback, with zero remaining links. The receipt explicitly
records acknowledgement eligibility as false. This test does not execute the
Rust withdrawal decision, so it does not close the integrated negative case or
same-runtime retry obligation above.

### WPR-10 — Loss qualification lacked a live acquisition witness

**Medium severity; high confidence. Confirmed test-coverage defect, corrected.**

The first loss coordinator waited only for source sequence at least 16. A
delayed coordinator could observe a completed 512-frame source and still inject
loss, then incorrectly describe the result as failure during acquisition.

The updated coordinator captures `before_loss` and requires RTC Running,
source running, not completed, and sequence in [16, 512) before injection.
Reviewed correction SHA-256 for `deployment/qualify_wireplumber_realization.jl`:
`69152e418bb60ec5c9f04553cd119ff009c375419e23f88fb1fed6452fc63158`.
This is a pre-injection witness, not an atomic guarantee against completion
between observation and the external action. Receipts must retain the witness
and identify which failure state was actually demonstrated.

**Disposition:** source correction reviewed; no deployed loss receipt was
accepted by this reviewer at this stage.

### WPR-11 — Manager-loss cleanup needed an explicit normative exception

**Medium severity; high confidence. Confirmed contract/source mismatch, revised.**

The implementation allows exact selected-manager client disappearance and zero
correlated links to complete cleanup. Initial normative edits required marker
destruction acknowledgement unconditionally, which a dead manager cannot
provide. Non-lingering links belong to that exact creator client; its removal
provides a distinct resource-lifetime fence without authorizing replacement
adoption or source release.

The subsequent RTC-DEV-003/030 edits explicitly allow this alternate fence and
prohibit treating marker disappearance observed before Withdraw publication as
acknowledgement while the manager remains alive. Required manager loss remains
a fault; successful resource cleanup does not silently readmit acquisition.

**Disposition:** explicit allocation accepted in the revised requirement text;
manager-loss and replacement receipts remain required before promotion.

### WPR-12 — Rust negotiated-Format decoding lacked fixed String/Array choices

**High severity for affected admission; high confidence in the parser gap.
Source correction reviewed; selected deployment manifestation not established.**

The reviewed `LinkContract::observe()` passes the complete native Format to
`PodDeserializer::deserialize_any_from`. The pinned PipeWireAO-rs `f2d8689`
generic Choice decoder supports numeric, Id, Fraction, Rectangle and Fd
children, but returns `InvalidType` for String or Array children.
`NdArrayFormat::from_properties` accepts fixed Id/Fraction choices but requires
a bare Int Array shape; RTC's schema accessor requires a bare String.

The public negotiated format representation can retain fixed Choice(None)
wrappers. The native Julia probe already has `fixed_format()` to unwrap exactly
one fixed child, including String and Array, while rejecting non-fixed choices.
Consequently a valid negotiated Format with those wrappers cannot pass the
reviewed Rust path, despite the isolated Julia probe accepting its contract.
Whether the selected FGN/JFG run emits that representation must be established
from its native Format or admission diagnostic, not inferred from a successful
probe using another decoder.

Remediation: support the fixed native representation through public SPA APIs
or a bounded ABI-aware normalization before the generic decoder. Retain strict
checks for object type/ID, unique properties, fixed choices, element encoding,
shape, layout, rate and schema. Do not remove Format validation or equate
EnumFormat compatibility with negotiated Format.

Required validation: exact native fixed String/Array choice inputs pass after
normalization; non-fixed or malformed choices fail; selected deployed actual
Formats pass the same checker. Preserve any fail-before runtime evidence.

The subsequent [link_format.rs](../../../src/live/link_format.rs) correction
normalizes at most 64 KiB of public native SPA POD data before the generic
decoder. It checks object type/ID and exact extent, property/value boundaries
and padding extent, and accepts only a single complete child of an unflagged
Choice(None). Scalar widths, Array child width/divisibility and String
termination/UTF-8 are checked before deserialization. Property keys and flags
are preserved. `LinkContract::observe()` uses this decoder; later scientific
contract validation remains in place. Missing Format/properties in a partial
notification retain old values only when the corresponding change-mask bit is
absent.

Independently reviewed correction SHA-256 values:

- `src/live/link_format.rs`:
  `8d7f3f8e1e0503b623161ebb72973a79ab133e6872cde779b86f340dc8753fec`.
- `src/live.rs`:
  `d479cebdac8eb41bbbfcf58ea8b479dc38b09d3f183105ccf6ace44c32676954`.

The three focused test bodies cover fixed scalar/Array/String choices and
property flags, non-fixed choices and wrong arity, malformed child widths,
String termination, truncated input, extra bytes and wrong object ID. The
implementation worker reports fixture fail-before/pass-after, full Cargo tests
and strict Clippy passing. This reviewer inspected the source and test bodies
but did not run them or inspect those execution logs at this stage. No new
significant source defect was found in the bounded normalization.

**Disposition:** source correction accepted for the fixed-choice parser gap;
retain the focused execution receipts. This does not establish that the parser
gap caused the selected deployment's timeout, or that the deployed session now
passes admission.

## Latest primitive evidence and unresolved deployment behavior

The reviewer also inspected receipts and adjacent test logs for:

- `/tmp/rtc-wp-realization-empty-initial-20261007-attempt1`: 14/14 pass with an
  initially empty inactive Filter, subsequent intent, usable Link and withdrawal.
- `/tmp/rtc-wp-realization-empty-coalesced-20261007-attempt1`: 14/14 pass with
  immediate Prepared-to-Realize publication; the manager did not observe
  Prepared, and realization/withdrawal still completed.
- `/tmp/rtc-wp-realization-empty-roundtrip-20261007-attempt1`: 14/14 pass with
  an owner-side roundtrip between those publications; the manager observed
  Prepared and realization/withdrawal completed.

These isolate publication schedules using the Julia native probe. They do not
prove the Rust bootstrap path or the full FGN/JFG deployment. At that earlier review stage, the primary agent
reported that a selected FGN attempt still timed out with its source held at
sequence zero after the Format correction; diagnostic investigation was still
open. WPR-13 and the latest qualification evidence below supersede that status. Keep its
failed evidence separate from the passing primitive and parser checks.

The integrated review remains conditional on the outstanding dispositions.
Pending-callback primitive evidence alone did not close WPR-09, and the WPR-12
source correction alone did not establish deployed success. Later independent
receipt review below records the completed integrated negative and clean runs. Full scientific and failure
qualification requires the exact final runner, policy, package and dependency
receipts.

### WPR-13 — WirePlumber public POD filtering has a 1024-byte output limit

**High severity for selected multi-link realization; high confidence. Capacity
correction, C regressions and selected clean native qualification reviewed.**

Independent source inspection confirms that WirePlumber's
`lib/wp/spa-pod.c:wp_spa_pod_filter()` uses a 1024-byte stack array with a plain
SPA builder and no overflow callback. It returns NULL whenever SPA filtering
fails, including insufficient builder capacity. The Lua realization decoder
uses NULL to report incorrect native intent types, so capacity failure can
appear to be a serialization mismatch.

The public SPA filtering implementation creates an internal dynamic builder,
but enables its growth only when the caller's builder has callbacks. That
internal implementation therefore does not remove this wrapper's capacity
limit. The identical large `params` Struct must be copied into the result, so
an otherwise compatible projection larger than the stack capacity cannot pass.

The three-link native Rust and Julia receipts measure 1160 bytes and reach
this failing filter call. The native Rust two-link measurement is reported as
864 bytes; earlier 1168-byte and 872-byte estimates were incorrect. Passing
smaller projections does not qualify the larger selected declaration. The later three-row fail-before/pass-after receipts below directly
establish the capacity distinction. This distinguishes the capacity defect from
WPR-12's Rust negotiated-Format representation gap.

**Adjudicated remediation:** preserve the existing public filtering API and
native intersection semantics. Initialize a public `spa_pod_dynamic_builder`
with the existing stack buffer and a nonzero growth step; pass its builder to
`spa_pod_filter`; create the owned `WpSpaPod` result before cleaning the dynamic
storage; clean it on both success and failure. Include the public dynamic
builder header explicitly. Retain NULL for filtering failure. Allocation-error
propagation inside SPA has a separate limitation recorded in WPR-14.
Use a dedicated WirePlumber feature worktree and bind the AO build and packaged
library to that revision. The RTC projection's 16 KiB and 32-link limits remain
unchanged.

This corrects an existing public API implementation. It needs no new Lua
iterator/equality API, weakened type checks, smaller selected graph, new
protocol or scientific-code change. An input-sized allocation alone is not a
general replacement: intersection may combine constraints and exceed either
individual input's size.

Required verification: native filtering above 1024 bytes succeeds for equal
typed Structs and NULL-filter copies; a late differing typed field still fails;
small existing cases retain behavior; the returned object remains valid after
builder cleanup. Exercise output growth beyond the original stack capacity and
preserve actual three-row fail-before/pass-after evidence. Re-run the selected
RTC startup with that exact library before claiming that its observed timeout
was corrected.

**Patch review:** the dedicated worktree
`/tmp/WirePlumberAO-pod-filter-20261007` changes only the public wrapper and its
C tests. Reviewed SHA-256 values are
`50895891e2742079f52093e03255992a4316ccfb5cf599ded989db9b27fbeecc`
for `lib/wp/spa-pod.c` and
`47aa24817600906b2004ffa1a3d3d2ee19c7526e0a3e6f1c5073908241d3b1e7`
for `tests/wp/spa-pod.c`. The function signature and transfer ownership remain
unchanged. It calls the same native intersection implementation, copies into
an independent owned `WpSpaPod` before cleanup, and cleans dynamic storage on
normal success and filtering failure. The small path retains its stack buffer;
large filtering may allocate both SPA's internal scratch buffer and the outer
result buffer. This is control-plane work, not a scientific process callback.

**Observed C evidence:** `/tmp/wp-pod-filter-fail-before-20261007.log` and
`/tmp/wp-pod-filter-null-fail-before-20261007.log` show the equal large Struct
and NULL-filter copy assertions fail on NULL results before the correction.
`/tmp/wp-pod-filter-pass-after-20261007.log` records the complete SPA-POD test
executable passing. The inspected Meson test log contains all 14 passing cases:
nine existing cases plus small filtering, large equal filtering, a late large
mismatch, large NULL-filter copy and large result lifetime after both inputs are
destroyed. These fixtures exercise growth beyond 1024 bytes and independent
result ownership. They do not exercise allocation failures. Sanitizer option
environment variables in a test log do not establish a sanitizer-enabled build.

**Disposition:** accept the minimal wrapper change for the demonstrated capacity
and normal lifetime correction. No Lua API or RTC protocol change is needed.
Record the SPA allocation-failure limitation separately. Native three-link
fail-before/pass-after, the complete isolated mechanism suite with the patched
library and selected clean scientific deployments are now recorded below.
These results do not extend to arbitrary deployments or allocation failure.


### WPR-14 — SPA filtering does not reliably propagate internal allocation errors

**Medium severity in the selected trusted bounded deployment; high confidence in
source path, fault-injection result pending. Dependency limitation.**

Affected dependency: the actual compilation headers under
`/opt/pipewireao/include/spa-ao-0.2/spa/pod/`, specifically `dynamic.h`,
`builder.h` and `filter.h`. The installed dynamic/filter headers match the
reviewed PipeWire source byte for byte. The WP capacity change enables the
existing public SPA dynamic growth path; the wrapper does not introduce its own
allocator or filtering algorithm.

**Observed source:** `spa_pod_dynamic_builder_overflow()` returns an allocation
error on failed `realloc`; first stack-to-heap failure leaves its data pointer
NULL while retaining the old capacity. `spa_pod_builder_raw()` advances the
logical offset even after failed growth. Several writes in
`spa_pod_filter_part()` ignore the returned error. `spa_pod_filter()` can then
copy the internal builder's logical offset from its buffer without checking
that the offset fits its capacity.

**Derived consequence:** with an equal Struct exceeding the internal 4096-byte
growth capacity, allow the first internal allocation and fail a later one. The
internal buffer remains allocated at its previous size, while its logical offset
continues beyond that size. If the outer result allocation succeeds, its copy
can read beyond the internal allocation. First internal allocation failure has
a different NULL/partial-output path. These are source-derived failure paths;
they have not been demonstrated with allocation injection in this review. The
five new C fixtures cannot establish graceful allocation-error handling.

The WP wrapper does clean its own dynamic buffer on returned failure, and copies
the result before cleanup on success. Its owned-copy implementation already uses
GLib allocation, whose normal out-of-memory policy terminates the process.
Replacing only the outer builder callback with WP's existing `g_realloc` policy
would leave SPA's nested `realloc` behavior unchanged.

**Required discriminating check:** use a deterministic allocation shim and a
memory checker on equal Struct filtering. Permit the first internal growth,
fail its next growth, and permit the outer allocation; check for an invalid read
or partial result. Separately exercise first internal allocation failure and
NULL-filter outer allocation failure. Keep the ordinary capacity regression
unchanged. Any remediation must follow the established dependency failure path,
not introduce a second filtering implementation.

**Disposition:** retain as an explicit dependency allocation-failure limitation;
do not claim graceful NULL-on-OOM, fault-injection coverage, or arbitrary
publisher availability/security. The selected sole trusted RTC encoder bounds
its intent at 16 KiB, but that bound does not prove allocation cannot fail.
The primary agent adjudicates this separately from acceptance of the normal
capacity correction. No speculative production patch is requested by this
finding.


## Latest qualification review — selected clean deployment and retry boundaries

This section supersedes earlier pending status only for the evidence explicitly
listed here. The reviewer inspected source and receipts without running runtime
processes or modifying implementation.

### Native capacity correction and pending marker loss

The paired directories `/tmp/rtc-wp-realization-rust-count3-20261007-before`
and `-after` contain the same Rust test binary SHA-256
`59f0118c62f075ce56dc5eb0f2621f39e884663b32b0e6023503094411562157`
and unchanged Lua policy. Both log three links and a 1160-byte intent. Before,
the Rust bootstrap test fails; with the corrected WP library it passes 1/1
(and the enclosing native fixture passes 8/8). This proves recognition of the
same Rust projection; this bootstrap case reports zero format callbacks and
must not be described as three negotiated Links.

The separate `/tmp/rtc-wp-realization-multi3-20261007-before` and `-after`
fixture uses three distinct output/input port pairs. The original library times
out awaiting Prepared acceptance; the corrected library passes 25/25. Its
receipt records three exact manager-owned Links, their passive policies,
1160-byte intent, six native format callbacks and zero remaining links after
withdrawal. The patched ordinary mechanism suite is separately recorded under
`/tmp/rtc-wp-realization-links-20261007-patched2`.

WPR-09 now has an integrated Rust negative receipt in
`/tmp/rtc-wp-realization-rust-marker-loss-20261007-attempt3`: the Rust test
passes 1/1 and its enclosing fixture passes 13/13. Source and log establish
actual marker removal before the test-delayed activation callback, bounded
withdrawal failure, retained session with acknowledgement eligibility false,
and rejection of the next realization while the exact manager remains present.
After the callback drains and links disappear, cleanup still remains unknown;
revoking the exact manager Client permits the separate creator-lifetime fence.
The attempt-3 receipt records that the manager process remains running but
its exact Client is absent, with zero links. The later archived repeat at
`/tmp/rtc-wp-realization-rust-marker-loss-20261007-final` also passes the Rust
test 1/1 and enclosing fixture 13/13. Its trace records pending Link observation,
unknown retained cleanup, fenced next realization and eventual exact manager
revocation cleanup. In this repeat the manager process has exited by the final
post-test snapshot; process liveness at that later snapshot is not the fence
criterion. Both cases establish that the exact Client is absent and no links
remain. This closes the integrated negative case;
it does not remove WPR-09's explicit trusted-core assumption about arbitrary
external marker destruction after Withdraw publication.

### Selected FGN and JFG clean deployment

Inspected receipts:

- `/tmp/rtc-wp-realization-fgn-evidence-20261007-retry4/receipt.json`.
- `/tmp/rtc-wp-realization-jfg-evidence-20261007-attempt1/receipt.json`.

Both record success, exit code zero and final stopped state. The coordinator
`deployment/qualify_wireplumber_realization.jl` verifies the exact declared
endpoints, passive policy, actual negotiated formats and creator process before
acquisition; both receipts contain three Links and RTC reports `owned_links=0`.
Native Stop and Reset establish Ready with source paused at sequence zero;
Start/Stop/Reset then drive two completed 512-command acquisitions per engine.
For each acquisition the retained 256 Frame and Command prefix bytes match the
supplied accepted baseline for that engine. This is a within-engine replay
claim; no cross-engine bit equality is asserted.

Each measured simulator tail contains 256 exchanges and reports zero allocated
bytes, zero allocation counts and zero GC pauses. The counter scope is the
entire simulator process after its retained prefix, including controls and
interim reports, excluding final serialization. It is not an allocation claim
for every process. Both receipts record complete cleanup of all captured,
previously verified detached owner groups and removal of the private runtime.
These are bounded Copper CPU FGN/JFG with CUDA AOS software deployment results,
not hardware validation or a new throughput/latency qualification. In
particular the source-interval counters include samples exceeding the 10 ms
comparison period; zero allocations must not be presented as zero jitter.

### Development-only same-runtime retry coordinator

Reviewed `deployment/qualify_wireplumber_retry.jl` SHA-256
`c545f094eb7c1ffa77a3d83f7ba5636f2b9fe8f7a3e200e32ecdefb8381a9e71`
and `scripts/run_realization_probe.py` SHA-256
`9fe11394e4dbf7c4c857111a7ee88ca08844b8c6e3e931e94fac26a99813d8c3`.
The coordinator copies a sealed package into its fresh evidence directory,
replaces only the RTC entry point with an explicit development wrapper and
updates that artifact hash. The wrapper executes the exact ignored Rust test
in the same PID. One Runner and adapter perform two Load-to-Ready and
Unload-to-Offline cycles, check actual cohorts, retain one runtime Client,
require increasing generations and distinct marker incarnations, and verify
zero correlated links after each withdrawal. No source acquisition or native
runner endpoint is provided by this fixture.

The process collector enumerates direct children of its owned launcher,
records parent/session/group/start-tick identities before exit, rejects role
replacement and requires every configured placement role before accepting
complete cleanup. Its fallback signals only its still-owned launcher process.
Source review found no significant ownership defect in this bounded collector.

The FGN receipt now passes at
`/tmp/rtc-wp-realization-fgn-retry-evidence-20261007-attempt1/receipt.json`.
The independently inspected transcript records generations 1 and 2 using the
same runtime Client `29:30`, distinct marker incarnations `48:49` and `48:72`,
three admitted Links each, and zero correlated links after both withdrawals.
The Rust test passes 1/1. All four captured owner groups are confirmed complete;
the source remains paused at sequence zero and the outer deployment is failed
and not admitted. The specific error is `required rtc exited with status 0`,
within native controller discovery. Thus the fixture's successful test process
exit is correctly rejected as an admitted outer native runner deployment.

This receipt records the original coordinator hash above. After launch, the
coordinator was strengthened to require that exact final error substring;
reviewed updated SHA-256 is
`17b379d211558b08b1ae42cbbba0a2b213ac0136090bb1f6ffaeab3d7459782b`.
The existing FGN receipt independently satisfies the new condition; it is not
represented as an execution of the revised coordinator. JFG subsequently passes
with the revised coordinator at
`/tmp/rtc-wp-realization-jfg-retry-evidence-20261007-attempt1/receipt.json`.
Its transcript records generations 1 and 2 on unchanged runtime Client `48:49`,
markers `51:52` and `51:59`, three Links admitted and zero correlated links
after each withdrawal. Rust passes 1/1, all five captured owner groups are
confirmed complete, the source remains paused at sequence zero, and the failed
nonadmitted outer deployment reports the same expected successful test-process
exit diagnostic. This closes the held adapter retry gate for both engines.

These observations prove adapter unload/retry with held scientific owners.
They do not prove native caller endpoint reload/retry or a scientific acquisition
across realization generations. The development wrapper deliberately supplies
no native runner endpoint and sends no source acquisition commands.

### Dependency suite and retained limits

The baseline and patched WP full-suite logs under
`/tmp/wp-pod-filter-{baseline-full-ao-environment,full-ao-environment}-20261007.log`
both report 45/57 passing and exactly the same 12 failing test names with
`AO_RUNTIME_DIR=/tmp`. The default-environment run reports 10/57 passing and
47 failures; it cannot be reported as a successful full suite. Matching baseline
failure names support absence of a newly observed full-suite regression; they
do not prove those failures are harmless or fully diagnose their causes.

WPR-14 remains the accepted dependency allocation-failure limitation. No
fault-injection result, graceful-OOM behavior, arbitrary publisher security or
systemd supervision qualification is claimed. Selected manager/runtime/core and
required-Link loss cases must be accepted against their own final receipts.


## Final production source pass

The final read-only source pass examined the changed production integration in
`src/live.rs`, `src/main.rs`, all four `src/live/` modules,
`deployment/julia/src/deploy.jl`, `deployment/julia/src/session_manager.jl`
and `deployment/wireplumber/realization.lua`, plus the package preparation and
qualification helpers. No new significant unresolved defect was identified in
that pass under the documented trusted private-core allocation.

The review rechecked explicit opt-in with exact manager Client ID/serial,
default direct link ownership, latest/hold exclusion, node/client provenance
before projection and admission, retained removal watches for overlapping
identities, actual LinkInfo endpoint/passive/lifetime/Format validation,
monotonic intent phases, callback drainage and the manager sync before marker
acknowledgement. Unknown withdrawal retains local session resources and fences
the next realization. Manager startup occurs while scientific ingress remains
held; the existing owned-process machinery monitors and cleans the new role.
No new scientific scheduler, native caller command endpoint or JSON live
control path is introduced by these changes.

Final inspected production SHA-256 values:

| File | SHA-256 |
| --- | --- |
| `src/live.rs` | `d479cebdac8eb41bbbfcf58ea8b479dc38b09d3f183105ccf6ace44c32676954` |
| `src/main.rs` | `95bcca94c6e930ca67466e42074c1612652b53c589bc8b0d10515d49a3cbec1c` |
| `src/live/wireplumber.rs` | `35b965c8ae5485147e136071c15300942b06e9ed64373a51dc8e590a327dbe2b` |
| `src/live/realization.rs` | `ac6f5263c130a83d0372266f90225dc4e1c49008465315787fb439cc29f84940` |
| `src/live/realization_marker.rs` | `01f0907194cf6cac8a416e02b92b8adc0de1c197dd466603589a1137ee29cf1a` |
| `src/live/link_format.rs` | `8d7f3f8e1e0503b623161ebb72973a79ab133e6872cde779b86f340dc8753fec` |
| `deployment/julia/src/deploy.jl` | `6a03e444a451d7a88a65920af7a3aa58035336a92711d43fa8ced64ae70d3cbb` |
| `deployment/julia/src/session_manager.jl` | `54903d955a0292ddeb45687732c4804485af14b1e4ca6a20d4fd6c8f25ce55e4` |
| `deployment/wireplumber/realization.lua` | `1b03ef4fb26dbd9f90d69e90502ad6ae12bddddd5a1c82419387b06507fa0ed8` |

This is source acceptance for the bounded integration, with the clean deployment
and held adapter retry evidence stated above. It does not replace final deployed
loss receipts. WPR-14, the trusted acknowledgement authority assumption,
allocation measurement scope, and the exclusion of native caller reload,
latest/hold, systemd supervision and broad timing/hardware claims remain in
force. The reviewer did not rerun compilation or runtime tests.


## Deployed required-Link loss — FGN

Independently inspected
`/tmp/rtc-wp-realization-fgn-required-link-evidence-20261007-attempt1/receipt.json`
and `deployment.log`. The receipt passes its narrow fault/cleanup gate:

- Before injection RTC is Running and admitted; the source is running,
  incomplete, at sequence 22. The coordinator rechecks the selected Link
  incarnation before its explicit native destruction.
- The removed Link is `51:52`, correlated to marker `50:51` at declaration index
  2. The policy trace records `link-removed` withdrawal for that exact marker,
  followed by its manager-side withdrawal completion.
- Rust then reports bounded withdrawal uncertainty because the marker was
  already removed before its own Withdraw acknowledgement became eligible.
  This is the intended WPR-09 conservative outcome, not a successful runner
  Unload acknowledgement.
- The supervisor exits with code 1, retains failed/not-admitted state, and all
  four previously captured owner groups are observed complete. The launcher
  exits 11.512 seconds into the coordinator's post-injection wait, inside its
  60-second check. This is a measured case, not a universal revocation deadline.

The final source field remains the earlier running sequence-22 status snapshot.
It is not a fresh source acknowledgement. Separately, the simulator log reports
that command sequence 27 times out and a failed report is written at sequence
26. Final cleanup diagnostics retain the removed source proxy and unknown source
control outcome. These facts support failure latching and subsequent complete
owned-cohort cleanup. They do not establish successful runner Unload, an
acknowledged source pause, fresh source revocation latency, or same-runtime
recovery after this failure.

The coordinator's generic failed-state/nonzero-exit assertions are necessary but
would not alone distinguish the intended loss from an unrelated post-injection
failure. For this receipt, the exact identity/injection witness and matching
policy and Rust traces establish that distinction. Apply the same evidence
standard to the remaining engine/loss receipts; do not infer their outcomes
from this one passing case. No production change is proposed from this result.


## Deployed loss matrix — FGN completed

The reviewer independently inspected all four FGN receipts and deployment logs
under `/tmp/rtc-wp-realization-fgn-CASE-evidence-20261007-attempt1`, with CASE
as listed below. Each records success for the qualification gate, launcher exit
code 1, final failed/not-admitted state, all four captured owner groups complete
and the private runtime removed. All use coordinator SHA-256
`ec0707ac6422984aea68c9ff40419558027b126063adf2d361a498d0fa883a74`.

| Injected loss | Fresh running, incomplete source sequence | Post-injection launcher wait | Causal observations |
| --- | --- | --- | --- |
| Required Link | 22 | 11.512 s | Exact Link `51:52`, marker `50:51`; matching policy Link removal and withdrawal; Rust retains unknown withdrawal. |
| Manager | 21 | 14.682 s | Captured WirePlumber PID/start-ticks match target; required manager exit latched; Rust reports required Link disappeared/replaced. |
| RTC runtime | 17 | 8.905 s | Captured RTC PID/start-ticks match target; required RTC exit latched; policy withdraws marker `51:52` and completes its own drain. |
| Private core | 18 | 15.568 s | Captured core PID/start-ticks match target; required core exit latched; Rust reports synchronization deadline before withdrawal submission. |

The three process injections use the inspected `scripts/signal_test_owner.py`:
it first opens a pidfd, verifies the selected parent PID and start ticks, then
sends SIGKILL through that pidfd. The coordinator confirms the target against
its previously owned direct-child identity and requires the helper to succeed.
This protects against signalling a later reuse of the numeric PID. Some final
supervisor errors say `exited with status 0`; in these cases that field must not
be interpreted as graceful owner shutdown, because the injection is explicitly
SIGKILL. Required process disappearance is latched regardless of that exit-code
field.

All waits are inside the existing 60-second launcher check. These are observed
post-injection case durations, not hard source-revocation or real-time bounds.
The manager/runtime/core source fields retain pre-injection running snapshots
at sequences 21/17/18. Their simulator logs separately record failed reports at
sequences 29/25/26. Cleanup diagnostics preserve the missing required process
or removed source proxy and unknown source control outcome. Core loss prevents
a manager acknowledgement from being used; complete process/core teardown is
the reported outcome.

The exact witnesses and correlated logs establish causality for these four
receipts beyond the coordinator's generic final failed-state assertion. They
qualify loss detection, failure latching and eventual complete captured-owner
cleanup in the selected FGN deployment. They do not establish successful runner
Unload, an acknowledged source pause, fresh source revocation latency, clean
scientific completion after injection or same-runtime recovery. JFG loss and
subsequent explicit fresh-deployment recovery require their own receipts.


## Deployed loss matrix — JFG completed

Independently inspected all four receipts and logs under
`/tmp/rtc-wp-realization-jfg-CASE-evidence-20261007-attempt1` using the same
coordinator revision and acceptance limits as the FGN matrix. Every case records
qualification success, launcher exit code 1, final failed/not-admitted state,
complete cleanup of all five captured groups (Julia graph, core, manager,
simulator and RTC), and absence of the private runtime.

| Injected loss | Fresh running, incomplete source sequence | Post-injection launcher wait | Causal observations |
| --- | --- | --- | --- |
| Required Link | 21 | 10.808 s | Exact Link `54:55`, marker `53:54`, index 2; policy logs Link removal and its withdrawal completion; retained-buffer/Julia graph failure follows. |
| Manager | 19 | 8.309 s | Exact captured manager PID/start-ticks targeted by pidfd SIGKILL; manager exit latched; Rust observes the required Link disappeared/replaced. |
| RTC runtime | 19 | 8.419 s | Exact captured RTC PID/start-ticks targeted by pidfd SIGKILL; RTC exit latched; policy withdraws marker `53:54` and completes its drain. |
| Private core | 21 | 15.678 s | Exact captured core PID/start-ticks targeted by pidfd SIGKILL; core exit latched; Rust cannot submit a synchronized withdrawal. |

For required-Link and runtime loss the logs explicitly report a retained
ndarray buffer being removed before processing completed, followed by
`pw_ndarray_filter_run` failing with Broken pipe. Required-Link loss is latched
as the required Julia owner exiting with status 1; the runner also reports a
withdrawal connection error. Runtime loss retains the RTC exit as the primary
failure and a Julia-owner failure during cleanup. These are observed failure
propagation paths. They do not indicate a successful scientific drain or runner
Unload, and no source/algorithm change is justified by these fault injections.

The final source snapshots remain the earlier running status. Separate simulator
logs record failed reports at sequences 25, 27, 27 and 30 respectively. Manager
and core cleanup retain the missing-owner/unknown-control diagnostics. As in
FGN, an `exit status 0` field for a SIGKILL-injected owner is not evidence of
graceful exit. All measured waits fall within the 60-second launcher check;
none measures or establishes a real-time source revocation bound or pause ACK.

Together, these independently reviewed receipts close the eight selected
deployed loss cases for failure latching and complete captured-owner cleanup.
Explicit fresh clean deployments after the entire loss series remain a separate
recovery check. No native caller reload or same-runtime acquisition recovery is
inferred from process teardown followed by a fresh deployment.


## Fresh deployment after the loss series — FGN

Independently inspected
`/tmp/rtc-wp-realization-fgn-readmission-evidence-20261007-attempt1/receipt.json`
and its deployment log. This new deployment passes after the eight selected
loss cases: three declared manager-owned Links, RTC `owned_links=0`, native
Stop/Reset establishing Ready with source paused at sequence zero, two completed
512-frame/512-command acquisitions, and both retained 256 Frame/Command prefixes
matching the accepted FGN baseline. Each 256-exchange measured simulator tail
reports zero allocation counts/bytes and zero GC pauses under the existing
inclusive simulator scope.

The policy records requested withdrawal and completion. The launcher exits zero,
final state is stopped/not admitted, all four captured groups are complete and
the private runtime is absent. The receipt uses the same reviewed coordinator
and policy revisions. This establishes explicit fresh FGN deployment success
following the loss series, not in-place repair or native caller reload of a
faulted runner. The subsequently inspected fresh JFG deployment is recorded below. Existing
timing, allocation scope and dependency limits remain unchanged.


## Final acceptance — selected opt-in realization

**Accepted for the bounded selected integration.** No significant unresolved
production defect was found within that scope after the final source and receipt
review. Earlier pending statuses in this chronological review are closed only
by the specific subsequent evidence described here; the retained limitations
are not promoted to passing claims.

The final JFG receipt and log at
`/tmp/rtc-wp-realization-jfg-readmission-evidence-20261007-attempt1` independently
confirm fresh deployment after the eight loss cases: three declared
manager-owned Links, RTC `owned_links=0`, held Ready/source paused at sequence
zero after native Stop/Reset, two completed 512-frame/512-command acquisitions,
matching retained 256 Frame/Command prefixes against the accepted JFG baseline,
and zero reported allocation counts/bytes and GC pauses for both 256-exchange
inclusive simulator tails. Requested manager withdrawal completes, the launcher
exits zero, final state is stopped/not admitted, all five captured owner groups
are complete and the private runtime is absent. The reviewed coordinator and
Lua policy revisions are unchanged.

The completed evidence set establishes:

- Explicit opt-in link realization on the selected trusted private core, using
  Copper complete-frame CPU FGN and CPU JFG with CUDA AOS. WirePlumber owns the
  external declared Links; RTC owns admission, scientific readiness,
  hold/release and reset. Actual endpoint, owner, passive and negotiated Format
  checks precede admission. The default direct RTC link path remains selected
  when no manager is configured.
- One initial clean deployment and one explicit fresh clean deployment per
  engine, each with two 512-command acquisitions. All eight retained acquisition
  prefixes match their own accepted engine baseline. Each run's measured
  simulator tail reports zero heap allocation and GC under its documented
  inclusive process scope; this is not a whole-deployment allocation claim.
- Two held adapter Load/Unload generations within one Rust runtime per engine,
  with distinct markers, unchanged runtime Client and confirmed withdrawal
  before the next generation. The integrated unexpected-marker-loss test also
  retains unknown cleanup and fences retry until its alternate exact-manager
  lifetime fence is established.
- Eight deployed required-Link/manager/runtime/core loss cases, four per engine,
  with exact injection witnesses, corresponding fault traces, failure latching
  and complete captured-owner cleanup within each observed launcher check.
  These cases retain unknown source/withdrawal outcomes where present; they do
  not assert successful runner Unload or a fresh source pause acknowledgement.
- Explicit fresh deployment succeeds for each engine after the full loss
  series. This is operator-selected new deployment, not automatic stale repair.

The public WP POD capacity correction has C and unchanged-fixture native
fail-before/pass-after evidence. WPR-14 remains an accepted dependency
allocation-failure limitation; graceful OOM handling has not been established.
The bounded private-core authority assumption remains necessary because marker
removal cannot identify an arbitrary external actor after Withdraw publication.

**Not qualified by this work:** native caller endpoint reload/retry, additional
profiles or latest/hold realization, systemd supervision, arbitrary or hostile
publishers, allocation-failure resilience, target cadence, worst-case latency,
or physical hardware behavior. The matched 12 baseline/patched WP full-suite
failures remain disclosed, rather than described as a wholly passing upstream
suite. No algorithm, gain, scientific artifact or scientific API correction is
part of this acceptance.

Only this review document was changed by the independent reviewer. Source
identities, reviewed receipts, measured scopes and unresolved limitations are
recorded above for the primary agent's final integration and delivery decision.
