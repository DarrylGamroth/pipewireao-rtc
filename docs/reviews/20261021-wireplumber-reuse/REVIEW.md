# WirePlumber reuse review — 2026-10-21

Disposition: independent review and focused post-change software verification
of both the hook migration and existing SessionItem extension complete. The
extension replaces AO's raw child-Link creation/retirement mechanism while
retaining its admission and cohort-absence policy. One native reconfiguration
defect found during final review was corrected with fail-before/pass-after
evidence; no blocking finding remains in the reviewed source. Installed-session
evidence remains separately scoped. This report does not authorize relaxing
RTC-ARCH-025 or claim timing or hardware qualification. Earlier sections preserve
the successive design/review stages; the final verification section records the
final implementation disposition.

## Scope and evidence

| Repository | Worktree and branch | Reviewed revision | Initial state |
| --- | --- | --- | --- |
| WirePlumberAO (WP below) | `/home/dgamroth/workspaces/codex/worktrees/wireplumber-reuse-20261021`, `codex/wireplumber-reuse` | `0f64f9ef9d7f080a2668470f3904aa3d0ebf92af` | Clean |
| PipeWireAORTC (RTC below) | `/home/dgamroth/workspaces/codex/worktrees/rtc-wireplumber-reuse-20261021`, `codex/wireplumber-reuse` | `c1b7895b4032624a1024aafb1e858f029fce391b` | Clean |

Read both repository instruction files, the RTC task index and
[RTC-ARCH-025](../../WIREPLUMBER_SESSION_DESIGN.md). Reviewed AO session,
connections, owner, acquisition, ingress and POD helpers; stock event dispatcher,
transition, Lua event bindings, standard event source, `si-node` and
`si-standard-link`; the native endpoint transport; and RTC configuration,
one-shot launcher/runtime and simulator replacement boundaries. Line references
below are to the recorded revisions. No production source was changed and no
live session was started or stopped. This is source-level evidence; runtime,
timing, allocation and hardware behavior were not measured.

The principal reuse opportunity is upstream asynchronous event transitions for
session sequencing. The exact NDArray connection cohort, protocol validation,
owner identity and bounded native transport implement requirements that the
reviewed stock components do not supply. Replacing these merely to increase
SessionItem usage would add adaptation machinery and weaken the current contract
unless the missing capabilities are first implemented and demonstrated.

## Findings

### WPR-001 — Replace generic session sequencing with upstream transitions

- **Class / severity / confidence:** confirmed maintenance opportunity, P2, high.
- **Observed evidence:** WP `src/scripts/ao/session.lua:28–116` implements
  cancellation bookkeeping, guarded callbacks, operation creation/completion and
  a recursive `sequence`; `:120–154`, `:472–601` and `:631–786` compose these
  into lifecycle/startup sequences. WP `src/scripts/linking/link-target.lua:14–160`
  demonstrates the supported `AsyncEventHook` API. WP
  `modules/module-lua-scripting/api/api.c:3119–3208` maps named steps and an
  error step onto `WpTransition`, and converts thrown Lua step errors to terminal
  transition errors. `lib/wp/transition.c:422–519` owns step advancement and
  terminal completion.
- **Derived cost:** callback nesting and a separate generic sequence dispatcher
  obscure the prescribed ordering and require AO-specific maintenance of a
  facility already present upstream. This is not evidence that current ordering
  is wrong.
- **Smallest coherent action:** express session operation phases as named
  `AsyncEventHook` steps, pushed through `EventDispatcher`; remove the generic
  recursive sequencing implementation once its callers use the hook. Preserve
  the single admitted operation, epoch/session identity, ticket validation,
  absolute deadline, effect-issued classification and cancellation handles.
  These are domain policy, not redundant transition state. Keep bounded
  iteration over graph/owner declarations where that communicates the data
  dependency clearly. Avoid a second generic workflow language around hooks.
- **Required validation:** actual upstream Lua hook execution, synchronous and
  delayed completions, thrown step/callback errors, source hold before consumers,
  downstream-before-upstream start, held reset, partial-start fault cleanup,
  terminal completion exactly once, cancellation and late completion fencing.
- **Disposition:** recommended implementation, subject to WPR-002; not a claim
  that every protocol helper should become a hook.

### WPR-002 — Hook cancellation is not effect retirement or asynchronous cleanup

- **Class / severity / confidence:** confirmed migration constraint, P1 if
  violated, high; no existing AO defect asserted.
- **Observed evidence:** WP `lib/wp/event-dispatcher.c:230–304,400–435` sorts events
  by priority and sequence. A suspended asynchronous hook blocks later events at
  equal or lower priority; a newly queued higher-priority event may run first.
  `lib/wp/event.c:241–246` only cancels a `GCancellable` when processing is
  stopped. `lib/wp/transition.c:422–443` checks cancellation on advancement, while
  `:496–519` marks the transition completed before invoking its error step.
  `modules/module-lua-scripting/api/api.c:2629–2670` converts Lua table event data
  to `WpProperties`, not an arbitrary retained Lua operation object.
- **Derived cost:** replacing the current fences with event cancellation can
  leave a never-completing hook parked forever or allow stale effects to act.
  Starting asynchronous rollback inside the error step cannot make that
  completed transition await rollback. Priority alone is not single-operation
  admission. Serializing callbacks/proxies into event table data loses their
  ownership and type semantics.
- **Smallest coherent action:** keep one bounded Lua operation owner, retain its
  epoch/identity gates, and pass only a scalar correlation key through events.
  On deadline/supersession explicitly terminate any parked transition and cancel
  or fence its effects. Run cleanup as its own explicit bounded operation or
  retained callback chain; do not publish cleanup success from the hook's
  terminal error callback. Check transition completion before late advancement.
  Keep fault observation able to interrupt a suspended ordinary operation.
- **Required validation:** deadline with no external callback, callback arriving
  after deadline, callback arriving synchronously during cancellation, required
  loss during each suspended phase, no second normal effect admitted, and no
  queued event retained indefinitely after cancellation.
- **Disposition:** required design constraints for WPR-001.

### WPR-003 — Stock selection and retirement need extensions for the full AO contract

- **Class / severity / confidence:** confirmed contract gaps, P1 if substituted
  without adaptation, high; custom ownership retained for the hook migration.
- **Observed evidence:** WP `modules/module-si-node.c:172–219` accepts only
  `input`/`output` contexts, enumerates all directional ports and represents
  them as node/port/audio-channel triples. It does not select `port.name`.
  `modules/module-si-standard-link.c:243–377` scores audio channels, allows
  unpaired outputs and creates Link properties containing only the two node and
  port IDs. It does not propagate AO `link.passive` or cohort `object.path`.
  `:128–131` returns no associated proxy. `:145–185` deactivates Links and resets
  counters, with no manager-Core synchronization or correlated absence proof.
  Link activation success and `link-error` do not validate the two declared
  NDArray contracts.
- **Existing non-audio precedent:** `src/scripts/node/create-item.lua:65–92`
  explicitly covers video nodes and selects `si-node` for non-audio content.
  `lib/wp/si-interfaces.c:155–165` documents channel zero for non-audio ports and
  order-based pairing when channel information is unavailable. Equal zero
  channels receive a positive score in standard-link. Thus a single output and
  single input without audio-channel metadata can already be paired. NDArray's
  media type alone is not an incompatibility. Exact topology is an application
  requirement: ordinary PipeWire Links also use explicit node/port IDs, and AO
  resolves its declaration's names to those IDs before linking.
- **Observed AO requirements:** WP `src/scripts/lib/ao-connections.lua:200–240`
  resolves exact names, directions and owner incarnations; `:319–393` checks
  negotiated NDArray types, shape, schema, layout and rate; `:459–560` records
  pending activations, exact endpoints, provenance, passive setting and
  correlated identities; `:562–600` waits for pending completion retirement,
  deactivates, synchronizes the manager Core and proves correlated absence.
- **Derived cost:** stock node-wide audio pairing can silently select a different
  scientific port and omit a required passive boundary. A wrapper that recreates
  every existing identity, format and teardown check while also maintaining
  SessionItems increases owners rather than removing machinery.
- **Smallest coherent action:** retain the exact AO Link cohort. Do not introduce
  synthetic audio-channel identities. A future bounded experiment could add an
  explicit named-port selection/property propagation/Link-observation seam to
  upstream SessionItems, then prove the teardown contract. That experiment is
  justified only if it removes a substantial owner rather than wrapping it.
- **Required validation before future replacement:** multiple NDArray ports in
  differing registry orders, exact link count and named mapping, passive boundary,
  mismatched Format refusal, required endpoint/Link loss, activation completing
  after withdrawal begins, and no success until retirement plus Core sync plus
  exact absence. Both full-frame and row-block profiles need scoped evidence.
- **Disposition:** retained for the current hook migration; existing-interface
  extension follow-up recommended below. Reject only an unadapted replacement
  that loses the identified guarantees, not non-audio SessionItem reuse.
  Preserve current lifecycle and validation until the replacement passes its gates.

### WPR-004 — Reuse the event dispatcher without stock all-feature discovery

- **Class / severity / confidence:** confirmed preservation constraint, P2,
  high; current selective managers justified.
- **Observed evidence:** WP `modules/module-standard-event-source.c:415–427`
  requests `WP_OBJECT_FEATURES_ALL` for all of its managed types. Its callbacks
  emit parameter-change events (`:330–338,356–371`). AO connections explicitly
  request only `Feature.Proxy.BOUND | Feature.PipewireObject.INFO`
  (`src/scripts/lib/ao-connections.lua:8,98`). The RTC generated configuration
  loads the Lua script and narrow endpoint/journal components without the stock
  policy stack (`src/configuration/wireplumber_configuration.jl:173–232`).
- **Derived cost:** adding stock event-source solely to obtain hooks broadens
  object activation and parameter observation contrary to RTC-ARCH-025's
  selective-feature requirement. Its audio rescans/default policy add no
  declared NDArray admission benefit.
- **Smallest coherent action:** keep selective ObjectManagers and push AO events
  directly into the built-in dispatcher. A shared configurable event source is
  a possible later upstream enhancement, not a prerequisite for WPR-001.
- **Required validation:** generated profile does not enable the stock audio
  policy; unrelated scientific Node Props remain unsubscribed; exact required
  object loss is observed during startup and steady state; optional observer
  arrival/removal does not gate admission or lifecycle.
- **Disposition:** preserve selective discovery; reject wholesale stock profile
  loading as a shortcut to hook reuse.

### WPR-005 — Lua event construction drops supplied event properties

- **Class / severity / confidence:** confirmed source defect, P2, high.
- **Observed evidence:** WP `modules/module-lua-scripting/api/api.c:2721–2728`
  pushes the literal `properties` but never looks up that key in the input table.
  The top stack value remains the literal string, so neither table nor boxed
  property conversion runs and `wp_event_new` receives a null property argument.
  `tests/wplua/scripts/event-hooks.lua:104` exercises only type and priority.
- **Derived impact:** AO hooks that filter on supplied correlation/operation
  properties can be silently omitted; handlers that read them see no supplied
  value. Existing AO code does not yet rely on this constructor.
- **Smallest coherent action:** add the missing input-table lookup and extend
  the existing event-hook test to verify custom property matching and retrieval.
  This is a narrow binding correction, not grounds for a new event bus.
- **Required validation:** fail-before/pass-after test with a custom event
  property and an interest requiring it; preserve existing no-properties event
  construction. Boxed properties should work if their public input form is
  exercised by the chosen implementation.
- **Disposition:** recommended fix before using event properties. No runtime
  reproduction was executed during this read-only review; the stack behavior is
  established by the source and should receive the focused regression above.

### WPR-006 — Active documentation retains the retired coordinator allocation

- **Class / severity / confidence:** confirmed documentation defect, P2, high.
- **Observed evidence:** RTC `docs/ECOSYSTEM_INTEGRATION.md:29–33,76–101,152–158`
  describes WirePlumber as discovery/link policy under a separate headless
  lifecycle runtime; `:353–356` calls the Julia supervisor/Rust runner current
  owners. `docs/architecture.md:418–430,474–480` still states Rust/Statig lifecycle
  and companion-launcher admission allocation. RTC-ARCH-025 explicitly retires
  these coordinator roles. Some surrounding architecture text already identifies
  the earlier implementation as historical, but the cited operative paragraphs
  and integration diagram remain contradictory in isolation.
- **Derived cost:** maintainers can reasonably interpret reuse as another
  supervisor-to-WirePlumber protocol and reintroduce dual lifecycle authority.
- **Smallest coherent action:** update the active integration ownership table,
  diagram and current implementation prose; explicitly mark superseded
  architecture allocation while preserving requirement/decision IDs and dated
  evidence. Keep systemd process ownership and scientific owner responsibilities.
- **Required validation:** review active ownership language against RTC-ARCH-025,
  check links/anchors and requirement IDs, and render any changed Mermaid diagram
  according to repository instructions.
- **Disposition:** recommended bounded documentation correction.

## Explicitly retained boundaries

The following are not duplicate generic session machinery on the reviewed
evidence and should survive this refactor:

- `ao-control`'s bounded native POD/envelope and identity validation,
  `ao-owner`'s token matching and query-until-deadline completion observation,
  and `ao-session-control`'s request admission, replay rejection and journal
  boundary. Stock EventDispatcher has no AO native protocol or unknown-outcome
  semantics. A submitted mutation must never be retried merely because a hook
  is restarted.
- `ao-acquisition`'s source-local protocol adapters and cursor/run/reset checks.
  Stock `WpSiAcquisition` is a link-resource acquisition interface; its name does
  not establish equivalence to scientific acquisition or the AOS exchange
  cursor. Keep scientific meanings with their owners.
- The narrow native control endpoint (`modules/module-ao-control-endpoint.c:30–58`)
  publishes typed Props and defers incoming callbacks to the core context with
  bounded handoff. EventDispatcher does not publish a remote native control node
  and offers no substitute for the transport receipt timestamp or queue bound.
- RTC `wireplumber_configuration.jl` binds verified process records into standard
  configuration; the one-shot launcher starts and reconciles systemd processes.
  `wireplumber_session_runtime.jl:443–524` observes native readiness and sends
  native controls. `simulator_configuration/jobs.jl:169–198` prepares a candidate,
  requests old-session shutdown, launches a new invocation, observes Ready and
  optionally requests Start. These are client/process transactions, not a second
  scientific lifecycle authority. Moving filesystem, installation or blocking
  systemd work into Lua would violate the current boundary.
- Scientific/data scheduling, FGN/JFG execution, calibration mathematics,
  process placement and optional observation remain outside this refactor.

## Integration acceptance

Accept a hook refactor only after the removed sequencing code is identified,
the retained policy fences remain explicit, and focused tests run against real
upstream transition/dispatcher behavior rather than only a Lua mock. Existing
connection withdrawal, owner and acquisition tests should remain applicable.
The public native protocol, generated profile's selective features and exact
scientific connection semantics must remain unchanged unless separately
adjudicated. Report local software evidence separately from installed-session,
timing and hardware qualification. Record final dispositions and verification
against the implemented revisions in this report or a linked dated receipt.

## Independent implementation verification

Reviewed the uncommitted implementation over the recorded baselines on
2026-10-21. The changes replace the session's normal startup, Start, Stop,
source-end Stop, Reset and Quit phase chains with native `AsyncEventHook` steps.
The generic recursive `sequence` helper is removed. Bounded iteration over the
declared graph/owner cohort remains inside the relevant phase. Single-owner
property/parameter operations retain their existing native callback contracts.
The review included the production diff, native Lua harness, event binding
regression, RTC fault-harness adaptation and corrected active documentation.

| Finding | Verified disposition |
| --- | --- |
| WPR-001 | Implemented. The named hooks run through the native dispatcher and `WpTransition`; they do not introduce a parallel workflow owner or protocol. |
| WPR-002 | Preserved and exercised. `retire` marks the Lua operation retired, stops event processing and explicitly errors any parked native transition before cancellation callbacks. Epoch/session/ticket/deadline guards remain. Each phase advances at most once. Fault compensation retains the previous ticket independently until withdrawal completes; a terminal hook error does not claim cleanup success. |
| WPR-003 | Retained for the current hook migration. Existing-interface extension is the follow-up target; raw-Link mechanism is not designated permanent AO policy. |
| WPR-004 | Preserved. No stock event-source or audio policy component is added. Existing selective ObjectManagers remain. Only the scalar operation epoch crosses the native event-properties boundary. |
| WPR-005 | Fixed. The missing table lookup is present. The native event test verifies table properties, boxed `WpProperties`, interest matching and omitted properties. The independent pass verifies success; fail-before reproduction was not rerun by this reviewer. |
| WPR-006 | Corrected in the reviewed active integration/architecture sections. RTC-ARCH-012 is explicitly historical and superseded by RTC-ARCH-025; the former Rust dispatcher/companion-admission language is replaced while preserving the decision identity. This is not a whole-repository historical-document audit. |

The exact reviewed WP file contents were:

| File | SHA-256 |
| --- | --- |
| `src/scripts/ao/session.lua` | `39215eaf2deff21f8e1ee6be170cc64c8eb9bd01ce5030c299a7b9852faad93c` |
| `tests/wplua/scripts/ao-session-hooks.lua` | `82278d739e4eb18d5e2c887dbac56bbb3e425838dd32e35cdf947b04c36b0a4a` |
| `modules/module-lua-scripting/api/api.c` | `fc9eb5330ce4937c225b34016524e05531cbc189f6662195a75152e566d4f83f` |
| `tests/wplua/scripts/event-hooks.lua` | `b5f07c92b3adefe7aca2f88fb6ca1a9f6515b7eafa6d1517ead70f89aa79f802` |

### Commands independently rerun

From the WP worktree, using the existing isolated build after the implementation
worker released it:

```sh
PIPEWIREAO_CONFIG_DIR=/usr/share/pipewire meson test -C build --no-rebuild \
  test-lua-ao-session-hooks test-lua-event-hooks test-lua-ao-connections \
  test-lua-ao-owner test-lua-ao-acquisition test-lua-ao-session-journal \
  --print-errorlogs
```

Result: **6 passed, 0 failed, 0 skipped, 0 timed out**. This pass ran the built
native event/transition implementation; it did not rebuild or install it.
`git diff --check` also passed in the WP worktree.

From the RTC worktree:

```sh
julia --startup-file=no --project=test test/integration/session_policy_faults.jl \
  /home/dgamroth/workspaces/codex/worktrees/wireplumber-reuse-20261021/src/scripts/ao/session.lua
```

Result: **7/7 production fault-ordering cases passed**, using `liblua5.4.so.0`;
the harness printed the session-policy hash above. Its new hook stubs only let
the existing compensation tests load the production script. They are not
evidence for native hook behavior; the separate native test supplies that.

### Demonstrated scope and remaining limits

The native session test runs the production Lua policy with real hooks and
transitions, while controlling owner/discovery I/O and the monotonic clock. It
checks synchronous and delayed completion, bootstrap and parameter capture,
downstream graph start before source release, source-first hold, reset cursor
adoption, source-end query refusal/success, owner shutdown, queued and suspended
deadline expiry, reentrant cancellation, repeated late callbacks, thrown native
steps and I/O failures. Required-loss injection covers ten startup I/O seams,
three Start seams and twelve Stop/Reset/Quit seams. Compensation is deliberately
parked to verify that the original public ticket remains pending until cleanup;
a same-priority sentinel proves the retired hook no longer blocks dispatch.

Observed passing tests and source inspection support the bounded sequencing
change. They do not establish real owner identity/transport races, actual Link
negotiation with every scientific profile, systemd cleanup under process loss,
installed full-composition behavior, deadline latency or hardware safety. The
unchanged owner/connections/acquisition tests retain their individual scopes.
No unresolved blocking finding was identified in this implementation review;
profile-specific integration and performance claims require their own receipts.

## Follow-up design: extend existing SessionItems for exact scientific links

The user's subsequent direction is to model new functionality on existing
implementations and extend existing interfaces for NDArray support instead of
creating parallel ones. The stock incompatibilities in WPR-003 are therefore
extension requirements, not a permanent argument for separate AO Link machinery.
This section preserves the bounded source-based recommendation before its
implementation. The final verification section below records the subsequently
implemented and tested extension.

### Existing extension points

Video is the existing non-audio model to follow: the stock create-item policy
uses `si-node` for video, and the linkable interface explicitly represents
non-audio ports with channel zero. A sole output/input pair already works without
synthetic channel data. A declared multi-port topology needs tighter selection
than the documented order-based fallback regardless of media kind. Row-block
scheduling does not itself justify a separate session mechanism: execution and
buffer/progress semantics stay in PipeWireAO/FGN/JFG unless an observed interface
gap demonstrates otherwise.

`WpSiLinkable.get_ports(context)` already permits contextual port subsets
(`lib/wp/si-interfaces.c:155–200`). `si-node` is the existing generic wrapper
around a `WpNode`; its directional subset implementation is the appropriate
place to add selection of an already-resolved port ID. `si-standard-link` already owns child Links,
their activation and destruction, and receives both port contexts in its
configuration. `WpSessionItem.get_associated_proxy(type)` already exposes an
associated native proxy; returning the sole child `WpLink` in an explicit
one-pair mode fits that existing contract. It requires no new AO SessionItem
class or scientific graph representation.

The smallest coherent extension is:

1. **Exact directional selection in `si-node`.** Reuse AO's existing name-to-ID
   discovery and extend the existing port-context convention to select that
   resolved port ID within the requested direction and wrapped node. Keep
   `input` and `output` behavior unchanged. The context spelling should follow
   upstream conventions; it is not specified here as a new addressing language.
   Missing IDs or IDs belonging to another node/direction must fail rather than
   choose a registry-order winner. This needs a local `si-node` configuration/
   context extension, not a new `WpSiLinkable` C method or a second named-port
   framework. Return the existing node/port tuple representation. Reuse one
   `si-node` per captured node, not one synthetic node item per port. Preserve
   name ambiguity, serial and owner/incarnation checks in AO admission policy.
2. **Explicit exact-pair mode in `si-standard-link`.** Add opt-in configuration
   that requires exactly one output and one input from the selected contexts
   and pairs only their IDs, allowing no fallback or partial matching. Reuse the
   existing non-audio singleton behavior and shared child creation path; this
   needs a cardinality/selection contract, not another pairing algorithm.
   Existing audio behavior remains the default. Apply only the
   declared supported Link properties, including `link.passive`, `object.path`
   and `object.linger`, at child creation. Node/port identity comes from the
   validated selected pair and cannot be overridden by forwarded properties.
   AO continues to require non-lingering links and a unique correlated path.
   The implementation belongs in the existing factory and should reuse its
   common child-Link creation/activation helpers.
3. **Observe through existing proxy access.** In exact-pair mode,
   `get_associated_proxy(WP_TYPE_LINK)` returns the sole retained child. Lua can
   observe its actual IDs, properties, state and negotiated Format using the
   existing `WpLink` API. This removes the need for a second AO-owned creator.
   The association must be defined during activation and retain a stable
   generation; it must not accidentally return a later replacement child.
   General multi-Link iteration is unnecessary for the first bounded extension.
4. **Add explicit asynchronous retirement to the existing link interface.**
   `WpSiLink` needs a narrow withdrawal/drain operation with a finish result,
   implemented by `si-standard-link`. It must invalidate the generation before
   cancelling/aborting pending work, reject new activation/reconfiguration while
   retirement is unresolved, destroy every child including any late completion,
   and complete only when child activation callbacks have retired and child
   destruction has been issued. A conventional GIO-style async/finish pair plus
   its Lua binding is a suitable shape; the exact API name is not settled here.
   Cancellation or timeout must not report successful retirement or reopen the
   generation. Unsupported implementations must report unsupported rather than
   fall back to a success-returning synchronous reset.

The fourth item is essential. `wp_object_deactivate`
(`lib/wp/object.c:534–540`) masks requested features with already-active features;
it does not itself drain an activation whose requested feature is still pending.
`wp_object_abort_activation` (`:555–579`) errors transitions, but terminal
transition notification does not prove all underlying effects have retired.
The current standard-link reset/deactivation counter handling cannot simply be
relabelled as the required retirement proof. Extend its existing lifecycle using
generation-aware pending-operation ownership; do not copy the Lua cohort into a
new AO-only C class. The initial exact-pair path avoids adapter acquisition work,
but the generic retirement implementation must either safely handle existing
adapter callbacks too or explicitly limit support to the documented mode.

### Ownership after the extension

| Responsibility | Appropriate owner after migration |
| --- | --- |
| Declared endpoint names, exact process/object incarnations, topology and source-first/downstream ordering | AO policy |
| Resolved port-ID subset lookup on a wrapped node | Existing `si-node` through extended context selection |
| One exact child-Link creation, activation generation, pending callbacks and destruction | Existing `si-standard-link` through the extended `WpSiLink` lifecycle |
| Passive/path/non-lingering properties | Declared by AO policy, applied by standard-link |
| Negotiated NDArray element type, schema, shape, layout/rate and declared-contract validation | AO admission policy using the associated `WpLink` and existing POD interfaces |
| Absolute operation deadline, unknown outcome, cohort correlation, required loss, no retry/fresh admission | AO policy |
| Manager-Core synchronization and exact correlated registry absence after all items retire | AO cohort policy using existing Core/ObjectManager APIs |

The existing `ao-connections` cohort is therefore a **mixture**. Its name/identity,
NDArray contract, ordering and whole-cohort absence checks are appropriate
domain policy. Its raw Link factory calls, proxy activation ownership, pending
callback tracking and per-proxy destruction duplicate mechanisms that
`si-standard-link` should own once extended. Today that duplication closes real
contract gaps, so removing it before the extension would be incorrect. After
the extension, AO should retain SessionItems and correlated identity records,
request retirement once per item, wait for their explicit results, then perform
one manager-Core sync and registry absence proof. It must not keep a second raw
Link owner alongside SessionItems.

### Completion scope and follow-up gate

At this design stage, the completed slice was **upstream asynchronous hook
reuse** and its focused software verification. The next
coherent slice is the four existing-interface extensions above, native regression
tests, and replacement of the corresponding AO per-Link implementation in the
same reviewable change series. Preserve the current implementation until the
new path demonstrates equivalent admission and withdrawal behavior.

Start from `tests/modules/si-node.c`, `tests/modules/si-standard-link.c` and
`tests/wp/session-item.c`, extending their patterns rather than building another
test framework. Require multiple named NDArray ports in shuffled registry order,
missing/ambiguous selectors, exact one-pair cardinality, no channel metadata,
preserved audio behavior, passive/path propagation and property override refusal.
Add controlled races for withdrawal before child binding, between binding and
activation completion, after one failure, and during late callbacks. Verify that
retirement success precedes Core sync/absence proof and that timeout permits no
readmission. Run existing AO Format/provenance/loss/withdrawal tests against the
new sole owner and prove the old raw-Link creation/destruction path has been
removed. Installed full-frame and row-block checks remain separately scoped.

The exact selector spelling and async API signature are proposed seams, not
claims about features already available upstream. Their justification is
concrete: they transfer generic per-Link ownership into its existing owner while
preserving the AO checks that owner cannot infer. No parallel SessionItem
framework, new control protocol or scientific scheduler is warranted.

### Authorized extension: lifecycle review constraints

The user subsequently authorized implementing the existing-interface extension
and removing duplicate AO Link creation/destruction. The selected bounded design
uses `si-node` contexts `input:<resolved-global-ID>` and
`output:<resolved-global-ID>`, strict UInt32 parsing, `si-standard-link`
`link.exact=true`, allowlisted child properties and the existing associated-proxy
accessor. `WpSiLink.withdraw` with a conventional async/finish pair and Lua
`item:withdraw(callback)` supplies the retirement result. This paragraph records
the selected design, not implementation completion. Non-exact or adapter cases
may explicitly report unsupported; ordinary audio behavior must be preserved.

Inspection of existing lifecycle facilities found no smaller supported operation
that proves the required retirement. Deactivation masks to active feature bits;
activation abort completes transitions without draining lower-level work. A Core
sync is a server-ordering fence, not proof that a client-side pending creation
callback cannot later issue more work. The new operation therefore extends the
existing link owner at a real missing lifecycle boundary. Reuse the local GTask
patterns in `modules/module-si-audio-adapter.c:700–749` and
`lib/wp/core.c:1265–1338`; do not introduce another completion framework.

Final implementation review must specifically establish:

- Generation retirement happens before abort/cancellation or destruction calls
  that can synchronously invoke callbacks. Reconfiguration/activation remains
  forbidden after permanent retirement, including after timeout or cancellation.
- Child completion ownership survives parent activation failure/abort. The old
  `g_cclosure_new_object(on_link_activated, transition)` ties child callbacks to
  the parent's transition lifetime; it cannot alone carry a retirement pending
  count after that parent is completed. Exact-mode callbacks need independent
  retained owner/generation context through the final accounting step.
- Calling deactivate on an unbound child is not counted as destruction proof.
  A pending child must settle and be destroyed even if binding occurs after
  withdrawal starts. A callback that never settles must leave the cohort fenced
  and produce an unknown outcome at the AO deadline, never synthetic success.
- Pending counts are established before starting calls that can complete
  synchronously, decremented once, and not reset by unrelated cleanup. The final
  successful withdrawal callback occurs only after every relevant callback has
  retired and all child destruction requests have been issued.
- GTask cancellation can yield a cancellation error but cannot imply successful
  withdrawal or reopen the generation. Background retirement, if still pending,
  retains sufficient owner/child lifetime and never advances a new generation.
- AO consumes that result before Core sync and correlated registry absence.
  It keeps deadline, identity and scientific admission policy but no parallel
  child-Link creator/destructor or per-child completion owner.

Required controlled cases include withdrawal while activation is queued, after
native proxy creation but before bound delivery, after binding but before INFO
completion, after successful activation, after activation failure, and during
late/reentrant callbacks. The final verification below covers the implementation
that followed this design review.

## Final SessionItem implementation verification

Independently reviewed the final uncommitted WP and RTC changes over the baseline
revisions at the top of this report. The existing `si-node` and
`si-standard-link` factories implement the selected resolved-port contexts and
exact singleton mode. The standard-link factory uses its shared child creator,
forwards the supported properties, refuses endpoint overrides and lingering
exact Links, and exposes the retained exact child through the existing
associated-proxy method. Video/non-audio precedent is preserved; no
NDArray-specific SessionItem class, audio-channel surrogate or new control
protocol was added.

`wp_si_link_withdraw` / `wp_si_link_withdraw_finish` use the existing
`WpSiLink` interface, its reserved ABI padding and conventional GIO/GTask
async/finish naming, consistent with adjacent acquisition/adapter interfaces.
The Lua binding supplies `(item, error)` and documents the same retirement
contract. Unsupported default/audio/adapter paths fail explicitly rather than
claiming a synchronous reset proves retirement. Default audio creation continues
through the existing pairing path and its regression test passes.

The final retirement implementation fences the generation and aborts the parent
before cancellation. Child callbacks independently retain the owner; they do not
depend on the parent transition's remaining lifetime. Destruction runs through
the existing locked WpProxy disposal path on an owning-Core idle source, after
the creation/binding callback stack unwinds. The idle source remains a retirement
fence through its destroy notification. Successful completion requires no pending
child activation callbacks, no retained retirement source and no native child
proxy. A cancelled withdrawal result never permits reconfiguration/readmission.
An explicitly withdrawn item remains closed permanently.

AO `connections.realize` now owns the cohort declaration and admission evidence,
with cached `si-node` wrappers and one standard-link item per declared link. It
contains no raw Link factory call, per-child activation pending counter or raw
proxy deactivation. Its retained `cohort.proxies` are observation references.
Late node activation cannot create a link after cohort retirement. Resumed
activation/observation exceptions are returned to the bounded realization
completion rather than only logged by the Lua native callback boundary.
`connections.withdraw` awaits each item result once, then synchronizes the
manager Core and proves exact correlated registry absence. Failures and expired
deadlines leave the cohort fenced. Named discovery, serial/process identity,
endpoint provenance, topology, passive settings, negotiated NDArray Format and
required-loss checks remain AO policy.

RTC configuration explicitly requires the two existing SessionItem modules;
export/staging and installation validation include them. Those changes were
source-reviewed, along with their missing-module refusal tests. The coordinator
separately reports 75 passing configuration/staging assertions; this reviewer
did not rerun that Julia selection. No stock audio policy or all-feature event
source was added. The public native session protocol and scientific owner
boundaries remain unchanged.

### WPR-007 — Reconfiguring an exact item could free a generation with deferred work

- **Class / severity / confidence:** confirmed implementation defect, P1, high;
  corrected during this review.
- **Observed trigger:** a configured but unactivated exact item, or a successfully
  active exact item, passed the old configure precheck. Configuration then called
  reset, which scheduled deferred retirement, and immediately freed the generation.
  `generation_free` asserted because `retire_source` was still non-null.
- **Correction:** reject reconfiguration atomically while the old exact generation
  is not retired or still owns pending/source/task work. Ordinary replacement
  requires explicit reset/deactivation and settled retirement; explicit withdrawal
  remains permanent. Rejected configuration preserves the old child, configuration
  and feature ownership. The contract is documented in the existing SessionItem
  API documentation.
- **Evidence:** the implementation worker added the native
  `/modules/si-standard-link/reconfigure` regression before changing production
  code. Its retained fail-before log reports the `retire_source == NULL` assertion;
  the same case passes after correction. This reviewer inspected those result
  excerpts and independently reran the passing native suite containing that case.
  The regression covers configured/unactivated and active refusal plus successful
  configuration after explicit reset and retirement settlement.
- **Disposition:** closed; no known remaining blocking finding in the final source.

### Final independent commands and scope

From the WP worktree, after the worker confirmed the build was stable and free:

```sh
PIPEWIREAO_CONFIG_DIR=/usr/share/pipewire meson test -C build --no-rebuild \
  test-si-node test-si-standard-link test-si-audio-adapter test-session-item \
  test-lua-ao-session-hooks test-lua-event-hooks test-lua-ao-connections \
  test-lua-ao-owner test-lua-ao-acquisition test-lua-ao-session-journal \
  --print-errorlogs
```

Result: **10 passed, 0 failed, 0 skipped, 0 timed out**. The native si-node and
standard-link executables contain **15 passing internal cases** (2 + 13), with
no internal skips. The default audio adapter test and all six SessionItem base
cases also passed. `git diff --check` passed. Raw Meson logs contain inherited
environment details; this report intentionally records only scoped test results.

The native tests use CPU-only, inactive real NDArray filters with multiple
ports in differing declaration orders, no audio-channel metadata, and an exact
explicit port selection. They verify passive/path/non-lingering properties,
control-port selection, selector/refusal behavior, the associated proxy and
post-withdrawal Core-sync registry absence. Controlled native races cover queued
activation, unbound child, withdrawal inside `pw-proxy-created`, bound-before-INFO,
reset, deactivate, cancellation, child failure, attempted activation during
withdrawal and reconfiguration. They do not exercise streaming buffer negotiation
because the filters intentionally remain inactive.

The AO connection tests cover retained scientific Format/provenance/loss policy,
retirement failure, deadline expiry with late completion, late node wrapping and
resumed constructor exceptions. Native transition tests continue to cover the
previously verified hook ordering and cancellation. The earlier seven-case RTC
fault-compensation evidence remains applicable to the unchanged session-policy
hash; its mocked hook boundary must not be confused with the native tests.

### Final source identities

| WP file | SHA-256 |
| --- | --- |
| `modules/module-si-node.c` | `966c19547624dc3d9e946fa1cd9d55401797811e006cf3b6bde98f27261c8cfa` |
| `modules/module-si-standard-link.c` | `1756bb90fe9d33d155ad512a12aa413cf49de9cf9368f861aa1f95ad13f444b6` |
| `lib/wp/si-interfaces.c` | `b72bbb38c5589d8281923c69999266e0748d47f3e16cc808ab30cb58991c3f76` |
| `lib/wp/si-interfaces.h` | `14ddddd1e4ecd802f831e7dcec69794ac45a0ddfd4f30d0125eec9bbd028629f` |
| `modules/module-lua-scripting/api/api.c` | `f893bfc533db8067673331c7a57912044277632871ab65e325440f3d14b614f2` |
| `src/scripts/lib/ao-connections.lua` | `664c7e33b61439cd2164cfece04045f78871e2bdb397716f081677bf43f99abf` |
| `src/scripts/ao/session.lua` | `39215eaf2deff21f8e1ee6be170cc64c8eb9bd01ce5030c299a7b9852faad93c` |
| `tests/modules/si-standard-link.c` | `e5210eb641a25fad6e1db5a3034bb7ac5065587efd404ba47845485a57e58376` |
| `tests/wplua/scripts/ao-connections.lua` | `aff0863e5a22d5d8a53a067ed28e1157c44836d4dbed4acb1c7f21b1b2dd4e4c` |

The final disposition of WPR-003 is now **implemented existing-interface reuse**,
replacing the per-Link mechanism while preserving AO admission/absence policy.
WPR-001/002/004/005 remain satisfied at this source. WPR-006's historical
coordinator correction was already verified; documentation describing this newer
SessionItem implementation is being finalized by the coordinator with its
separate integration receipt.

No GPU was used for this verification, and earlier GPU results for the hook-only
candidate do not qualify the new SessionItem implementation. CPU integration
receipts, live scientific streaming, full-frame/row-block profile parity,
systemd/process-loss behavior, latency/allocation measurements and hardware
qualification remain distinct evidence. This review approves the inspected
software ownership/retirement change within the stated test scope, not universal
real-time or physical-loop behavior.

## Instrument terminology follow-up

The user selected REVOLT/HEART and GPI 2.0 terminology as the authority for
instrument-facing names. This is an initial read-only mapping, not a scientific
equivalence claim or permission to rename schemas. Reference roots are
`/home/dgamroth/workspaces/codex/heart/revolt-on-sky` and
`/home/dgamroth/workspaces/codex/heart/gpi2.0-rtc`.

| Quantity or role | Source term and evidence | Mapping disposition |
| --- | --- | --- |
| Configured mirror flat | REVOLT `config/SCAO_REVOLT_yaml.config:523–527`: `SYS_FLAT_FILE`, described as DM system flat; `CheatSheet:213–223` distinguishes system flat, zero and file shape | Use **System flat** when the quantity is that configured flat. Do not merge it with an additive offset. |
| Mirror offset file | REVOLT same config `:529–535`: `PDM_OFFSETS_FILE` / `dmOffsetFilePath`, commented in that example; `CheatSheet:113–117,213–216`: `offsets` and `UseOffsetFile` | **DM offsets** is sourced. Whether our additive parameter is equivalent to this HEART selection is unresolved; no rename or unit conversion was made. |
| Reference gradients | REVOLT same config `:333–338`: `NCPA_GRADS_FILE`, NCPA reference vector; `CheatSheet:152–158`: `APPLY_SLOPE_OFFSETS` modifies NCPA slopes | Preserve NCPA/reference/offset distinctions. These are not interchangeable with mirror offsets or camera background. Copper's analogous config stanza is commented. |
| Reconstructor and its matrix | REVOLT same config `:386–394`: HO Reconstructor, `USE_LOADED_CM`; `CheatSheet:113–115`: `controlM`; GPI `doc/gpi2HoRecon.dox:3–11`: High Order Reconstructor, pixels to modes | **HO Reconstructor** names the operation; **Control matrix** names its coefficients. Preserve basis, dimensions and sign conventions in any application mapping. |
| GPI mirror identities | `doc/gpi2Woofer.dox:3–9`, `doc/gpi2Tweeter.dox:3–9`, `doc/gpi2RtcDataFlow.dot:19–39`: PDM0 Woofer, PDM1 Tweeter, separate TTS | Use **Woofer** and **Tweeter** for those GPI mirrors. Do not infer those identities for REVOLT Classic or Copper merely from algorithm structure. |

Our adopted algorithm documents `requested-with-offset = requested + offset`
before the existing PDM limiter, Float32 actuator order, µm wavefront, zero
initial offset and separate system flat (`JuliaFilterGraph.jl/docs/pdm-engineering-offset.md`).
That establishes our current meaning; it does not establish HEART equivalence.
The existing `org.calculon.ao.pdm-engineering-offset/1` schema is a protected
boundary identifier for this audit. The instrument application should supply a
source-backed display name through existing metadata once its mapping is
verified, without a GUI-specific instrument handler or a second alias API.

No scientific identifier, schema, gain, offset or flat was changed in this
increment. Unresolved offset equivalence stops that naming change only; it
does not block the generic session hook refactor. No new naming framework or
terminology-checker allowlist was introduced.
