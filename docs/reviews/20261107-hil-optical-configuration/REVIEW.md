# Standalone optical simulation configuration

Date: 2026-11-07. The user selected finishing standalone HIL configuration
before updating the HEART SPA plugins. This completes the optical configuration
surface following the [initial lockstep product](../20261107-hil-configuration/REVIEW.md).
The [maintained guide](../../HIL_CONFIGURATION.md) owns usage and current scope.

## Ownership and source cohort

Work continues in the existing dedicated extraction worktrees. Baselines are
RTC `fd8459d`, HIL `060b350` and AOS `ef40639`. Original checkouts, installed
applications and user processes remain unchanged.

| Responsibility | Owner |
| --- | --- |
| Instrument/settings resolution, physical contracts and binding construction | Existing RTC cold compiler, reused once at export |
| Model numerics, graph construction, detector/exposure behavior and model time | Public AOS interfaces and declared scientific dependencies |
| Independent configuration snapshots, prepared execution, transport options and finite controls | HIL's `Simulation` and `ExternalPupil` modules |
| Native streams, formats, metadata and buffers | PipeWireAO |
| Admission and application links | The caller's separate session connection |

Schema 1 retains lockstep configuration. Schema 2 adds external-pupil and
clocked-optical products containing ordinary AOS graphs, exact typed bindings,
pupil/sensor contracts, exposures, detector responses, chopping selections and
the optional source. No optical graph grammar, numerical executor, session
authority or supervisor is added. The runtime imports no RTC configuration.

Compiled model YAML and declared arrays are copied byte for byte, with original
hashes. Only the generated graph's model reference changes to a portable product
path. HIL retains verified snapshots, confines relative paths and materializes
assets privately during AOS construction and numerical preparation. AOS consumes
their arrays before the temporary files are removed. Repeated preparations
recreate assets and independent mutable graph owners; reused graph keys do not
share detector state or RNGs.

Clocked sources retain host execution. Accelerator optical/response graphs
require capture; runtime bindings are allocated on the selected device while
construction bindings remain on the host. Execution properties are derived from
actual prepared owners, so changing target cannot retain stale CPU/capture
labels. The same public HIL query now serves RTC; duplicated private optical
metadata construction is removed.

Clocked configuration has only its actual command input, not an unused pupil
node name. External-pupil mode requires a pupil node. Public controls remain
serialized `Run`, `Hold` and `Stop` decisions. The finite budget counts actual
source advances across upstream generations; Hold and reset do not count as
frames. Existing signed clocks, model-time chronology, pacing and deterministic
stream teardown are retained. Science stays outside PipeWire callbacks.

## Public interfaces and naming

| Interface | Authority and meaning |
| --- | --- |
| `InstrumentConfiguration.export_simulation` | Existing simulation authoring compiled to an independent product; accepts a transport mapping or YAML filename for schema 2 |
| HIL `AbstractConfiguration` / `OpticalConfiguration` | Typed configurations; the abstract type uses the required prefix and mode markers select handlers |
| HIL `Simulation.load`, `prepare`, `run!` | Existing load/prepare/run vocabulary extended to the two prepared optical modes |
| HIL `ExternalPupil.execution_properties` | PipeWire execution/capture descriptions derived from public AOS queries; shared by standalone and RTC paths |
| AOS `graph_input_contract`, `graph_output_contract` | Immutable cold descriptions of existing graph boundary ports; qualified public interfaces |
| `assets`, `path`, `sha256` | Existing artifact/path/hash vocabulary for copied compiled model files; AOS still owns model parsing |

AOS boundary queries use its own node admission and endpoint checks to return
name, direction, data role, element type, shape, schema and layout. They do not
allocate numerical arrays or prepare owners. HIL does not inspect private
prepared-node layouts or opaque port types. Public exposure schemas and command
schemas are checked against these actual boundary descriptions.

## Review and corrections

Independent review confirmed two P2 defects in the initial implementation:

1. A monotonic configuration produced a realtime pupil input while sensors used
   monotonic time. The public stream-options helper now forwards the selected
   reference clock to the pupil as well; all three supported labels are tested.
2. A source command or detector response could advertise an unrelated schema.
   Before the fix, a source with `test.command/1` accepted
   `unrelated.command/9`; changing both response/sensor labels similarly hid the
   actual detector graph schema. AOS's new public boundary queries now reject
   both cases before numerical preparation completes. No schema is inferred
   from field presence or renamed to conceal an incompatibility.

Primary review also corrected target allocation, host source selection,
generation-change frame accounting and stale execution properties. Final
independent recheck closed both findings and passed AOS contracts, HIL loading,
CPU science and the isolated three-clock execution selector. It found no new
significant issue in this scope. The reviewer ran no GPU or native-core gate;
those results below come from the implementation checks.

## Verification

Julia 1.13.3 was used. The source candidates remain RTC 0.7.2 / HIL 0.5.1 /
AOS 0.3.22. AOS's public contracts are committed as `c058f32f`; HIL's optical
implementation and mode-field cleanup are `6513d0f` and `3bd9742`. RTC's export
and metadata delegation are committed as `42808ff`.

The remaining CPU cohort selects registered FilterGraphs 0.10.0,
FilterGraphAlgorithms 0.12.0, FilterGraphPipeWire 0.5.2, PipeWireAO 0.9.2 /
JLL 4.0.2+0, calibration 0.17.3 and Proper 0.4.1. CUDA used its separate preserved
CUDA 6.4.2 / KernelAbstractions 0.9.45 environment on the RTX 3080; the CPU science
environment uses KernelAbstractions 0.10.5. Exact Projects/Manifests are retained.
These candidates have not been released or registered. Remote AOS main was
`06482bc8` (0.3.21) and no 0.3.22 tag existed when checked.

| Gate | Passing assertions |
| --- | ---: |
| AOS cold boundary contracts | 10 |
| AOS supported API ownership | 45 |
| Full HIL suite at `6513d0f`, including Aqua and native transport/calibration | 3,654 across 11 summaries; main suite 1,512 |
| Final schema-2 parsing and real CPU optical/response/source preparation | 20 + 18 |
| Compiled-model snapshot relocation/tamper checks | 10, plus loader checks |
| Final HIL private-core finite optical controls and cleanup | 12, plus 20 loader checks |
| CUDA captured optical/detector preparation, resident bindings, CPU equivalence and host source | 13, plus loader checks |
| RTC external optical export, seeded/chopped replay, cold export and independent relocated consumer | 54 |
| RTC clocked optical export and independent source-plane oracle | 22 |
| RTC compiled export, exact copied bytes/hashes, relocation and tamper rejection | 20 |
| RTC source/graph export and schema-1 relocation regression | 18 |
| RTC existing CPU capture/exposure/reset regression | 298 |
| RTC existing external-pupil preparation | 100 |
| RTC existing cold optical selection / Preparing-before-Proper | 17 |
| Core package/API optional-dependency boundary | 45 |
| Documentation links, requirement IDs, structure and YAML examples | 738 |

The final mode-field change only selects configuration keys; its parser, CPU
and private-core selectors were rerun. The previous full HIL and CUDA results
remain applicable to unchanged execution and device code. The preceding full
RTC core suite passed 11,068 assertions across 514 summaries. This increment
changes the optional scientific extension and public documentation, so focused
core/package and affected scientific selectors were run instead of repeating
the unchanged full core gate.

RTC's new selectors additionally compare complete seeded/chopped detector
trajectories against the existing owner, source DM rasters against independent
AOS stepping, source bytes before/after export, and relocated products in fresh
processes without RTC or original authoring. A cold exporter process also proves
Proper loads after metadata selection without a world-age failure. The compiled
export selector verifies RTC's copying/path rewriting, not only HIL's reader.
It reuses HIL's tiny model-data writer as development test input, not runtime
implementation; that selector requires matching HIL test sources.

## Evidence and limits

The [verification archive](verification.log.gz) retains source revisions,
cohort Projects/Manifests, selector/formatting scripts and original process logs.
Initial test-authoring errors and review-harness composition errors are kept as
failures with their scope. A CUDA 6.5.1 artifact setup failed; no production
change was inferred from it. The existing working CUDA 6.4.2 environment was
reused with preserved dependencies and the actual device selector passed.

The checks establish software preparation, numerical preservation, configuration
independence, native private-core behavior and one GPU configuration. They do
not establish physical-device correctness, full-instrument convergence,
deadlines, allocation budgets or target-host performance. The HEART SPA plugin
metadata update and actual protocol roundtrip remain deferred; no current
HEART interoperability claim is made.
