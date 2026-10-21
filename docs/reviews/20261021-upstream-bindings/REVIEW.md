# Upstream Lua binding boundary review — 2026-10-21

Disposition: independent source review and focused software verification pass,
including the reopened ULB-006 malformed-input investigation. No unresolved
blocking binding finding remains. The stock-library compatibility scope and
separate generated-configuration limitation are explicit below.

## Scope and source identities

RTC worktree: `/home/dgamroth/workspaces/codex/worktrees/rtc-lua-bindings-20261021`,
branch `codex/rtc-lua-bindings`, baseline
`f21c0ed4b6c988cf24292cd7ff93342acef83e9d`. It was clean at review start.
WirePlumber removal worktree: `wireplumber-upstream-lua-20261021`, baseline
`0bef96ae`. The independent stock worktree is
`wireplumber-upstream-stock-20261021`, tag `0.5.18`. Implementation agents own
production changes; this reviewer owns only this document.

The scope is relocation of remaining application-required Lua/POD inspection
bindings into RTC while retaining public upstream WirePlumber interfaces,
PipeWireAO dependencies, exact POD data and existing scientific/lifecycle policy.
The standard-Link review remains the authority for unchanged Link retirement
and Format notification behavior. No live service, GPU, scientific scheduler or
physical hardware qualification is included.

## Design constraints

### ULB-001 — Selective discovery requires a fresh ObjectManager

- **Classification / severity / confidence:** observed API constraint, P1 if
  violated, high; not a claim of a new implementation defect.
- **Evidence:** stock Lua `object_manager_new` requests all `WpObject` features.
  Public C `wp_object_manager_request_object_features` replaces the base mask
  but ORs previously requested masks into registered child types. A later
  request on an already configured stock Lua manager cannot remove those bits.
- **Required implementation:** create a fresh manager with public C APIs,
  register interests and the selective feature mask before installation;
  retain ordinary upstream manager iteration, activation and signals.
- **Required validation:** real managed Node/Port feature states and no unwanted
  parameter-cache activation, rather than a mocked constructor alone.
- **Disposition:** closed. The native action creates a fresh manager; the Lua
  helper adds interests before the caller installs it. The independently rerun
  real inactive-filter test observes exactly BOUND | INFO on the discovered
  Node, with no parameter or port features. No all-feature manager is created.

### ULB-002 — Property metadata belongs to the original Object

- **Classification / severity / confidence:** observed representation constraint,
  P1 if violated, high; not a claim of a new implementation defect.
- **Evidence:** upstream `WpSpaPod` property wrappers store key and flags in
  private wrapper metadata, separate from the public child POD pointer. Reading
  preceding bytes of that child cannot recover metadata reliably. Stock Lua
  Object parsing also collapses duplicate keys into a table.
- **Required implementation:** bounded iteration over the original public SPA
  Object representation, emitting separate records for every property, numeric
  IDs and flags, and independent owned child POD values. Scalar POD values must
  remain native to retain integer width, primitive type and signed zero.
- **Required validation:** duplicate and high numeric IDs, flags, owned lifetime,
  malformed extents, 64-bit integer fidelity, signed zero, arrays and fixed
  choices including trailing alternatives.
- **Disposition:** closed. Public Object bytes supply metadata; each property
  becomes a read-only GObject record and each child remains an owned WpSpaPod.
  Subtraction-based child extent checks reject an entire malformed iteration,
  including after a valid first child. Existing Format total-size, field-count,
  primitive-width, schema, shape and fixed-choice checks remain in Lua policy.
  Independent native and Lua tests cover the required fidelity/lifetime cases.

### ULB-003 — Existing upstream facilities remain the implementation owners

- **Classification / severity / confidence:** source-supported design decision,
  P2 if unnecessarily duplicated, high.
- **Evidence:** upstream 0.5.18 exports `GLib.get_monotonic_time`, existing POD
  builders/scalar parsing, ObjectManager operations, public event dispatch and
  asynchronous hook transitions. A new clock binding, POD constructor library,
  generic Lua FFI or alternate event/lifecycle engine is unnecessary.
- **Required implementation:** use the stock clock directly; limit the local
  native module to missing inspection/construction actions and a narrow public
  event constructor bridge where needed for the separately identified upstream
  Lua event-properties bug. Keep metadata JSON separate from native POD values.
- **Disposition:** closed. The native module adds thirteen public-API actions and
  one property-record GObject; the Lua helper calls those actions explicitly.
  POD construction and scalar parsing remain upstream. JSON contains only type
  names and bounded width/count metadata, never Long/Float/Double values. The
  event action uses the upstream dispatcher, with properties/source/subject
  ownership following its public constructor contract. Native asynchronous hook
  tests pass with epoch matching, cancellation and deterministic deadline races.
  No private wplua dependency, global constructor override or alternate session
  authority was introduced.

### ULB-004 — Iterator backing storage was freed on return

- **Classification / severity / confidence:** confirmed implementation defect,
  P1, high; corrected during review.
- **Evidence:** the first `pod-fields` and `pod-properties` implementations
  passed a `g_autoptr(GPtrArray)` directly into `wp_iterator_new_ptr_array`.
  That public function takes transfer-full ownership and stores the array
  without adding a reference. Automatic scope cleanup therefore freed the
  returned iterator's backing array and child objects.
- **Correction:** both successful returns use `g_steal_pointer(&children)`;
  malformed-input exits retain automatic cleanup.
- **Independent verification:** `/tmp/rtc-lua-review-iterator.c` constructs a
  Struct containing Int(42), obtains the native fields iterator and reads its
  first value against stock 0.5.18. Restoring the two faulty return expressions
  in an investigative source copy reproduces SIGSEGV (exit 139); the same probe
  compiled against corrected production source exits 0. This was an isolated
  reconstructed pre-fix experiment, not a production-file mutation. The worker
  separately observed failing Lua suites before the correction.
- **Disposition:** closed. Source correction, independent behavioral reproduction
  and maintained native/Lua regression-suite reruns all pass.

### ULB-005 — Stock binding compatibility and generated configuration differ

- **Classification / severity / confidence:** observed integration limitation,
  P2, high; a separately identified upstream defect, not an RTC binding defect.
- **Evidence:** upstream `internal-comp-loader.c` converts dependency-array
  strings with `wp_spa_json_to_string`, retaining quotation marks, while providers
  are parsed names. RTC's generated dictionary configuration serializes quoted
  dependency values. Bare relaxed SPA-JSON dependency tokens used by native
  test configurations do not trigger the defect.
- **Required disposition:** report stock API/binding tests separately from
  generated-configuration startup using the independently fixed library. A bare
  token test configuration is not proof that stock loads generated JSON.
- **Disposition:** accepted limitation. The coordinator explicitly retains the
  quoted-dependency fix in a separate generated-configuration deployment cohort.
  No serializer workaround or replacement component loader is introduced.

### ULB-006 — A null boxed result bypassed Lua assertions

- **Classification / severity / confidence:** confirmed implementation defect,
  P1, high; found by the worker's added negative Lua tests after the initial
  focused pass, corrected and independently verified before final acceptance.
- **Evidence:** stock `wplua_gvalue_to_lua` passes boxed values, including NULL,
  to `wplua_pushboxed`, creating truthy Lua userdata. `assert` on a nullable
  iterator/POD/metadata return therefore does not establish a valid payload.
  `lua.fields(Pod.Int(1))` reached `wp_iterator_ref(NULL)` through `:iterate()`
  and triggered `g_rc_box_acquire: mem_block != NULL`, terminating the fatal-log
  test process instead of raising a catchable Lua error. Malformed extents
  rejected by native traversal could reach that same error path.
- **Correction:** native boolean `iterator-valid` and `pod-valid` actions expose
  payload presence explicitly. The Lua wrapper checks them before iterator use
  or returning a copied POD. Array metadata returns an owned empty JSON object
  on invalid input; Lua rejects its missing type. Choice-child extraction is
  preceded by validated Choice metadata. The container/metadata inspection
  actions also cap total POD size at 64 KiB before child traversal. No upstream
  marshaller modification or global Lua override is introduced.
- **Independent verification:** the unchanged
  `/tmp/rtc-review-null-before/scripts/review-bad-container.lua` tests rejected
  Struct, Object and Array inspection of Int(1), plus `copy(nil)`. An isolated
  reconstruction without the iterator guard reproduces the native assertion
  (exit 133). The identical script with the corrected module/helper exits 0,
  with every `pcall` returning false as required. The nine-suite selection was
  independently rerun after this fix; all pass. Native malformed-child tests
  establish rejection of incomplete extents, while these Lua tests establish
  safe handling of the resulting null boxed payload.
- **Disposition:** closed. The initially passing positive-input suite did not
  establish this error-path guarantee; the final acceptance includes the added
  negative cases and same-input fail-before/pass-after evidence.

## Validation

From the RTC worktree:

```sh
meson test -C /tmp/rtc-lua-bindings-build --no-rebuild \
  ao-lua ao-lua-native ao-connections ao-owner ao-acquisition \
  ao-session-hooks ao-session-journal ao-links rtc-host --print-errorlogs
git diff --check
```

Independent result: **9 suites passed, 0 failed, 0 skipped, 0 timed out**;
whitespace check passed. `ao-lua-native` includes seven cases: owned property
records/duplicates/flags; owned Struct children/bounds; Object property bounds;
Choice/Array bounds; an unused malformed nested value that is not recursively
parsed; native event properties/source/subject lifetime; and real selective
discovery. Lua values cover Int32,
UInt32 IDs, ±(2⁵³ + 1), Int64 endpoints, Float/Double negative zero and exact
primitive type distinctions. The native tests explicitly release parents and
an iterator before reading retained values. Fixed Choice.None tests preserve
default ownership, trailing alternatives and source flags without mutation.

The existing policy suites retain exact identity, Format validation, required
loss, pending retirement, no resurrection, source-first fault handling and
absolute deadline behavior. This relocation changes calls to local helpers and
the stock GLib clock, not their admission or lifecycle decisions. The real host
test exercises the native Status endpoint against the stock library; mocked
science boundaries in hook tests are not live scientific processing evidence.

The reviewed stock worktree differs from tag 0.5.18 only in two Meson dependency
names selecting `libpipewire-ao-0.3` and `libspa-ao-0.2`. Its `lib/` and `modules/`
trees have no source delta. The RTC bridge's dynamic imports contain only public
WirePlumber/GLib APIs; no private wplua or removed extension symbols are used.
The test build selects `/home/dgamroth/.local/opt/pipewireao-wp-upstream-stock-20261021`.
POD-filter capacity, event-properties construction and quoted component
dependencies remain independently demonstrated upstream bugs. The RTC event
constructor bridge avoids the Lua event-properties defect through public C
APIs; it does not repair or conceal the upstream implementation.

Full generated-configuration startup and CPU array/coexistence receipts are
coordinator integration evidence, not independent reruns in this report.
Functional software tests establish neither deadline qualification nor
GPU/physical-loop behavior. No GPU, installed service or live workstation
simulation was used in this review. Raw inherited Meson environments were not
copied into the repository.

## Final integration evidence inspected

The following runs were performed by the coordinator. This reviewer inspected
their receipts, logs and relevant source, and independently summed the Julia
summary rows; these are not additional independent integration executions.

| Cohort | Observed evidence and scope |
| --- | --- |
| Stock WirePlumber CPU array/coexistence | `/tmp/rtc-upstream-bindings-array-stock-final.log`: 19/19 checks. The corresponding `rtc-upstream-bindings-array-stock-final-20261021/receipt.json` records three received Float32 arrays `[1,-1]`, `[2,-2]`, `[3,-3]`, exact source/sink port IDs, RTC-owned Link identity, successful withdrawal and no cleanup errors. |
| Three-bug-fix library CPU array/coexistence | `/tmp/rtc-upstream-bindings-array-threefixes-final.log`: 19/19 checks, with equivalent data, exact-Link and clean owned-resource teardown evidence in its `*-final-20261021/receipt.json`. |
| Julia package regression | `/tmp/rtc-upstream-bindings-julia.log`: 75 test sets, 2,329/2,329 passing assertions. Totals independently recomputed from all summary rows. |
| Production policy fault ordering | `/tmp/rtc-upstream-bindings-policy.log`: 7/7 assertions, identifying production session source SHA-256 `bce1d81600e0fac7a7df611e9651787c7691d59b1cd3adf537d534ae1eec0498`. |
| Actual generated configuration, stock library | `/tmp/rtc-generated-stock-20261021/receipt.json`: expected refusal, process exit 78. The log explicitly names missing provider `'"support.lua-scripting"'`, confirming ULB-005 with the production generator's quoted dependency value. |
| Actual generated configuration, three-bug-fix library | `/tmp/rtc-generated-threefixes-r2-20261021/receipt.json`: expected Configuring response and final child exit 0. The inspected probe uses `SessionConfiguration.write_session_config`, connects the real Julia `NativeControlClient`, requests Status and asserts the returned lifecycle is `:configuring`. Scientific owners are absent. |

The array test source additionally asserts post-withdrawal absence of the
selected Link, preservation of the unrelated Node, and a still-running separate
WirePlumber daemon with its own process identity. Both receipts record that
only owned children/resources were closed and the private core remained alive
until its owning helper stopped it. These are CPU transport/ownership results,
not timing, GPU or physical actuator evidence.

The generated-configuration probe is `/tmp/rtc-generated-configuration-probe.jl`.
The coordinator reports that its initial three-fix attempt was refused by the
client's runtime-directory permission check (0755); that attempt remains at
`/tmp/rtc-generated-threefixes-20261021` without a success receipt. The inspected
final probe explicitly sets its owned temporary runtime directory to 0700 before
connection. This is a probe setup correction, not a library or RTC production
permission relaxation.

The final three-fix process log also contains `Session control publication
failed` and an AO session fault. The coordinator places this after client close
during teardown; the receipt's exit 0 alone does not establish fault-free
shutdown. Therefore this generated-configuration result proves one native
Status response in Configuring with owners absent, and does not claim Prepare,
Start, Stop, complete scientific lifecycle or clean shutdown qualification.

Source review confirms that the generator declares `ao.lua` required before
the session script and that staging includes both `module-ao-lua` and
`lib/ao-lua.lua`. Configuration tests assert the component/provider dependency.
The array integration configuration declares the same component; its test Lua
policy uses stock `GLib.get_monotonic_time` for both initial and withdrawal
deadlines. These are direct migrations, with no alternate serializer, component
loader or global clock alias.

## Reviewed source identities

| RTC source | SHA-256 |
| --- | --- |
| `native/modules/module-ao-lua.c` | `7c1426056861b8125c69ed1fd2c15633ce9c61bb5bf160ea2c75b487299374de` |
| `native/scripts/lib/ao-lua.lua` | `76e363437d4a3b44acb8ba88df9aea9f388362c2bfd7633fa3163c9066eabd74` |
| `native/scripts/lib/ao-control.lua` | `47ffa6e38f0a2220bec6852c9d3e4d0a75ccbc04b050f4f759a773c4838664c8` |
| `native/scripts/lib/ao-connections.lua` | `e70f6cbbdfaaff3733b677fa1e640bcf334694c91b1b0a243180d42aeda9602a` |
| `native/scripts/ao/session.lua` | `bce1d81600e0fac7a7df611e9651787c7691d59b1cd3adf537d534ae1eec0498` |
| `native/tests/ao-lua.c` | `b705b902c895c88794258701b55ba618c8818cf351b7a5ceabb9074fe502cfba` |
| `native/tests/scripts/ao-lua.lua` | `8687fccb680cb4aee33240c1bb0a5afcee561ffd30cc90c016f772f726e9bb22` |
| `src/configuration/session_configuration.jl` | `adc4404ff055055c4bca25f74d50ae9be53a39235826a2d429ec382ca10d4cef` |
| `src/deployment/science_export.jl` | `cfc1be3a3d8c006dd864040dea1f54c3f8f6ae821ade903a1b9f7fae098a47e2` |
| `test/integration/session_items.jl` | `aaa68f8c8d6930c26022fe4dfc4228df6bdf3df86dfb5476b565970730d9c57f` |
| `test/data/session_items/validation.lua` | `b8eceaf9c479e8cab1fb7c79a131d57df31d1c19a8eff3f1503bec359819f755` |
| `test/test_session_configuration.jl` | `d262fc3e49e89690b29b7bb317edf9a1f7b28fd3d511971d6ebad8719155e19c` |
