# Generic finite calibration capture — 2026-11-06

Started at clean RTC `94ecd39`, branch `codex/julia-session-policy-20261104`,
dedicated worktree `pipewireao-rtc-cleanup`. The user approved a generic capture
interface with instrument choices in YAML, existing port/metadata contracts and
verified commits. Instrument source remains declarative. No live application or
instrument source is modified.

## Ownership and interface decisions

The RTC's dedicated `CaptureFiles` module owns finite calibration evidence
writing/reading. It reuses PipeWireAO's ndarray formats and metadata but does not
add persistence to that transport package. It owns no live acquisition,
scientific interpretation, new daemon or continuous recording service. The
existing acquisition owner retains native request correlation, cursors,
deadlines and unknown-outcome fencing. Continuous archiving remains deferred.

`Channel` binds a prepared `NdArrayFormat` and semantic schema; `Contract` binds
selected named channels and derives bytes with `payload_size`. Channel names are
bounded safe port identifiers, with at most 16 channels and native signed-Int32
buffer size per channel. Existing codecs support row-major UInt16, Float32 and
Bool arrays of rank one/two; broader encoding support is not implied.

`CaptureStore` requires that contract. The schema-5 writer persists selected
channels from completed acquisition snapshots without a Classic profile,
geometry or WFS quality policy. Cumulative reservation before effects,
failed-request charging, native receipt validation, file/path bounds, hashes,
fresh deadline checks and immutable final publication are preserved.

The reader requires the expected prepared contract, including schema and rate.
Historical schema 4 is available only through explicit `Val(4)` dispatch, with
frozen type/shape and quality checks in `legacy.jl`. That format did not record
schema/rate and cannot establish those facts. Both versions share the same
parsing, bounded I/O, hash, receipt and cursor validation path. Generated
historical data identifies frozen writer `94ecd39` and its regeneration script;
it is not manually authored output.

## Writer/reader verification

Julia 1.13.3. The standalone contract suite passes 278 assertions, including
arbitrary names, subsets, changed geometry, wrong schema/rate, budget,
interruption, malformed metadata, corrupt payloads and explicit historical reads.
Root's combined scalar/contract check passes 367 assertions in
`/tmp/rtc-capture-files-focused-20261106.log`. JuliaFormatter 2.14.8 preserves
syntax/literals and is idempotent. Independent read-only source review found no
blocking defect in immutability, arithmetic, metadata correlation, selection,
path/hash checks or publication. Its incorrect exposure-bound diagnostic was
corrected; root review also removed duplicated reader control flow.

## YAML, owner and native transport integration

Recipe YAML selects existing prepared channels and a payload limit. Owner
preparation binds their authoritative formats/schemas, without inferred
instrument-specific dimensions. The acquisition sink's role-based type ordering
is removed; its model-time interface accepts explicit native identity/start/
duration rather than importing AOS. Ordinary Collect retains its complete output
cohort; only persisted channels are selected. Runtime budget overrides can lower
the YAML limit, never increase it. Named command provenance has dispatch for
single and named projections. No Classic identity check remains in new capture
preparation. Scientific measurement selection and intrinsic validity retain their
calibration semantics outside the writer.

| Gate | Passing assertions | Log under `/tmp/` |
| --- | ---: | --- |
| Recipe YAML/validation order, no science loading | 44 | `rtc-generic-capture-yaml-20261106.log` |
| Actual prepared Pyramid port binding, quota overrides and named commands | 109 | `rtc-generic-capture-named-verified-20261106.log` |
| Generic acquisition slots/metadata/deadlines without AOS | 152 | `rtc-generic-capture-transport-20261106.log` |
| Real private-core transport, subset publication/readback and identity fault | 173, including the 152 above | `rtc-generic-capture-private-core-final-20261106.log` |
| Capture files/transport inside isolated core-test modules | 430 | `rtc-generic-capture-isolated-modules-20261106.log` |
| Complete core suite | 11,032 in 513 testsets | `rtc-generic-capture-core-final-20261106.log` |

The native gate reorders the source declarations, persists only YAML-selected
`validity` and `flux`, derives their formats/schemas from declared ports, checks
the exact 20-byte two-frame budget, verifies immutable metadata/payloads through
the reader, then rejects a real-link generation mismatch. The collector still
acquires all four channels. It uses three default threads plus one interactive
thread and owns/closes only its temporary core.

### Reference-timestamp source support

Initial native attempts failed during buffer allocation (`-ENOTSUP`) with both
the core package environment and matching command-endpoint source environment.
The existing NdArraySource advertises Header, AcquisitionIdentity and
ExposureTiming but not the ReferenceTimestamp required by the capture sink.
These source declarations cannot negotiate the complete sink requirement.
Original failure logs remain `rtc-generic-capture-private-core-20261106.log` and
`rtc-generic-capture-private-core-matching-20261106.log`.

PipeWireAO commit `bc13c14` on dedicated branch
`codex/capture-reference-metadata-20261106`, worktree `PipeWireAO-capture-metadata`,
adds optional ReferenceTimestamp advertisement and an explicitly supplied
`submit_array!` timestamp. It copies the supplied immutable fact under existing
ownership/locking and writes it within the existing buffer lease. Omission stays
absent, including on buffer reuse; no clock or reference fact is fabricated.
Native SDK code and ABI are unchanged. The focused upstream suite passes 202
assertions, including exact REALTIME/TAI/high-UInt64 preservation, default clearing
and 0-byte warmed copy-path checks (`ndarray-capture-metadata-unit.log`).

The passing native capture uses this exact source through a fresh
`/tmp/rtc-generic-capture-env-20261106` copied from the prior optional environment
and resolved with Pkg, plus explicit
`PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104`.
No existing environment or published registry is modified. The successful command
stacks the RTC environment for its direct clock dependency:

```sh
PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104 \
julia --startup-file=no --threads=3,1 \
  --project=/tmp/rtc-generic-capture-env-20261106 \
  -e 'push!(LOAD_PATH,pwd()); include("test/test_calibration_capture_private_core.jl")'
```

### Review and remaining qualification

Independent source review found no integration blocker in YAML/format binding,
quotas, native admission ordering, named provenance or model-time conversion.
Root review then aligned the owner's generic output type/rank validation with the
collector's supported set. Selected scientific measurements still require their
declared Float32 contract. The full Classic capture selector is migrated to the
new reader/contract, but requires a freshly exported capture-enabled application
and is not claimed rerun against the unchanged older application. Software
private-core evidence does not establish full-instrument science, hardware or
deadline qualification.

The first core run stopped because the extracted capture test helper used a bare
`include` inside an isolated test module. It is corrected to explicit
`Base.include(@__MODULE__, ...)`. The transport selector, now independent of AOS,
is added to the core suite. The original failure remains in
`rtc-generic-capture-core-20261106.log`; final core results follow separately.

The corrected full core process exits 0 with 11,032 assertions. Its deliberate
invalid-object Git test emits the retained `git cat-file` diagnostic; no core
warning or test failure remains. The isolated module check separately passes 430
assertions. Formatting/syntax/literal and idempotence checks cover the changed
Julia integration files. Documentation checks preserve requirement identities,
links, fences and whitespace. Source and validation are committed in reviewable
slices; no package or registry release is implied.

## AOS ownership recheck

Independent source review rechecked both scientific transfers against current
callers. Measured-influence sampling prepares a simulated mirror's dimensionless
OPD response columns; acquisition, fitting, FITS and admission remain elsewhere.
Detector frame layout completes the simulated detector/ADC chain. The real
measurement frontend uses FilterGraphAlgorithms, whose existing pixel
calibration/extraction algorithms do not replace simulated padding/ADC conversion.
The current AOS ownership is appropriate. No current hardware-only caller was
established. If that changes, evaluate shared array-algorithm ownership there;
do not make physical acquisition depend on a simulator merely for convenience.
