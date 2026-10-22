# Classic CPU shutdown investigation — 2026-10-21

Status: independent source and sanitizer review establishes CSD-02; the minimal
remediation is implemented and independently source-reviewed. Focused sanitizer
fail-before/pass-after, all native suites, managed held shutdown, finite science,
and both fault/recovery cases are verified. Canonical deployment and its held
shutdown regression are independently verified. The original CCPU-04 deadline expiry
remains a separate unresolved observation.

Reviewed worktree:
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-classic-shutdown`, branch
`codex/classic-shutdown-20261021`, base
`1c37543517275612ff1f35adc8794bf3cb239643`. At review entry the primary agent's
`test/integration/classic_shutdown.jl` was untracked. The reviewer changed only
this review record and did not operate services or alter the harness.

## Scope and source conclusions

This follows [CCPU-04](../20261021-classic-cpu-loop/REVIEW.md#ccpu-04--initial-run-native-quit-expired-initiating-mechanism-unresolved).
Its original five-second expiry remains failed evidence with an unresolved
initiating mechanism. Process accounting is not a shutdown-phase trace.

- **Observed in source:** `native/scripts/ao/session.lua` gives Quit one absolute
  deadline capped at five seconds. The operation serializes source hold, graph
  hold, link withdrawal, source shutdown, bootstrap shutdown, controller release,
  and exact control-client removal. `docs/operations.md` explicitly requires
  preserving this dispatcher bound unless a separate contract change is approved.
- **Observed in source:** the ordinary simulator uses legacy source control.
  `acquisition.shutdown` is consequently an immediate no-op; the source bootstrap
  owns actual cleanup and is first in `owner.shutdown_order`. Its successful
  completion follows HIL/observation cleanup and final operational-report writing.
- **Observed in source:** each bootstrap retains its successful terminal result
  and cold control transport until the shared controller is removed or its ticket
  expires. The session deactivates that controller only after all owner results
  have been validated. Scientific cleanup precedes terminal publication; process
  exit need not precede the last owner acknowledgement.
- **Observed in source:** `connections.wait_clients_removed` polls exact global
  ID/serial identities, tolerates a replacement incarnation, checks core identity,
  and has bounded cancellation. This review found no demonstrated client-removal
  wait defect or circular dependency in the intended shutdown ordering.
- **Observed in source:** the held simulator loop observes bootstrap cancellation
  at its serialized service boundary. Native graph quit is repeated until main
  excludes the hook before node close, explicitly covering quit-before-run races.

The reviewed bootstrap runtime, endpoint and AOS extension match the released
RTC 0.2.1 source used by the selected CPU owners. The selected manifest records
AOS/HIL 0.2.2; the HIL cleanup seam closes streams/core/context and then stops and
closes its thread loop. No assumption about the newer AOS development checkout
is used here.

## Findings and experiments

### CSD-01 — First traced Ready→Quit trial terminates the native manager

Severity: medium. Confidence: high for the failed trial; unknown for its cause.
Classification: observed runtime failure, distinct from the original CCPU-04
expiry. Disposition: addressed by the confirmed CSD-02 correction; equivalent
held managed shutdown now passes. The precise allocator reuse behind the
uninstrumented GLib crash was not captured.

Evidence root:
`/home/dgamroth/workspaces/codex/worktrees/classic-shutdown-20261021/ready-001`.
Exact manager: `pipewireao-session@2b8c81efa77f.service`, invocation
`1806dee736ca493390b598de171c5b6c`, PID 102186. The attempt receipt retains
`accepted=false`, and the client failure is `native control outcome unknown:
owner proxy was removed`.

Independent inspection of the retained RTC journal gives these embedded
monotonic timestamps:

| Event | Monotonic microseconds | Since Quit entry |
| --- | ---: | ---: |
| Quit start | 4509782578 | 0 ms |
| Hold source | 4509782985 | 0.407 ms |
| Hold graphs | 4509796482 | 13.904 ms |
| Withdraw links | 4509803772 | 21.194 ms |
| Source shutdown | 4509815458 | 32.880 ms |
| Owner shutdown | 4509815630 | 33.052 ms |
| Source bootstrap request, PID 102016 | 4509815666 | 33.088 ms |

The retained RTC journal stops before any owner callback. The primary agent
separately inspected systemd evidence and reports manager signal 11/SEGV at
4509824445 microseconds, about 41.867 ms after Quit entry. This signal evidence
must be retained with the final investigation record. The source and graph
owners subsequently report revoked retained controllers; those errors do not
identify the initiating failure.

This trial used a copied prefix with temporary Lua phase/effect/owner logging.
The trace records synchronous function return, not asynchronous phase
completion; the next phase entry proves the latter. Owner callback logging
precedes reply validation, so callback entry alone is not a valid-ACK proof.
The instrumentation changes no deadline or operation ordering, but it remains
a changed execution environment and cannot yet be excluded as a contributor.

The selected next discriminator repeated the same isolated held CPU scenario
using the original uninstrumented prefix, with a debugger attached only to its
exact manager incarnation after Ready. The approximately 42 ms manager crash
is not evidence of five-second budget exhaustion and does not justify widening
the production deadline.

Follow-up `ready-002` used the original uninstrumented prefix and also received
SIGSEGV. The independently inspected `ready-002/debugger.log` identifies the
faulting main-thread PC as `0x7f10b0ca5209` in system GLib, followed by another
private GLib frame, `g_main_loop_run`, and native `main.c:166`. Other threads are
waiting. This rules out the temporary Lua tracing as a necessary condition of
the observed crash; it does not locate the first invalid memory operation.

Static instruction inspection used the installed x86-64 GLib 2.84.4 library,
`/lib/x86_64-linux-gnu/libglib-2.0.so.0`, SHA-256
`980ab64e995225de1543779e3bafafac9d705904d42ca3b5eb76e7a336cc5e1d`, build ID
`4b881c2eb20a863a8c8f695345453dd32248ffb4`. `nm -D` places `g_main_loop_run` at
`0x5eff0`; comparison with the retained return address gives a library base
of `0x7f10b0c47000` and fault offset `0x5e209`. Narrow `objdump -d` inspection
shows a load through the pointer previously read at offset `0x58` of a
candidate source, immediately after setting bit `0x10` at offset `0x2c`.
The installed public `GSource` layout assigns those offsets to `priv` and
`flags`. This supports inspecting source-private state; the retained backtrace
does not include register values or memory proving a particular stale source.

Additional source inspection found balanced ownership in the RTC deferred
event delivery path: it retains the endpoint and current source across signal
dispatch, and compares source identity after potentially reentrant handlers.
The upstream `wp_core_idle_add`/`wp_core_timeout_add` functions return owned
source references; Lua boxed ownership consumes those references. No confirmed
refcount defect or POD overwrite was found in this bounded inspection.

The next discriminators considered were retained fault registers/source memory
and memory-error instrumentation of the exact RTC process. A Valgrind run can instrument system
GLib accesses; an RTC/libwireplumber ASan build can detect misuse in those
components but leaves ordinary system GLib loads uninstrumented. Neither the
GLib crash location nor the timing identifies the initiating writer/free.

### CSD-02 — Repeated link-observer detach writes through a freed native proxy

Severity: high. Confidence: high. Classification: confirmed RTC memory-lifetime
defect. Disposition: corrected; independently verified in source, focused
sanitizer fail-before/pass-after, and managed held/finite shutdown.

Affected code: `native/modules/module-ao-control-endpoint.c`,
`link_observer_detach` and `link_observer_free`. The observer connects detach to
`pw-proxy-destroyed` and calls detach again when the retained WpLink's qdata is
finally freed. The installed SPA implementation of `spa_hook_remove` unlinks
the hook without clearing its list pointers or `removed` callback. Thus the
first detach leaves stale neighbor pointers, and the later finalization repeats
the unlink after the native proxy has been freed.

**Observed:** independent inspection of
`ready-003-asan/rtc-journal.jsonl` reports an eight-byte heap-use-after-free write
in `spa_list_remove`, called by `spa_hook_remove`, `link_observer_detach:173`,
and `link_observer_free:180`, during Lua garbage collection. The destination is
88 bytes into a freed 120-byte allocation. The retained free stack identifies
`core_event_demarshal_remove_id`; allocation identifies `pw_proxy_new` through
`wp_global_proxy_step_bind`. The phase trace again reaches link withdrawal and
the first source bootstrap shutdown request before the invalid write.

**Derived:** the source's two detach paths and the SPA header's non-clearing
unlink semantics explain this sanitizer finding without changing the shutdown
deadline, owner order, or upstream WirePlumber. Earlier inspection of GSource
ownership found no defect because the later GLib fault was an observed crash
site, not the demonstrated initial invalid memory access.

Recommended correction: after removing the observer hook, zero the complete
hook. This clears stale neighbor pointers and the optional removal callback.
Subsequent detach is a no-op; reattachment is preserved because
`spa_hook_list_append` initializes the hook before insertion. Merely resetting
the link to a self-list would still retain its callback and private pointer.

The implemented diff adds exactly that complete-hook zero and an explanatory
comment. The independent reviewer inspected it and the native regression diff.
No operation deadline, shutdown ordering, scientific owner or upstream
WirePlumber implementation changes are part of this correction.

The expanded `format-observation` regression explicitly releases the retained
WpLink after native retirement and the core/remove-id fence, and checks final
destruction through a weak notification. Its preserved fail-before run in
`ao-links-before.log` aborts after approximately 0.04 seconds with the same
ASan invalid write, now reached directly from `format_observation:349` rather
than Lua garbage collection. This isolates the native lifetime defect from
scientific execution and the five-second session budget. A separate
`format-observer-rebind` case performs two public deactivate/reactivate cycles,
checks one forwarded native Format notification per cycle, and verifies final
destruction. Source inspection confirms that this covers retained observer
reattachment as well as final detach.

The independent reviewer subsequently checked the recorded pass-after results:
`ao-links-after.log` passes, and `asan-native-suites.log` and
`fixed-native-suites.log` each report all ten suites passing. The detailed ASan
test log includes all fifteen native link cases, including format observation
and observer rebind. ASan used `detect_leaks=0:abort_on_error=1`; this is invalid
access coverage, not leak qualification. The ordinary prefix's libwireplumber
binary and session Lua compare byte-for-byte with their unchanged originals.

Reviewed remediation source hashes:

| File | SHA-256 |
| --- | --- |
| `native/modules/module-ao-control-endpoint.c` | `16127f062905bb53f785870afa3437aebc6f114b5c05d16826a6d50d7c583154` |
| `native/tests/ao-links.c` | `77cf2056f8eb9bed925bb813d94f35444c9995f3f4459188c1bdf4ae0cbc0ea9` |

Validation obligations and disposition:

1. Extend the existing native format-observation regression to retain the WpLink
   after native retirement, synchronize until the server's remove-id has freed
   its proxy, and then release the final WpLink owner. Demonstrate the same
   sanitizer failure before and no invalid access after the correction.
2. Exercise detach and reattach on the same observed WpLink and verify that each
   subsequent format event is forwarded once. Repeated detach and a never-bound
   observed link must be harmless. The rebind/finalization regression covers the
   former; source inspection confirms the never-bound zero-initialized observer
   has no foreign list pointers or removal callback to access.
3. Repeat isolated managed Classic Ready→Quit with the ordinary corrected native
   build, complementing the precise ASan native lifetime regression. Require
   accepted native Quit, clean owner shutdown and exact cleanup; retain failed
   trials separately. The ordinary managed pass is verified below. A corrected
   full managed run under ASan is not claimed.

Relationship to CCPU-04: freed-memory writes can produce allocator-dependent
symptoms, including a later unrelated crash or damaged callback state. That
makes this defect a plausible contributor to the original five-second expiry,
but the original trial lacks an invalid-access trace or phase trace. Fixing
CSD-02 and passing new shutdowns does not prove that CCPU-04 had this cause.

## Managed pass-after evidence

The reviewer independently inspected these retained receipts and logs under
the same investigation evidence root:

| Case | Verified evidence |
| --- | --- |
| `ready-004-fixed` | 11/11 assertions; Ready without Start; accepted native Quit; stopped/success ledger; all exact PID/cgroup cleanup checks true |
| `closed-loop-fixed` | 2,859/2,859 assertions; 256 exact controller/plant comparisons; accepted Quit and complete stopped/success cleanup |
| `fault-link-fixed` | 134/134 assertions; exact required-link removal produces Fault and acknowledged source hold; failed cohort fully cleaned; fresh cohort reaches Running and ends stopped/success |
| `fault-controller-fixed` | 40/40 assertions; injected graph/controller process exit produces policy shutdown with uncertain source hold; exact failed-cohort cleanup and fresh Running → stopped/success recovery |
| `ready-005-canonical` | 11/11 assertions using the stable deployed prefix; accepted native Quit; stopped/success and all exact process/cgroup cleanup checks true |

The held-run receipt's manager invocation is
`5ec7a4b97e0f4bc09ab9d2424729f252`, unit
`pipewireao-session@ab5398fda651.service`. Its native executable, endpoint module,
libwireplumber and test-source hashes match the reviewed files. The recorded
19.54 seconds includes the client call and deployment/process cleanup; it is
not a measured five-second native effect duration. Native acceptance still uses
the unchanged dispatcher bound.

For the full finite rerun, all three payload hashes were independently
recomputed and match both its receipt and the prior accepted run-005 payloads.
All four harness hashes also match. Corrected and zero-command mean pupil OPD
RMS remain 51.03357998457757 nm and 281.04609905785304 nm. This confirms the
selected deterministic CPU science result survived the native correction;
it does not establish independent physical-model validity or wall-rate timing.

The link-removal case retains an exact stopped source acknowledgement, zero
source command-timeout entries and zero uncertain-hold entries. Its expected
faulted cohort finishes `phase=failed`, `cleanup_complete=true`, while the fresh
cohort finishes `phase=stopped`, `service_result=success`, without error. This is
the newly observed held outcome; it does not rewrite the previous uncertain
hold evidence or establish why that earlier trial differed.

The controller-exit case retains one uncertain-hold message after the injected
scientific controller exits: `Node operation expired; submitted outcome unknown`.
Its source command-timeout array is empty. This gate accepts bounded emergency
policy shutdown and exact cleanup, not a demonstrated source hold or successful
normal Quit of the damaged cohort. The fresh cohort reaches Running and then
stops successfully. This explicit failure-path observation is separate from
CCPU-04's original normal-Quit expiry.

The canonical trial uses
`/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021`, invocation
`0821ab62027f43378f8027c8b4df7e6e`. The reviewer checked its three recorded native
hashes and both policy hashes against the installed files. The deployed endpoint
module matches the tested ordinary module, SHA-256
`f6c374cf3784523b01562ac6d66cb118a26b066b6fde38c736a8a456a7ec38ce`.
The original module backup and deployment hash record also verify. The original
host binary is unchanged from the retained initial prefix, as is libwireplumber;
the retained five-second policy is unchanged. The final CPU Ready→Quit helper
hash is `4befaa64fa6a070b301b9cc2d3d77bef214cb30659d7d3f16a2ab9580acddd7b` and
matches both passing held-run receipts. It emits success only after the full
testset passes, requests native Quit once, and retains exact cleanup evidence.

The final independent disposition accepts CSD-02's correction and CSD-01's
observed post-fix managed shutdown result. The ASan write offset (88 bytes into
a freed native proxy) coincides with the public GSource private-pointer offset
used at the uninstrumented GLib crash, making allocator reuse a consistent
explanation. No retained core proves that exact reuse. Historical CCPU-04 has
not recurred in these post-fix normal shutdown trials, but its initiating cause
remains unproved. None of the fault-path results has been relabelled as a clean
normal shutdown of a damaged cohort.

## Verification boundaries

This is source and retained-evidence inspection. It establishes the CSD-02
defect and its focused verified correction, but not shutdown reliability. No GPU execution,
hardware validation, timing
qualification, or success reclassification of earlier failed runs is claimed.
