# Independent native supervisor codec review

2026-10-06. Reviewed foundation commit
`2a78a3136229d6985615629ace43b595f3974330`, branch
`rtc-native-supervisor`, against RTC-ARCH-024 / RTC-DEV-030 and the
[supervisor contract](NATIVE_SUPERVISOR_CONTROL.md). The independent review
worktree is
`/home/dgamroth/workspaces/codex/pipewire/pipewireao-rtc-supervisor-codec-review`,
branch `review/supervisor-codec-2a78a31`, created from that commit with no
pre-existing changes. The source worktree was also clean when inspected.

No confirmed codec defect was found in this bounded review. The reviewed
foundation can proceed to production integration. This conclusion does not
establish a working public native supervisor, actual nested observation
freshness, installed qualification, or scientific/hardware acceptance.

The review changed only this record and an explicit
[review discriminator](../deployment/julia/test/review_native_supervisor_codec.jl).
No production remediation was applied. The discriminator is deliberately run
separately from `runtests.jl` and does not create a PipeWire core or owner effects.

## Scope and evidence

The source review covered both supervisor codecs, the newly added Julia runner
request decoder, the thin supervisor client, relevant common-envelope and
generic-client validation, reused runner results, HEART/acquisition validators,
and the mutation reply reservation. The Rust and Julia field order, scalar
tags, optional values, unsigned bit preservation and checked byte arithmetic
were compared directly.

| Review ID | Severity | Confidence | Disposition |
| --- | --- | --- | --- |
| NSCR-001 | Informational | High | Verified exact profile and reply correlation; no defect found |
| NSCR-002 | Informational | High | Verified typed schemas and malformed fixture rejection; no defect found |
| NSCR-003 | Informational | High | Verified combined reply reservation for the reviewed schema; no defect found |
| NSCR-004 | Integration gate | High | Open in the reviewed foundation; required before production acceptance |

### NSCR-001 — Exact profile and reply correlation

**Observed:** `SupervisorProfile` advertises
`pipewireao.rtc.deployment-supervisor/1`; it has independent capability names
and delegates to the generic client. Generic `node_info!` checks the selected
profile, owner PID, endpoint instance, serial and global ID. `healthy` monitors
owner/controller identity and removal. `same_request` compares endpoint
instance, full controller identity, token and operation before retaining a
matching reply. Matching re-publications retain the first observation time.

Source evidence:
[supervisor traits](../deployment/julia/src/native_supervisor_codec.jl),
lines 27–37;
[supervisor wrapper](../deployment/julia/src/native_supervisor_client.jl);
[generic client](../src/native_control_client.jl),
`same_request`, `observe!`, `matching_reply`, `healthy`, `node_info!` and
`request!`.

**Validation:** The generic client suite passed 23 assertions. Sixteen
additional supervisor-profile assertions vary controller global ID, UInt64
serial, controller incarnation and token independently; none satisfies the
pending request. A changed endpoint incarnation produces UnknownOutcome.
Identical re-publication preserves the first observation time. A reply recorded
after the supplied deadline is not selected. These are callback/selection
checks, with deliberately supplied observation timestamps.

**Disposition:** No remediation proposed. Actual two-caller admission,
duplicate payload equivalence and endpoint removal belong to NSCR-004. A
decoder accepting an otherwise valid message from another controller is not
an admission decision: the matching predicate must still select that message.

### NSCR-002 — Closed typed schemas and observations

**Observed:** Julia runner request decoding shares request preflight and field
validation with encoding. Parameter decoding accepts an Id Array and checks
shape/type limits without opening its artifact. Property requests retain exact
native scalar tags and reject nonfinite requested values. Successful property
observations preserve floating-point bits, including the fixture NaN.

The supervisor checks phase/admitted consistency, Preparing owner absence,
required admitted runner observation, owned process uniqueness/PIDs, binding
profile and incarnation, positive nested tokens and the runner session ID.
Simulator query token/instance and cursor semantics are checked explicitly;
cold acquisition and HEART semantics match their existing codecs. Full-width
unsigned serials/cursors and optional generations are preserved. The completion
keeps operation-specific Requested, Completed, Active and Submitted outcomes;
parameter submission remains Submitted with an observed generation pair.

Source evidence:
[Julia request decoder](../src/native_runner_codec.jl),
lines 312–350;
[Julia supervisor](../deployment/julia/src/native_supervisor_codec.jl),
`_decode_record`, `_validate_runner`, `_simulator`, `_source_pod`, `_heart_pod`,
`validate_snapshot`, `_completion_payload`;
[Rust supervisor](../src/native_supervisor_codec.rs), the corresponding
binding/record/source/HEART/snapshot validators and completion decoder.

**Validation:** The Julia supervisor suite passed 197 assertions. Rust decoded
and re-encoded the valid shared POD fixtures byte for byte and rejected every
malformed fixture, across 44 fixture files. Cases cover all fourteen requests,
closed result variants, simulator/calibration/correction/HEART observations,
negative completions and independent/sentinel rejection, plus malformed
semantic/type cases.

**Disposition:** No remediation proposed. Positive nested tokens and internally
consistent bindings alone cannot establish fresh native acquisition. Production
must populate these records from actual bound clients within the accepted
deadline, as already required by the contract.

### NSCR-003 — Combined mutation reply capacity

**Observed:** Both implementations measure the complete supervisor snapshot
and reserve the common header, phase/admitted fields and closed worst-case
mutation result. Property generation rows use distinct requested `node:property`
prefixes, with both optional generation values present. Parameter results
reserve the optional generation pair. The bounded failure alternative is also
reserved. Variable runner catalogs are measured before materializing their POD
catalogs. Query overflow rejects rather than truncating the catalog.

Source evidence:
[Julia capacity helpers](../deployment/julia/src/native_supervisor_codec.jl),
lines 347–459;
[Rust capacity helpers](../src/native_supervisor_codec.rs), `snapshot_size`,
`preflight_mutation_reply`, `completion_size` and `encode_completion`.

**Validation:** The existing suites exercise all mutation variants, the exact
64 KiB reserve boundary and one byte beyond the supplied snapshot bound.
The independent discriminator additionally encodes a real completion with all
42 distinct property generation rows, multi-byte UTF-8 names, both generations
present, simulator/HEART observations and a 55,000-byte runner sink name.
The reservation equals the actual encoded completion length. The result
decodes as Active with all 42 rows. A future snapshot bound below the present
snapshot rejects. These five assertions test actual serialization as well as
the helper's arithmetic.

**Disposition:** No remediation proposed for the foundation. A default reserve
uses the current snapshot size. A production caller must supply a proven
future bound when the operation can add an optional value, extend a string or
grow a catalog. The reservation cannot infer those future changes.

### NSCR-004 — Production integration remains an acceptance gate

**Observed:** The reviewed foundation explicitly excludes production
`DeploymentRunner` ingress/coordinator replacement, operator discovery,
CLI/GUI migration and live-file retirement. Its preflight/admission helpers
perform no effects and do not enforce call ordering in an absent integration.

**Required implementation and validation:** Call admission validation and
combined mutation preflight before every mutation effect, including source
coordination that precedes the internal runner command. Prove the future
snapshot bound. Carry the accepted ticket's single absolute deadline through
runner/source/acquisition/HEART operations and synchronization. Acquire nested
Status/query observations freshly from live bound clients; saved locator or
report data cannot supply health. Establish the endpoint before owner startup,
preserve Preparing behavior, and exercise two actual callers, busy/stale/replay,
removal, expiry and post-effect unknown outcomes. Complete CLI/GUI and installed
start/control/cleanup gates before claiming public native migration.

**Disposition:** Remaining work, not a codec defect or a reason to change this
foundation speculatively. The parent integration review must independently
verify these obligations against its final source and actual native tests.

## Reproduction and limits

All review tests ran on CPU 15, Julia 1.12.7, one Julia/BLAS thread, and one
Cargo build job. Cargo reused the shared target; it rebuilt the RTC binary
without creating a dependency target tree.

```sh
JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 taskset -c 15 julia \
  --startup-file=no --project=deployment/julia -e \
  'include("deployment/julia/test/test_native_supervisor_codec.jl"); include("deployment/julia/test/test_native_control_client.jl")'

JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 taskset -c 15 julia \
  --startup-file=no --project=deployment/julia \
  deployment/julia/test/review_native_supervisor_codec.jl

CARGO_TARGET_DIR="$HOME/.cache/rtc-live-controls-20261005/native-filter-target" \
CARGO_BUILD_JOBS=1 \
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
LD_LIBRARY_PATH=/opt/pipewireao/lib/x86_64-linux-gnu \
taskset -c 15 cargo test --locked --offline --features live \
  --bin pipewireao-rtc native_supervisor_codec::tests -- --test-threads=1
```

Final results: 197 supervisor + 23 generic-client + 21 independent Julia
assertions passed; both focused Rust tests passed. The initial discriminator
used a 0.5-second future deadline that compilation consumed; it correctly
received UnknownOutcome and was corrected to use a fresh 60-second synthetic
selection deadline. That fixture issue was not a production failure.

Julia reported the existing loaded/precompiled dependency-version notice.
Cargo reported the existing `proc-macro-error2` future-incompatibility warning.
No connected owner, science, scheduling/resource qualification or hardware
experiment was run. No performance claim follows from these cold codec tests.
