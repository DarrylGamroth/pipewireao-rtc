# GUI service baseline allocation discriminator

Date: 2026-10-06. Read-only source/evidence pass at RTC
`3b5a09dbd07ac8bcecb95a270b02d7144dec2dbc` and GUI
`857bb06f5c3dcb1a250605019b9b0997cc11e46e`, both clean when inspected.
Review worktree: `rtc-bootstrap-allocation-review`, initially at `27b2a0d`.
No SCI, build, test execution or production edit. Cold reads used CPU 11.

## Observed evidence

Cache root: `~/.cache/rtc-native-final-deployment-20261006/`.
`gui-hil-service-classic-fgn-v4/result.json` reports functional success using
installed Classic FGN v11: both cohorts complete 512 frames and commands;
the retained source prefix remains 16 frames. Midrun pause/resume, reset,
matching prefix/truth and the invocation-bound normal service exit pass their
functional checks. The receipt is `exited 0 success` for invocation
`632b8b5e2156426bad30801eb9d84980`.

| Inclusive simulator interval | First cohort | Reset cohort |
| --- | ---: | ---: |
| Measured exchanges | 496 | 496 |
| Allocated bytes | 3,949,304 | 0 |
| Pool allocations | 74,553 | 0 |
| Malloc allocations | 17 | 0 |
| Big/realloc/GC counts and GC time | 0 | 0 |

These values were independently read from both retained `sustained-result.json`
files. Functional service success is not zero-allocation success. The first
cohort fails the inclusive allocation gate; zero collections do not erase
allocation pressure. Neither prefix nor accounting scope should change.

## GUI-ALLOC-R001 — Baseline creates a new selection client after the prefix

**Severity:** high for combined allocation acceptance. **Confidence:** high for
the observed route and known allocation mechanism; exact allocation attribution
in this cohort is unmeasured. **Classification:** observed source/report, with
separately identified hypotheses below. **Affected:** GUI harness
`listed_identity`, `check`, and simulator bootstrap registry ingress.

The retained scenario is `baseline`, with `gui_test=null`. `run_test` returns
immediately for baseline and unattended scenarios: **no Rust GUI test is launched
by this baseline**. The harness nevertheless invokes Julia `listed_identity`
after `D.wait_state` returns a Running admission. That method reads the existing
registry file and then calls `NativeSessionClient.select_session`, which creates
a new native supervisor client, queries it, and closes it in `finally`.
Read-only registry-file listing and this native connection are distinct actions.

The admitted source was already at generation 1, sequence **27**, beyond the
fixed prefix 16. The new native controller's birth/death is therefore inside
the first allocation interval. The primary retained admission client remains
open, but that does not eliminate this second temporary selection connection.
Midrun pause occurs at sequence **281** after checkpoint 256; the held and
resumed snapshots retain sequence 281. The second reset cohort performs neither
the initial temporary selection nor the midrun pause/resume. Final identity
selection occurs after that cohort has completed.

The old [bootstrap allocation review](NATIVE_BOOTSTRAP_ALLOCATION_REVIEW.md)
already independently demonstrated recurring registry-wake allocation:
8,384 bytes for a warmed forced wake/snapshot and 13,840 bytes for capability
construction in its particular cold fixture. SDK global callbacks materialize
copied Globals and property dictionaries before application wake filtering;
managed listeners materialize another copied Global. Endpoint refresh copies
the registry and binds/closes newly appearing/disappearing controller objects.
The current source still contains those mechanisms. Quiet filter-state getter
and atomic-wake fixes do not remove this event-driven allocation.

**What is established:** this baseline reintroduces a post-prefix native
selection connection, and the existing SDK/endpoint design has allocation on
such ingress after warmup. The zero second cohort argues against continuous
quiet allocation for that setup. **What is not established:** how much of this
cohort's 3,949,304 bytes belongs to compiler work, registry materialization,
controller binding/removal, or the first midrun control path. Similarity to the
earlier 3,862,872-byte failure is not an allocation census or unique root cause.

Source status/resume already run during preparation/admission. The ordinary
source RUN/query implementation uses prepared in-place scalar POD buffers;
pause/resume do not rewrite reports. Cold first-pause compilation remains a
hypothesis until distinguished. The reset cohort's different control schedule
cannot resolve that hypothesis by itself.

**Disposition:** retain first-cohort allocation failure and functional service
success as separate facts. No production repair selected in this review.

## Cheapest discriminating sequence for primary execution

1. Reuse the same sealed package, 512/16 counters, service ownership and retained
   client. In a clearly labeled diagnostic coordinator, omit only the initial
   temporary native selection; retain read-only listing/identity checks through
   the already admitted client and retain the same midrun pause/resume. This
   isolates that additional connection from the successful control schedule.
   It is not a substitute for concurrent selection qualification.
2. If needed, perform one late native selection on an otherwise warmed reset
   cohort, keeping its marker lifecycle deliberately inside the measured
   interval. Repeat the midrun control schedule when comparing controls.
   A new attachment can allocate after compilation warmup, so a quiet reset is
   not the relevant warmed attachment test.
3. If attribution remains necessary, adapt the existing diagnostic
   `prepare_allocation_profile.jl` to the current exact package. Keep the same
   prefix/final seams and 2% sample rate; preserve source/seal hashes and label
   the result diagnostic, not timing or zero-allocation qualification.
   The old flat/tree output discarded timing. Local Julia 1.12.7
   `Profile/src/Allocs.jl` confirms fetched records contain timestamp, type,
   size and stack. Save individual sample records after profiling stops.
4. Record coordinator-side monotonic before/after intervals and fresh native
   generation/sequence for selection, pause and resume. Validate the profiler
   timestamp clock mapping before joining these timelines. Do not dereference
   the profiler's explicitly unrooted task pointer. Avoid println, JSON writing
   or newly allocated snapshots in the simulator's measured interval. Any
   optional source-side event trace must use bounded preallocated storage,
   itself prepared before the interval, and remain a diagnostic overlay.

A sampled profile can distinguish compiler/registry/control call paths and
event timing; it cannot establish exact bytes per source by adding inclusive
stack totals or extrapolating each sample to a unique count.

## Design constraints after discrimination

Preparation may compile confirmed cold methods before initial SCI release.
Retaining a selected client before release can remove a specific marker
birth/death from a measured cohort. Both require exact identity and lifecycle
proof, without consuming scientific frames or enlarging the prefix. Such
ordering only qualifies a prepared fixed-client scenario; it does not prove
zero allocation for later detachable GUI attachment.

For arbitrary new native attachment, existing copying SDK registry callbacks
make whole-simulator-process zero allocation unattainable by warmup or wake
filtering alone. A stronger gate requires an approved public SDK/control
change that bounds and avoids these allocations, or an approved process
boundary preserving exact owner identity and authority. This review does not
select either architecture. Moving allocation to another task/thread in the
same simulator, disabling GC, bypassing public APIs, ignoring controller
removal, or dropping required requests would not satisfy the existing gate.

The current functional baseline is useful evidence. Its allocation failure
must remain visible while the primary decides and verifies the required
combined interaction/resource scope.
