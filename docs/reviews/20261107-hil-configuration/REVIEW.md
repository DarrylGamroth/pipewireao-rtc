# Standalone HIL configuration, first supported product

Date: 2026-11-07. This follows the
[prepared runner extraction](../20261107-hil-extraction/REVIEW.md) and the user's
request to run simulation configurations with other RTCs through SPA plugins.
The [configuration guide](../../HIL_CONFIGURATION.md) defines the implemented
scope and compatibility limits.

## Decision and implementation

The existing higher-level instrument/settings resolver remains the cold export
authority. Copying it into HIL would duplicate the compiler. RTC's new public
`InstrumentConfiguration.export_simulation` resolves authoring once into a
portable directory. It reuses existing graph resolution, binding construction
and declared wire-contract validation, writes a standard AOS graph and exact
FITS binding arrays, and verifies HIL's independent reader before publishing the
new directory. Existing destinations are rejected. The original source is not
modified. Shared binding-name and wire-contract queries are reused by the
existing preparation path and the exporter.

HIL's public `Simulation` module owns `Configuration`, `load`, `prepare` and
finite `run!`. There is no RTC import at runtime, no second graph language and
no duplicated numerical executor. Preparation delegates to AOS's public graph,
boundary and model-time APIs. The caller retains admission and link authority;
links use a separate session connection. The runner always closes its transport
on completion, stopped admission or failure.

Schema version 1 supports resolved **lockstep graphs only**. Prepared
external-pupil and clocked-optical execution remain available through the
previous extraction's APIs; their compositions and compiled optical model assets
are not yet supported by this manifest. Unknown modes and compiled optical
assets reject rather than creating host-dependent products. This is an initial
configuration interface, not completion of current-optics configuration or
HEART interoperability.

| Identifier | Meaning and authority | Scope |
| --- | --- | --- |
| `Simulation` / `Configuration` | A configured AOS simulation exposed through HIL; uses existing simulation/configuration terminology | Public HIL namespace and owned input record |
| `load`, `prepare`, `run!` | Read a product, prepare numerical owners, run finite exchanges | Public operations within that namespace |
| `export_simulation` | Resolve existing simulation authoring to that independent product | Public cold RTC operation |
| `schema_version`, `graph`, `hil`, `pipewire` | Product version and the existing AOS graph, HIL boundary and PipeWire transport contracts | YAML boundary; graph syntax remains AOS-owned |
| `bindings`, `path`, `sha256`, `shape`, `eltype` | Named exact array assets and their verified representation | YAML/FITS boundary; logical Julia/FITS dimensions, no permutation |

FITS Bool bindings use exact UInt8 codes 0 and 1; all other supported element
types require exact readback. YAML and asset sizes, collection depth/entries,
shape products and retained arrays are bounded. Duplicate mapping keys, escaping
paths, unknown fields and inconsistent hashes/types/shapes reject before native
connection. The loader retains verified bytes and owned arrays; preparation
copies bindings so later preparations do not share mutable numerical state.

## Independent review

Review found one confirmed P2 defect: an initial portable configuration could
declare a 10 ms model period while its response node advanced 1 ms per step.
AOS explicitly leaves cadence agreement to its caller. The same rejection tests
failed before the fix for both a response and multilayer atmosphere graph.

HIL now dispatches on the public `SecondOrderResponseNodeConfig` and
`MultiLayerAtmosphereOPDNodeConfig` types to validate rounded model nanoseconds
before numerical preparation. Values and coefficients are unchanged. RTC export
also retains its existing exact authored response-period check before exposing
the destination. Nominal SPA rate is independently declared: 30 Hz need not
equal an exactly representable integer or Float32 model period.

Independent re-review closed the finding and independently passed all 53
focused checks. It found no further significant defect in snapshot ownership,
array representation, bounds, relocation, public AOS reuse, authority or cleanup.

## HEART compatibility finding

Read-only inspection used plugin revision
`9aeea5334d03874dcfffc6bc29c8187f2774705a` in
`pipewireao-spa-plugin-heart`. Its `dm-source.c` advertises Header, the retired
monolithic Acquisition and HeartStdDm metadata; `wfs-sink.c` advertises Header
and that old Acquisition. Neither advertises current ReferenceTimestamp.
Its documented UDP protocol does not preserve complete acquisition identity or
exposure facts. Current lockstep HIL requires those facts to correlate commands.

The WFS sink supports raw/packed UInt16 as well as calibrated Float32; it is not
UInt16-only. A detector or intensity output cannot acquire calibrated-pixel
meaning merely by renaming its schema. The command source already converts wire
micrometres to metres, so configuration must avoid another conversion.

These are observed source contracts, not a current-cohort live qualification.
The earlier October bridge evidence predates the compact metadata migration.
No plugin or external RTC source was changed in this changeset. Required
follow-up is a native plugin metadata migration, explicit encoding/unit
selection and a private-core protocol roundtrip. Lockstep correlation must not
be weakened or fabricated to conceal the gap.

## Verification and source cohort

Baselines were RTC `7806be5`, HIL `061d5a6` and AOS `ef40639`. Dedicated worktrees
and branches continue from the extraction. The AOS public input-copy change is
unchanged. HIL's new interface is `915717a` and the cadence fix is `060b350`.
RTC's export is committed as `b846cf3`.
Versions remain development candidates RTC 0.7.2 / HIL 0.5.1 / AOS 0.3.22;
no registration or installed deployment is changed.

Verified software evidence includes 53 focused HIL checks plus Aqua, 19
private-core finite execution/control-teardown checks, and cold RTC export with
numerical equivalence and an independently loaded relocated product. The native
check exchanges three actual correlated buffers through a direct ndarray link.
It does not exercise a HEART plugin. The private-core loop was unchanged by the
cadence fix; its matching 1 ms graph remains accepted by the new checks.

| Gate | Passing assertions |
| --- | ---: |
| HIL standalone configuration and real CPU graph preparation | 53, plus Aqua |
| HIL private-core finite run and control teardown | 19 |
| RTC export, numerical preservation, contract rejection and cold relocation | 18 |
| Existing cold selected optical graph and Preparing/Proper ordering | 17 |
| Full RTC core suite | 11,068 across 514 summaries |
| Documentation links, structure and requirement-ID preservation | 711 |

The final selectors and full core suite exit 0. Concurrent core tests can vary
their assertion count; the summary count is unchanged. The expected missing Git
object rejection diagnostic remains in the core log. The modified Julia files
are formatter-idempotent, with normalized parsed-code equality checked before
writing formatting changes. Final cohort resolution emits no SHA compatibility
warning.

The [verification archive](verification.log.gz) retains commands, generated
cohort Projects/Manifests, source revisions, full output and original failures.
Initial export-test authoring omitted a required calibration graph, then missed
an explicit import of a qualified-public AOS operation; both are corrected test
setup errors. A rejection test initially expected the wrong exception type from
the existing wire-contract validator; its established `ArgumentError` behavior
is retained. The initial formatter invocation selected a depot lacking its
installed formatter; rerunning with that tool environment's depot passed.
A SHA compatibility warning was corrected to `0.7, 1` before final resolution.
The native test initially created links on HIL's connection, which existing
proxy lifetime guards correctly refused to close; the test now gives links
their separate session connection. None of these is claimed as a production
protocol defect or hardware finding.

Checks create no installed application or live user session. They do not
establish hardware correctness, latency, deadlines or full-instrument optical
configuration/HEART qualification.
