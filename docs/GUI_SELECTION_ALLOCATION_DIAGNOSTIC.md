# Native selection allocation diagnostic — 2026-10-06

This is diagnostic evidence, not GUI qualification or a production repair.
Starting review worktree: `/tmp/rtc-gui-selection-allocation-review`, branch
`docs/gui-selection-allocation-diagnostic-20261006`, clean RTC base
`92444413e4930e1191821b8a402301307fbaca2a`. The installed science package was
cloned from `/tmp/classic-jfg-sdk-interrupt-final-v1-installed`. No production
SDK, RTC, GUI, science implementation, gain, frame prefix, or allocation gate
was changed. The owned SCI reservation ended with all five processes gone.

## Contract and experiment

The unchanged allocation oracle is the simulator's process-wide `Base.gc_num`
difference after retained prefix 16 and through completed exchange 512. It
includes science, native transport and controls on all Julia threads, recording,
diagnostics and interim reports; final serialization is excluded. Zero bytes
and zero GC remain the required acceptance result. Source model rate 500Hz,
wall rate 100Hz, CUDA AOS, CPU JFG and original placement were retained. The
functional harness's success flag does **not** assert the allocation gate.

The diagnostic clone warms only the allocation profiler before preparation,
starts `Profile.Allocs` at the existing seq 16 boundary, sample rate0.005, takes
the original allocation-finish counter before stopping/fetching, and writes
bounded aggregates before report/cleanup. There is no profiling of cold CUDA
preparation. Independent native Selection remains followed by midrun
pause/resume, completion, stopped reset, second completion, independent identity
verification and normal stop. A diagnostic-only fresh-Status wait defers the
first Selection until source sequence >= 17; actual attempt2 started it at 162.
This changes attach timing from the original baseline and is not acceptance.

708 other declared package artifacts, including scientific packages and
processing artifacts, matched the original bytes. The descriptor, owner,
helper and harness hashes are in [experiment provenance](evidence/gui-selection-allocation-20261006/experiment-provenance.json).
The complete original baseline and both attempt receipts remain preserved at
`/tmp/gui-source-allocation-diagnostic-20261006`; compact receipts include their
hashes and paths. No Rust GUI executable ran in this `baseline systemd` scenario.

## Observations

| Window | Completed measured exchanges | Inclusive bytes | Pool / malloc | GC pauses |
| --- | ---: | ---: | ---: | ---: |
| Original baseline first |496|4,045,040|75,458 /34|0|
| Original baseline second |496|0|0 /0|0|
| Diagnostic attempt2 first |496|3,984,776|74,891 /29|0|
| Diagnostic attempt2 second |496|0|0 /0|0|

First diagnostic attempt was unsuccessful: cold attach work allowed source 512
before the midrun checkpoint, so the existing harness rejected it. Service
exit0 and cleanup passed. Its profile files were removed with the private
runtime before preservation; **no profile attribution is claimed for attempt1**.
Attempt2 used warmed caches, fresh paths and external bounded profile retention.
It passed the original functional/reset checks, recording only the original
16-frame prefix. `whole_trajectory=false`: this is not a 512-frame trajectory
comparison. The first allocation gate still fails.

Attempt2 processes were launcher 3902122, core 3902212, JFG 3902231,
simulator 3902691 and RTC 3903397. Service result/exit were success/0;
`cleanup_confirmed=true`, and each PID was independently absent from `/proc`.
The [receipts](evidence/gui-selection-allocation-20261006/receipts.json) preserve
the failed attempt and distinguish functional success from allocation success.

### GUI-ALLOC-D001 — confirmed first-window allocations

Severity: qualification blocker. Confidence: high. The unchanged inclusive
counter shows first-window heap use and second-window zero above. The profile
has 393 samples, 19,292 sampled bytes, two opaque Julia task identities, and 0
samples in generation 2. Sampling is process-wide Julia heap profiling; native C
malloc attribution is not claimed. Sample bytes are not an exact reconstruction
of the inclusive counter.

### GUI-ALLOC-D002 — confirmed compiler work; specific SCI caller unresolved

Confidence: high for sampled compiler work, incomplete for exact caller.
Retained type rows include 77 explicitly `Compiler.*` samples, including
IncrementalCompact closures, IRCode, Refiner and InferenceState. Retained heads
include `already_inserted_ssa → process_node! → iterate_compact → compact!`.
Business ancestry contains
`_with_thread_loop_lock(f::NativeControlEndpoint.poll! closure)`.
The profiler retained the first 32 distinct stack groups and first 8 head frames;
296 of 393 samples are outside those groups. Its relevant-file filter omitted
RTC endpoint and compiler source frames, so the complete initiating compiler
MethodInstance cannot be reconstructed from this SCI profile. Full raw profile
data was cleared and the process exited. No third SCI attempt was made.

### GUI-ALLOC-D003 — confirmed registry copy path

Confidence: high for the observed path; byte attribution incomplete. A retained
sampled stack contains `Dict{String,String}(Dict) → globals → find_globals →`
the endpoint poll lock. Current source and the staged source are identical:

- [bootstrap runtime](../deployment/julia/src/native_owner_bootstrap_runtime.jl):
  registry-added/removed callbacks set `wake`; `_poll_ready!` calls the endpoint
  only for wake/pending, and the reserved monitor runs on Julia thread 2.
- [generic endpoint](../deployment/julia/src/native_control_endpoint.jl): `poll!`
  unconditionally calls `refresh_controllers!`; this snapshots matching globals,
  updates exact serial/PID/incarnation proofs, binds candidates and retires nodes.
- Staged public SDK `core.jl:1388` documents that `globals` copies globals and
  property dictionaries. `find_globals` filters that copied snapshot.

The quiet monitor guard already avoids continuous traversal. Selection adds
and removes an exported public controller; registry maintenance during those
events is expected. That does not establish that all 3.98MB belongs to dictionary
copies or to one compilation.

## Cold private-core discriminator

One additional **non-science** fixture reused the existing private-core helper,
same concrete HIL bootstrap Endpoint/Runtime profile and normal
Preparing→Prepared→Connected lifecycle. A separate Julia process attached,
queried and removed a temporary native controller. No AOS, JFG graph, GPU,
science warmup or production precompile action ran. Owner 3907054 and core 3907088
exited; `CLEANUP_CONFIRMED` was printed. Late-client PID was not recorded; its
protocol phases completed and no matching client process remained.

| Phase | Process bytes | JIT bytes | Compiler time ns |
| --- | ---: | ---: | ---: |
| Quiet before |0|0|0|
| First late attach |1,263,280|9,711|52,708,182|
| Retained late Status |194,592|0|0|
| Late remove |3,046,392|23,645|192,658,543|
| Following quiet 0.3s |1,077,200|28,370|70,770,659|

These bytes include diagnostic closures, pipe IO and sleeping; they are not an
isolated registry allocation benchmark. `--trace-compile=stderr` produced a
bounded 118,649-byte trace with phase markers. The first attachment includes
compilation of the fixture's `round(::Process,...)` and `flush(::PipeEndpoint)`;
that cold fixture work must not be attributed to the owner.

### GUI-ALLOC-D004 — confirmed cold controller retirement specialization

Confidence: high for this cold fixture, derived consistency with the SCI path.
After removal, the trace records first compilation of:

```text
Base.close(::PipeWireAO.Node{Proxy{Registry{bootstrap core},
    proxy callbacks capturing NativeControlEndpoint.refresh_controllers!},
    node callbacks capturing NativeControlEndpoint.refresh_controllers!})
```

It also records proxy pointer comparison and `pw_proxy_destroy`. The exact full
signature is in [cold compile trace](evidence/gui-selection-allocation-20261006/cold-compile.log).
This matches `refresh_controllers!` calling `close(controller.node)` when the
exact controller incarnation disappears. Compilation on the reserved monitor
can span a phase boundary, so the remove/following-quiet split is not exact
per-method accounting. Combined source/profile/trace evidence identifies a
concrete cold retirement specialization consistent with temporary Selection
closure. It does **not** prove that this one method accounts for all SCI bytes.
The retained Status interval has no measured compilation but still allocates;
precompiling retirement alone cannot establish zero inclusive allocation.

## Adjudication needed before a production repair

1. A cold lifecycle precompile experiment targeting the exact retirement
   specialization can distinguish compiler bytes from remaining registry/proof
   publication bytes. Precompile at genuine preparation is a possible latency
   repair, not a demonstrated zero-allocation repair. Do not warm science, move
   counters, inflate the prefix or change attach/reset ordering.
2. The public SDK snapshot contract intentionally returns copies. A future
   allocation repair would need a reviewed public bounded traversal/cache API
   and exact controller proof/retirement semantics; direct private registry
   layout access is inappropriate. Controller binding, NodeInfo conversion and
   capability publication also require accounting, not just `find_globals`.
3. Preserve the whole-process gate. Moving cold work to another Julia thread
   does not exclude it from this counter; the existing monitor already uses a
   separate thread. Any different process/scope contract is an architectural
   decision, not a local profiling fix.
4. After an approved change, repeat the same first late Selection and reset
   fixture with unchanged source counts/identity/cleanup, and independently
   require zero inclusive allocation. Repeated late attach/remove is needed to
   distinguish one-time compilation from recurring metadata allocation.

No production modification, automatic warming, retry, GC suppression, gate
relaxation or claimed remediation is included here.

## Reproduction and evidence

SCI attempt2 command (only under the explicitly granted reservation):

```sh
taskset -c 11 env JULIA_PKG_OFFLINE=true julia --startup-file=no \
  --compiled-modules=existing \
  --project=/tmp/classic-jfg-sdk-interrupt-final-v1-installed/julia \
  /tmp/gui-source-allocation-diagnostic-20261006/check_diagnostic.jl \
  /tmp/gui-source-allocation-diagnostic-20261006/package \
  /run/user/1000/gui-alloc-diagnostic-attempt-2-20261006 \
  /tmp/gui-source-allocation-diagnostic-20261006/evidence-attempt-2 \
  /tmp/gui-native-gates-build/gui-native-gates-test-13ef605bcf1e6d614702190911e35d3c44bb8f02aeced5abe300b06cd3dc1ac0 \
  baseline systemd
```

Cold discriminator command:

```sh
taskset -c 15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 julia \
  --startup-file=no --compiled-modules=existing --threads=2,0 \
  --trace-compile=stderr \
  --project=/tmp/classic-jfg-sdk-interrupt-final-v1-installed/julia \
  /tmp/gui-source-allocation-diagnostic-20261006/cold-discriminator/owner.jl \
  > /tmp/gui-source-allocation-diagnostic-20261006/cold-discriminator/owner.stdout.log \
  2> /tmp/gui-source-allocation-diagnostic-20261006/cold-discriminator/compile.log
```

The [evidence directory](evidence/gui-selection-allocation-20261006/original-files.json)
retains exact bounded profiles, trace, concrete type/result, helper source,
owner/harness patches, source receipts and SHA256 provenance (~179KB).
Diagnostic source paths are experiment-specific and are not an operational
entry point. The cold profiler synthetic test passed 4 checks (136 sampled
allocations, three opaque task identities, bounded output). Documentation,
JSON schema/ledger consistency, local links and `git diff --check` were checked;
no Rust rebuild was needed. The strict GUI trajectory/death/duplicate-owner
gates and zero-allocation repair remain separate work.
