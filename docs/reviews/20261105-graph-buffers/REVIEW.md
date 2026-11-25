# Physical-offset graph buffer negotiation — 2026-11-05

Baseline: clean `45f46a4` on `codex/julia-session-policy-20261104`, worktree
`pipewireao-rtc-cleanup`. The original checkout and running applications were
preserved. This investigation closes the software gate previously blocked in
the [clock evidence](../20261105-clocks/REVIEW.md#clk-06-physical-offset-host-chronology).
That historical failure record is unchanged.

## Findings and disposition

**BUF-01 — confirmed test declaration defect; high confidence; fixed.**
`test/physical_offsets_private_core.jl` constructed its PipeWireNode without
`input_metadata` or `output_metadata`. FilterGraphPipeWire defaults these frame
ports to Header-only support. The connected HIL streams require AcquisitionIdentity,
ExposureTiming and ReferenceTimestamp records as well. Native buffer negotiation
intersects the advertised records, then verifies each peer's original required
records. The missing custom records cause `-ENOTSUP` before any frame processing.

The native trace shows a compatible 8-byte payload, two buffers and MemPtr/MemFd
support, followed by a metadata intersection containing only Header (32 bytes)
and `allocating -> error ... Operation not supported (-95)`. Source review found
the corresponding required-record rejection in native `src/pipewire/buffers.c`,
`check_required_metas`. This is a contract rejection rather than evidence of
heap exhaustion or a host-clock failure.

The graph now declares the existing required acquisition profile on `residual`,
`compensated` and `physical`, using Common.telemetry_metadata_ports. The algorithm's
existing residual provenance governs both outputs. Parameter Ports are unchanged.

**BUF-02 — confirmed test classification declaration defect; high confidence;
fixed.** Once BUF-01 was repaired in a temporary copy, all four scenarios ran:
143 assertions passed and four SCC-tap assertions failed. Each expected electrical
LOW but received ABSENT. The test supplied LOW without declaring the separate
electrical-trigger record. HIL publishes only declared, negotiated records.

The SCC sender and tap now require that record. The test's SCC receiver advertises
optional support through its cold public stream-options record. Every other
option field is preserved. RTC-DEV-037 physical-offset admission does not require
electrical polarity, so production receiver requirements were not tightened.
The unused numeric version column in the test specifications is replaced by the
actual metadata profiles. All original scientific, identity, timing, failure and
classification assertions remain intact.

**BUF-03 — confirmed validation-selector documentation defect; high confidence.**
The imported HIL private-core helper selects its daemon with
`PIPEWIREAO_HIL_TEST_PREFIX`, defaulting to PipeWireAO_jll.artifact_dir. It does
not read `PIPEWIREAO_PREFIX`. Client JLL preferences select libraries separately.
The investigation explicitly exercises both daemon selections below. The original
failure also reproduces with the matching command-endpoint SDK, so daemon
selection is not the cause of BUF-01. Repository validation guidance is corrected
with that distinction.

## Verification

Julia 1.13.3; four default threads, no interactive threads. Optional environment:
`/tmp/pipewireao-rtc-optical-types-env`.

| Component | Selected source/cohort |
| --- | --- |
| RTC | Baseline `45f46a4` plus the reviewed test patch |
| PipeWireAO | `PipeWireAO-command-endpoint`, `bbb7a43` |
| FilterGraphPipeWire | `JuliaFilterGraph-command-endpoint`, `07f08a9` |
| Native SDK | `/tmp/pipewire-command-endpoint-native4-sdk-20261104`, source `c34dc252b` |
| Registered daemon | Artifact `0e8228b168a266b5414800f73b12194c4da1beea` |

The validation environment remains unchanged. SHA-256:

```text
Project.toml          fcbd5b735eaec9e322b75b96b66e5a3808cd3e8670bf417b75143d262b6110e9
Manifest.toml         b5770921c78a577b2fddea6a1d951f66d346ec7cc1ea6a0b8f46b50fa2ebe9a1
LocalPreferences.toml 4fa2850c041e5cce9406093a128655406247759f2e01584932b011c6ee263cbd
```

Client library preferences select the command-endpoint SDK. With the original
test declarations, both the default artifact daemon and matching SDK daemon fail
with `-95` before the first frame. Adding graph metadata alone removes that error
and exposes BUF-02. With both declaration fixes, **147/147 assertions pass** on
each daemon selection. The scenarios cover silence, disconnect, unrelated pending
calibration and mixed pending calibration; physical/compensated outputs remain
paired and primary frames remain independent of calibration packet arrival.

Matched SDK command:

```sh
PIPEWIREAO_HIL_TEST_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104 \
julia --startup-file=no --threads=4,0 \
  --project=/tmp/pipewireao-rtc-optical-types-env test/physical_offsets_private_core.jl
```

Unsetting `PIPEWIREAO_HIL_TEST_PREFIX` selects the artifact daemon in the same
environment. The recorded runs also set `PIPEWIREAO_PREFIX` to the SDK; the HIL
helper ignores that variable. No native allocator or production implementation
was modified. Independent source review found no material issue in the patch and
verified that no existing assertion was removed or weakened. JuliaFormatter
2.14.8 is idempotent and preserves parsed syntax/literals; whitespace checks pass.

Local logs:

- `/tmp/rtc-graph-buffer-repro-20261105.log` and
  `/tmp/rtc-graph-buffer-original-daemon-20261105.log`: original artifact-daemon failure.
- `/tmp/rtc-graph-buffer-original-matched-20261105.log` and
  `/tmp/rtc-graph-buffer-original-matched-daemon-20261105.log`: original SDK-daemon failure.
- `/tmp/rtc-graph-buffer-declared-20261105.log`: graph-only repair, 143 passes/four
  classification failures.
- `/tmp/rtc-graph-buffer-fixed-matched-20261105.log`: SDK daemon, 147 passes.
- `/tmp/rtc-graph-buffer-fixed-artifact-20261105.log`: artifact daemon, 147 passes.
- `/tmp/rtc-graph-buffer-format-20261105.log`: formatting/syntax verification.

These are isolated private-core functional checks. They do not establish hardware,
scientific calibration, sustained cadence, latency, allocation budgets or strict
real-time qualification. No live daemon, instrument, device or dependency source
was changed. The full core suite was not rerun for this optional test-only change.
