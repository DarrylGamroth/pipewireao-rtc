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

## Integration in progress

Recipe YAML selects existing prepared channels and a payload limit. Owner
preparation binds their authoritative formats/schemas, without inferred
instrument-specific dimensions. The acquisition sink's role-based type ordering
is removed; its model-time interface accepts explicit native identity/start/
duration rather than importing AOS. Generic transport and YAML selectors pass;
private-core and owner integration evidence will be recorded with that slice.

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
