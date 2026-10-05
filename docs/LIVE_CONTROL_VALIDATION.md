# Native simulator control validation

Selected contract: [native source controls](LIVE_CONTROL_NATIVE.md),
[RTC-DEV-025/026](operations.md#rtc-dev-025--acknowledged-simulator-admission-and-controls).
Starting RTC revision `57337d6d52db7e23d27a55d58e358995f235b3d7`; worktree
`pipewireao-rtc-live-controls`, branch `work/hil-live-controls-20261005`.
Evidence root: `~/.cache/rtc-live-controls-20261005`.

## Implementation and measurement boundary

Complete-frame simulator pause/resume/reset requests use unchanged native V1
SPA run/reset PODs. Fresh status uses a separately versioned native Props query.
The owner stages bounded scalar requests in the PipeWire callback, applies them
after the matching command is adopted, then publishes the complete retained
status/snapshot set. The client checks the exact node incarnation, owner PID,
instance and request token. Saved JSON reports remain preparation, stopped
reset and final artifacts; pause/status/resume use the live adopted cursor.

The measured interval remains the entire simulator process after the retained
256-frame prefix through final command adoption. Actual midrun pause/status/
resume and held waiting remain included. Counters are not reset or subtracted
around those operations, and ordinary GC stays enabled. Cold preparation,
stopped reset and final report serialization retain their declared exclusions.
These checks do not establish native allocator freedom.

The campaigns use the frozen Classic/Copper simulation, calibration,
graphs, matrices, detector settings, seeds and model period. Staging verifies
342/345 protected files for Classic FGN/JFG and 336/338 for Copper FGN/JFG.
Only source-control, SDK and adapter infrastructure is replaced. Candidate
packages are explicitly labelled development sources, not registered-release
qualification. Their scientific bytes remain unchanged.

## Preserved failure and targeted correction

Installed Classic FGN v7 delivered all 8,192 exchanges and completed native
midrun controls, but failed the inclusive allocation gate with 329,552 bytes
and 6,675 pool allocations. GC counters were zero. It stopped before run 2;
the qualifier retained the failed run and confirmed orderly public shutdown.

Diagnostic v8 reproduced the same allocation counter. Sampling the exact
interval at 0.1 captured 654 allocations and 27,337 sampled bytes, with no
omitted events or truncated stacks. Of these, 653 events/27,313 bytes entered
Julia compilation through PipeWire `remove_mem` callback ABI materialization;
one 24-byte sample came from stream-command POD copying. Sampled bytes are not
an exact allocation census. The diagnostic overlay changes execution cost and
is not a timing or zero-allocation qualification.

PipeWireAO registered those two Julia notifications even when their optional
observers were absent. Native PipeWire has its own memory-removal listener and
applies stream commands before notifying listeners. The correction omits just
these two optional registrations when their callback is `nothing`, preserving
configured observers and mandatory state/error/completion callbacks. The
absent-listener test fails twice before the change and passes twice afterward;
the full PipeWireAO suite passes 2,011 assertions. Independent adjudication and
the Classic FGN before/after evidence are recorded as NC-005 in
[the library review](https://github.com/DarrylGamroth/PipeWireAO.jl/blob/v0.6.16/docs/NATIVE_CONTROL_REVIEW.md).

PipeWireAO 0.6.16 is released and registered, commit
`354512752bc35fd9fe59fe16cc1a0585668107c6`, tree
`09c5b1a7cf7869dcf9c252651e7c9569bf7bcbdb`.
No native ABI or JLL change was required; the SDK retains PipeWireAO_jll
1.7.0+19. Adapter 0.1.1, commit
`0960d980b28db36d0d1d6714f7d75791d1233f37`, is merged into its local main.
That repository has no configured remote; it is not claimed pushed or released.

## Installed lifecycle results

Each lifecycle has an initial run with public midrun stop, two fresh status
queries 100 ms apart and resume, then a stopped reset/restart and second run.
The qualifier checks held-sequence stability, final report readiness, exact
frame/command counts, repeated retained-prefix hashes and owned cleanup.

| Candidate | Exchanges per run | Measured exchanges per run | Inclusive heap/GC | Disposition |
| --- | ---: | ---: | --- | --- |
| Classic FGN v9 | 8,192 | 7,936 | All fields zero in both runs | Pass; held sequence 6,136; cleanup complete |
| Classic JFG v10 | 8,192 | 7,936 | All fields zero in both runs | Pass; held sequence 5,990; cleanup complete |
| Copper FGN v11 | 4,096 | 3,840 | All fields zero in both runs | Pass; held sequence 2,537; cleanup complete |
| Copper JFG v12 | 4,096 | 3,840 | All fields zero in both runs | Pass; held sequence 2,412; cleanup complete |

All four lifecycle records pass. The [sealed evidence](LIVE_CONTROL_EVIDENCE.json)
records each primary lifecycle and summary hash, exact reset-prefix identities,
the two preserved failed allocation gates and the sampled profile identity.
This closes the selected installed source-owner control/allocation gate for
these development candidates. A clean committed-main registered-package run
remains a separate final deployment check.

Registered PipeWireAO 0.6.16 SDK tests pass 1,384 assertions across 63 test
summaries. Focused owner protocol/source/loop tests pass 87/125/18 assertions.
The adapter's actual native-control worktree suite passes 1,280 assertions.
Installed-fixture Git provenance probes emit expected no-repository warnings;
the suites complete successfully. The earlier wrong adapter checkout's baseline
log is retained separately and is not used as evidence for the new hooks.

GPU campaigns are serialized. CPU-only tests share the host and run on CPU 14;
the admitted simulator runs on CPU 6 and deployment verifies its thread
placement. CPU 0/1 are excluded. This is functional and allocation evidence,
not isolated latency, maximum-rate or hard real-time qualification. The simulator
uses a captured CUDA graph; the tested RTC algorithms run on CPU. HIP, physical
devices and GPU RTC algorithm execution are not qualified here.

## Remaining live transports

The simulator source-owner path is native. The public supervisor socket,
supervisor-to-Rust socket, calibration action endpoint and calibration/HEART
owner control/health files still use JSON. This increment does not claim that
those live interfaces have migrated. Saved configuration, scientific plans,
capture manifests, reports and evidence remain distinct from live transport.
The next migration must preserve their typed actions, restoration fences,
causal completions, exact identities and finite failure behavior; encoding JSON
inside a POD would not satisfy the selected native serialization requirement.
