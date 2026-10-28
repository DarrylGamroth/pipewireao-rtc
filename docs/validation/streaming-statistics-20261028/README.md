# Headless streaming statistics — 2026-10-28

Implemented on dedicated `codex/streaming-statistics-20261028` worktrees, based
on RTC `958fb59` and JuliaFilterGraph `edd39e2`. RTC upstream `e1a1fed`
(0.2.40) was subsequently merged before acquisition integration. The initial
numerical campaign below did not change installed applications or run a GPU,
physical device or live native stream.
JFG implementation/review commits are `c37c66a`, `f771217` and `7156ec4`;
the numerical source identity below binds the optimized results independently
of documentation and packaging commits.

## Acquisition integration and publication

FGA 0.8.14 is published from JFG `8bf45ec`; its registered tree is
`7aa2f3152e8307916199c56fed86f69e08f0fe43`. Full `Pkg.test` passes. The first
sandboxed run found a missing direct Statistics test dependency; after declaring
it in the test project, the same full selector passes. A fresh registered
consumer with no path overrides also passes the statistics and actual Graph
selectors (`REGISTERED_STATISTICS_PASSED`). Logs are retained under
`~/.cache/pipewireao/streaming-statistics-20261028`.

RTC 0.2.41 adds typed FITS startup bindings for optional analysis, using the
existing graph owner's preparation path. Bounded acquisition provenance retains
the selected graph, binding declaration, recipe, calibration and per-file hashes
in the artifact manifest. The declaration hash binds HDU/axis selection, while
file hashes are checked against the actual prepared snapshots. Registration
rejects an inconsistent graph identity.

Classic/GPI workflows and their numerical evidence are maintained in the
instrument repository's README. Candidate observation is distinct from dark,
lamp, eligibility or physical precision qualification. GPI references consume
the controller's published normalized-pupil samples; a dropped raw stream cannot
recreate its previous-frame normalization. Its additive modal reference is
`-R × mean(normalized pixels)`.

## Delivered scope

- FGA's ordinary CPU `ArrayStatisticsF32` declaration supplies finite,
  sliding-window and exponentially weighted per-element mean, variance and
  standard deviation, with explicit schemas and bounded preallocation.
- An optional RTC analysis capture attests direct outputs from one finite
  statistics node, requires exact completion count, rejects mixed/invalid
  source metadata, and publishes one immutable snapshot through an atomic flag.
  The frame writer never mutates a published snapshot. A control task performs
  ordinary Git/SQLite artifact registration. There is no frame-thread I/O,
  automatic parameter application, new database schema or live-control protocol.
- Existing GUI catalog compatibility checks require exact scope, type, shape,
  schema and FITS BUNIT. Generated array registration now accepts explicit units
  and verifies that FITS preserves them exactly before catalog publication.
  No GUI source changes or instrument-specific renderer are required.

Finite/sliding variance is sample variance (N−1); EW variance is central weighted
population variance. EW uses an explicitly configured nominal accepted-sample
period, not irregular timestamps. Windows count accepted analysis frames;
copy/drop-oldest queues do not guarantee contiguous exposures. Array output
headers follow the latest source sample, while artifact metadata records the
actual captured count, first/last sequence, gaps and available cohort identity.
There is no per-element validity-mask implementation or automatic reference-sign
conversion. A mean of residual gradients is not an absolute reference.

## Validation

Julia 1.13.3, selected source environment:
`~/.cache/pipewireao/streaming-statistics-20261028/environment`.
Its Project/Manifest select the two task worktrees and the existing registered
scientific dependencies. A copied `core-environment` adds only FITSIO as a direct
test dependency; no resolved versions changed.

From the JFG worktree, the focused selector is:

```sh
julia --startup-file=no --project=ENVIRONMENT -e '
include("julia/FilterGraphAlgorithms/test/array_statistics.jl")
include("julia/FilterGraphAlgorithms/test/public_docs.jl")
include("julia/FilterGraphAlgorithms/test/declaration.jl")
include("julia/JuliaFilterGraph/test/array_statistics.jl")
using FilterGraphAlgorithms, Test
@test isempty(Test.detect_ambiguities(FilterGraphAlgorithms; recursive=true))'
```

The [numerical log](numerical-tests.log) records numerical, declaration,
documentation and actual Graph checks. An independent `--check-bounds=yes`
run passed 3,063 numerical assertions plus 29 Graph assertions, including
rectangular arrays, SIMD tails, BigFloat oracles, cancellation, level shifts,
alias rejection, reset/commit/discard, finite freezing, nonfinite/overflow
rejection and zero warmed allocations. The original forced-bounds numerical
selector is retained in [bounds-tests.log](bounds-tests.log).

RTC selectors (from its task worktree):

```sh
julia --startup-file=no --project=ENVIRONMENT test/test_analysis_capture.jl
julia --startup-file=no --project=ENVIRONMENT test/analysis_statistics.jl
julia --startup-file=no --project=ENVIRONMENT test/test_analysis.jl
julia --startup-file=no --project=CORE_ENVIRONMENT test/test_configuration_store.jl
```

Results: 104 capture assertions, 26 actual Graph/catalog assertions, 114 existing
optional-analysis assertions and 53 existing catalog/journal assertions passed.
The actual Graph selector sends three rectangular frames, captures the finite
products, registers them, retrieves them through the same JSON-lines helper
interface used by the GUI, and verifies FITS shape, values, BUNIT, scope, schema
and source gaps. Its observer has zero warmed allocations on intermediate and
completion frames. Registration creates no scientific update-history entry.
The catalog selector's missing-object negative test deliberately emits a Git
`cat-file` error; its expected exception assertion passes.

No full-suite, physical, native-stream cadence or deadline qualification is
claimed. The optional graph extension is also loaded separately from source.
An earlier concurrent precompile probe emitted missing-cache warnings while
the scientific source was being edited; it is not used as a clean load claim.
The fresh `--compiled-modules=no` probe succeeds with undeclared-import warnings
from Markdown/StyledStrings, VectorizationBase/HostCPUFeatures and
SpecialFunctions/OpenSpecFun_jll. The identical probe against the unchanged
registered-package baseline emits the same six warnings and succeeds. They are
pre-existing dependency/source-loading warnings, not a verified fix in this task.

## Review findings and dispositions

Independent review identified three confirmed defects and verified their fixes:

| ID | Severity | Finding | Disposition and evidence |
|---|---|---|---|
| STATS-01 | P1 | Fixed-origin/subtractive sliding moments erased small signals after large level changes; EW with α=1 could fail to follow input. | Reconstruct sliding moments in two passes; compensated finite/EW means. The same 76-check regression failed 18 assertions before repair and passed afterward: [before](level-shift-before.log), [after](level-shift-after.log). |
| STATS-02 | P2 | Shape/type checks alone allowed unrelated status outputs or EW moments to masquerade as a finite acquisition. | Require one directly exported finite statistics node and exact declared completion count; mixed-node/mode/port regressions pass. |
| STATS-03 | P2 | FITS string cards silently truncated long units or trimmed trailing spaces, breaking existing GUI compatibility. | Validate encoded string-card bounds and surrounding whitespace; require exact BUNIT readback before registering. Boundary, quote, whitespace and overflow tests pass. |

Final independent review found no remaining confirmed blockers in numerical,
indexing, publication, artifact compatibility or SIMD/FMA changes. Local commit
is the Algorithm's state boundary; a downstream Graph-node failure does not
roll back earlier locally committed Algorithm history. Product registrations
are separate transactions; receipts preserve already registered IDs on a later
failure. Neither registration nor a scientific effect is automatically retried.

## SIMD/FMA evidence and measured cost

The corrected scalar baseline is JFG `f771217`, not an old GUI implementation.
Its numerical source SHA-256 is
`4c109fe03766ccce87dab47c08a21404dbc0b4c23a2ae0696a69e95366d23c66`.
The optimized numerical source SHA-256 is
`94a70f6c784163fb47a531df6ff30247665792d83c94759371012bbefba846b8`.
Both runs use the same ordinary single-node prepared Graph, four deterministic
input arrays, 500 warmup calls, a further timed warmup, and five repetitions of
1,024 calls. Finite mode's one-billion-sample limit prevents benchmarking a
frozen result. Sliding mode retains 16 samples. Calls are checked for success,
checksums match, and all six cases have zero warmed allocations.

AMD Ryzen 7 6800H (`znver3`), Julia 1.13.3 / LLVM 20.1.8, Linux x86-64,
one Julia and BLAS thread, CPU affinity 2. GC runs outside each repetition;
per-call `time_ns` overhead is included. CPU frequency is not fixed and the
host is shared. Earlier/repeated runs varied materially, so these paired
medians are observations, not guaranteed speedups or real-time bounds.

| Shape | Mode | Before median (µs) | After median (µs) |
|---|---|---:|---:|
| 1024 | finite | 18.925 | 6.983 |
| 1024 | sliding | 119.995 | 15.789 |
| 1024 | exponential | 18.655 | 6.321 |
| 64 × 96 | finite | 124.543 | 39.734 |
| 64 × 96 | sliding | 473.757 | 94.246 |
| 64 × 96 | exponential | 77.845 | 37.921 |

Full percentiles/repetition medians and environment/source identities are in
[before](performance-before.json) and [after](performance-after.json). The
reproducible JFG harness is `julia/FilterGraphAlgorithms/benchmark/array_statistics.jl`.
Raw samples and concrete LLVM/native listings are retained under
`~/.cache/pipewireao/streaming-statistics-20261028/performance`.

Concrete kernels contain four-lane Float64 SIMD. Finite/EW native listings
contain packed `vfmadd213pd` / `vfmadd231pd`; compensated summation's LLVM
`fadd`/`fsub` retain strict ordering without `fast`/`reassoc`. SIMD visits
independent contiguous elements, preserving each pixel's retained-frame order.
No `ivdep`, broad fast-math or SIMD reduction of compensated sums is used.
Caller axes/aliasing are checked before staging into a dense owned buffer;
forced-bounds tests cover the corresponding indexing proof and tail cases.

Finite/EW work is O(P); sliding remains O(PW), with bounded additional scratch
included in `max_state_bytes`. These measurements cover warmed closed-loop
Graph service cost, not fixed-rate arrival, transport, GUI, tail latency under
offered load, optical correctness or hardware behavior.
