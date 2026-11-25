# Startup-settings inspection memory — 2026-11-04 UTC

## Scope and source

Source baseline `9cd1b19d2419811abe1cc32129669e0f0e9a2782`, branch
`improvements/startup-settings-memory-20261104`,
dedicated `pipewireao-rtc-settings-memory` worktree, initially clean. GUI source
and web service are unchanged; its pre-existing untracked SPIDERS test is kept.
This increment changes management tooling and its native client, not the running
RTC application or scientific inputs. The source changes were committed and
fast-forwarded into local main after matching the installed runtime against the
patch. Git promotion restarted no service.

The [original rollout](../management-rollout-20261104/README.md) reported a
1,221 MiB management-family peak. That included the shared cached Julia worker
and an overlapping one-shot reader in the selected application's pinned project.
The settings/schema reply is approximately 4 KiB. Profiling and first/warm-call
comparison point to Julia compilation and generic declaration validation as the
large cost, rather than scientific preparation. Description runs no graph or
backend callbacks. A CPU profile included inference/code-generation frames;
warm allocation samples were chiefly small YAML/declaration objects.

## Measured policy and limits

Fresh Julia 1.13.3 processes, existing compiled package caches, startup files
disabled, same installed CPU application and SDK 4.0.0. Linux `smaps_rollup` was
sampled every 50–100 ms; totals include all descendant processes, and swapped
PSS was tracked separately. Measurements ran sequentially without the core test
suite. First-use latency is distinct from repeated reads; different package
paths and cache construction prevent treating single timings as a latency SLO.

| Temporary pinned reader experiment | Peak PSS | Elapsed process time |
| --- | ---: | ---: |
| Existing `-O0` | 673.0 MiB | 13.6 s |
| `-O0 --compile=min` | 298.1 MiB | 23.6 s |
| `-O0 --heap-size-hint=64M` | 380.4 MiB | 21.9 s |
| `-O0 --heap-size-hint=128M` | 378.7 MiB | 22.6 s |
| `-O0 --compile=min --heap-size-hint=128M` | 246.9 MiB | 26.6 s |

All five settings/schema results were identical. Broad `--compile=min` was
rejected for the shared worker: its first native verification was still running
after approximately 50 seconds; only that test-owned process was stopped. Allocation
profiling during compilation also imposed excessive overhead; it was stopped
and replaced with CPU profiling plus warmed allocation sampling.

The selected policy retains normal compilation and adds a soft heap target:
256M for generated management workers, 128M for description-only pinned readers.
The 256M worker target leaves more headroom for cold compilation than 128M;
both produced similar peaks in the measured workloads. Timing also varies with
package paths and caches, so these trials do not isolate the target's timing effect.
These guide GC, not a memory cap; code, libraries and required live allocations
can exceed them. Preflight/backend warming and independent rebuild-job arguments
are unchanged. The [endpoint contract](../../MANAGEMENT_ENDPOINT.md) documents it.

Actual native-companion IPC, two Describe requests per owner:

| Cohort | Peak family PSS | First / repeated Describe |
| --- | ---: | ---: |
| Original, following catalog read | 1,188.1 MiB | 29.5 / 11.9 s |
| Worker 128M, reader 128M, following catalog read | 736.0 MiB | 38.3 / 18.3 s |
| Worker 256M, reader 128M, Describe first | 728.2 MiB | 46.6 / 17.0 s |

Every reply was identical and every owner returned to one native process after
test-owned shortened idle expiry. Sampled swapped PSS was zero. The first two
cohorts also listed the same 19 existing artifacts. Do not compare the last
cohort's cold latency directly with an already catalog-warmed worker. Existing
60/120-second owner and 50-second reader timeouts remain unchanged.

## Cold token-selection defect

GUI inspection exposed a fresh-Status rejection, including after the external
GUI disconnected. The native client chose a request token before local cold
encoding/validation. Another controller could complete during that work, making
the chosen token obsolete before submission. The client now validates locally
with an unsent positive placeholder, then selects its real token using the latest
observed accepted token. Identity/health checks, exhaustion, absolute deadline,
remaining budget and one submission are retained. No retry or rebinding is added.

The existing private-core two-controller integration was extended to complete a
competing request during local encoding. It failed before the fix: the first
request reused token 8 and was rejected with -114; only one of the two requested
effects occurred. After the fix all 50 endpoint assertions pass, with exactly two
distinct successful requests in the added scenario. The included profile tests
add 23 passing assertions. This uses a test-owned core and synthetic operations;
it sends no effects to the operator's RTC.

Another caller can still win between final token selection and owner admission.
Such a request is rejected safely. This does not promise collision-free
concurrent submissions or weaken fresh native verification. Independent review
found no actionable issue in the resource-policy or token-selection changes.

## Verification and deployment

The final core suite passed 8,860 reported assertions across 376 summary rows;
the earlier policy-only run passed 8,850. The following commands were used:

```sh
julia --startup-file=no -O0 --project=. -e 'using PipeWireAO; ENV["PIPEWIREAO_PREFIX"]=String(PipeWireAO.LibPipeWire.PipeWireAO_jll.artifact_dir); include("test/runtests.jl")'
julia --startup-file=no -O0 --project=. -e 'include("test/test_management_cli.jl"); include("test/test_simulator_configuration.jl")'
PIPEWIREAO_PREFIX=/path/to/native-sdk julia --startup-file=no --project=. test/native_control_endpoint.jl
PIPEWIREAO_MANAGEMENT_BINARY=/path/to/pipewireao-management \
PIPEWIREAO_MANAGEMENT_NATIVE_PREFIX=/path/to/native-sdk \
  julia --startup-file=no --project=. test/management_systemd.jl
```

The focused suite passed 132 assertions; generated-unit activation, literal-dollar
paths, cgroup crash cleanup and independent-job survival passed 11 assertions.
The systemd test's trusted worker substitution now checks its generated argv
before replacement, including the new heap flag. Observed operator unit PIDs and
invocations remained unchanged. The core suite's `git cat-file` diagnostic is
expected from its deliberately deleted-content-object rejection test, not a
runtime failure.

The complete declared runtime closure was exported using `RuntimeExport` under
`~/.local/lib/pipewireao/management/9cd1b19-memory-20261104`. The native management
binary and SDK are unchanged. `ManagementCLI.install` regenerated units, which
passed verification; only management was refreshed, after its worker was idle.
Neither the web service nor any of the five RTC services was restarted. The
installation has no dependency on the source worktree. Runtime receipts retain
package/unit hashes and source-code diff digest
`16c26923bd7818d60a727fed73d42f61565b67168acbd317e83cb8086cfa37b1`.

The deployed web GUI loaded the identical five-field settings/schema/session
projection after the token fix, with engineering controls disabled. The full
cold read took 83.4 seconds, inside existing timeouts; startup latency remains
material. No native writes, page errors or protocol errors were observed. Sample
Header identities matched displayed sequences, which advanced throughout
inspection and idle expiry. The largest observed update gap was 0.287 seconds
and receive-to-poll age 0.185 seconds. Reopening SHWFS after idle returned a newer
source sequence. The bridge spawned no children.

Total deployed management-family peak was **720.9 MiB PSS**, approximately 40%
below the original measured peak. Sampled swapped PSS was zero. The temporary
pinned reader exited after completion, and the shared worker exited after the
normal 60-second idle grace, leaving only native management at **1.48 MiB PSS**
while the browser remained connected and samples continued. These are sampled
resource/application observations, not hardware or frame-deadline qualification.

Before/after checks preserved all five RTC PIDs, process start ticks, executable
SHA-256 hashes and unit invocations, plus the existing web PID/invocation. The
session remained Running. Every existing file hash and SQL row matched: 127
native store files (19 artifacts, 7 materializations, 1,884 events including 5
Unknown), 297 simulator-job files, 20 files in the old empty GUI store, and all 84
frozen installed-application files. The old GUI simulator root remains absent.
No storage migration, reclamation, history repair or scientific replacement ran.

## The five persistent RTC processes

Snapshot at 2026-11-04 09:09 UTC; values are proportional memory, in MiB.

| Process | PID | Resident PSS | Swapped PSS | Responsibility |
| --- | ---: | ---: | ---: | --- |
| Native session | 1786367 | 4.2 | 1.3 | RTC admission, lifecycle and declared application links |
| PipeWireAO core | 1786195 | 14.4 | 2.8 | Native transport, nodes and graph hosting |
| Julia graph owner | 1786228 | 68.1 | 590.4 | Pixel calibration, WFS processing, reconstruction, correction and DM transforms |
| Julia parameter source | 1786229 | 143.7 | 458.3 | Persistent input ports for calibration matrices, backgrounds, reference slopes and offsets |
| Julia simulator owner | 1786230 | 181.3 | 1,281.9 | CPU optical plant/camera simulation and command feedback |

Together these used approximately 412 MiB resident PSS and 2.28 GiB swapped PSS;
reporting resident memory alone would omit much of their retained footprint.
Their memory was observed, not modified. Separating parameter publication and
optical simulation from controller processing isolates ownership/work, at the
cost of three persistent Julia runtimes. This application has a 500 Hz logical
model rate with 10 Hz wall-clock development pacing; no 500 Hz physical-loop
claim follows from these process or GUI checks. Installed `rtc/graph.conf`,
`rtc/parameters.conf`, the live generated parameter-source document and
`simulation.conf` establish these roles.

The parameter publisher's five declared F32 payloads are a 212×376 reconstructor,
two 277-element offsets, a 352×352 background and 188×2 reference slopes: 818,184
bytes (0.78 MiB), plus native buffering. Publication is demand-driven; it keeps
the live-update ports available between requests. Current source declarations
contain no initial payloads. The graph owner loads startup calibration from the
saved FITS bindings separately. The source reports submission; active adoption
is verified at the graph. Attributing the publisher's much larger process
footprint requires its own profiling; payload size alone does not explain it.

Raw profiling logs, screenshots, temporary endpoints/stores and the Python
browser environment (163 MiB) were removed after summarizing. No Rust build was
needed. The merged task worktree was removed after promotion; the installed
runtime is independent of it. Existing scientific storage and source histories
were not cleaned. Changed Markdown links and whitespace checks passed.
