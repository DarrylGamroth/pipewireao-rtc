# Registered RTC packages and FITS artifacts

Approved direction: user instructions and the adjudicated [application review](PIPEWIREAORTC_REVIEW.md), 2026-10-14. This document defines the implementation boundaries and acceptance obligations. Delivery status belongs in the roadmap's **Current work** section.

## Source baseline and preserved state

- Shared package: `8a175c2a3608f74e66571617906d0aa8f8e5f580`, implementation branch `codex/pipewireaortc-implementation-20261014`, separate worktree `PipeWireAORTC-implementation-20261014`.
- The starting README/module changes and `NativeSourceControl` implementation were retained from the original working tree. No unrelated scientific changes are adopted by this migration.
- WirePlumber policy baseline: `d20cd2037fda7b5932b0feb58b0af5aef5226a48`; policy validation is a separate change.
- RTC-ARCH-024/025 and RTC-DEV-030 remain authoritative for transport, session ownership and controls. Renaming does not revise these contracts.

## Package boundary

`PipeWireAORTC` retains UUID `a3e2c7da-f73f-4284-8482-36ac422b34e6`. Reusable configuration, installation, launch and CLI implementation lives under `src/`; root commands only load the package and dispatch. Native codec modules retain their names and records. Existing sealed exports remain a compatibility path, with no claim that an old SDK becomes a small registered application merely by renaming its package.

Scientific algorithms remain in FGA/JFG/AOS/AOC; transport adapters initially remain separate. Cold operational clients must not load CUDA or scientific implementations as mandatory dependencies. Optional integrations must use the parent package's public API and own their concrete integration methods. `Hsm` and `Agent` are deferred by explicit user instruction. Histogram replacement is a separate measured change.

## FITS preparation contract

`Artifacts.FITSArtifact(path; hdu=1, axes=nothing)` identifies one image HDU. HDU indices are one based. `axes` names the FITS NAXIS dimensions in logical owner order; every multidimensional selection requires an explicit permutation, including square matrices. A vector may omit `(1,)`.

`Artifacts.prepare(source, T, shape)` returns a `PreparedArtifact` with an owned logical `Array{T,N}` and provenance. Preparation snapshots bounded original bytes before decoding, validates the selected image and converts exactly where the target is integral or Boolean. Float rounding is allowed; nonfinite values and overflow are rejected. Units are recorded from `BUNIT`; there is no implicit unit conversion. `pack` produces transient little-endian row-major bytes for transport and hashing. It does not create an artifact file.

The original FITS is bounded at 512 MiB and each decoded/target image at 256 MiB. These are per-artifact bounds, not a global application memory guarantee. The cold preparation peak includes the FITS snapshot, decoded image, owned converted image and packed hash buffer. Owners must additionally bound the aggregate retained set. No FITS parsing or allocation belongs in a PipeWire process callback.

An owner validates declarations first, prepares all required arrays before publication, and retains them until the scientific executor has copied or adopted them under its own contract. Cancellation is checked between cold preparation steps. Closing/abandoning a failed preparation must not publish a partially configured owner.

Stored artifacts in the new application are FITS. This does not change native ndarray encoding or the legacy v1 raw-file request semantics. A live FITS update needs an explicit owner/client contract and adoption receipt; changing what a v1 raw filename means is prohibited. Startup FITS support alone does not establish live replacement support.

## Instrument application boundary

The target instrument directory contains Project/Manifest, native PipeWire/RTC graph and session configuration, a simulation graph, FITS artifacts and binding metadata. Optional GUI configuration and reports are separate. Registered packages supply all executable implementation; no copied `src`, tests, scientific package directories or authoring-checkout paths belong in the application.

Classic's exact actuator order, masks, coordinates and prepared-profile provenance must survive the migration. Reusable AOS preparation should accept these declared inputs; `REVOLTClassicSim` is not registered. Publication must retain the early bootstrap Preparing endpoint, cancellation and source-first sequencing. New-framework SPIDERS is an additional declared profile; it does not imply porting the legacy Aeron RTC.

## Delivery coverage and evidence gates

| Review allocation | Required implementation | Acceptance oracle | Closure boundary |
|---|---|---|---|
| RAR-01 / RTC-DEV-030 | Pure malformed-command validation before effects; retain post-effect faults | Same malformed parameter payload faults before and fails without effects after; wrong-arity controls already stay healthy | Isolated Lua policy software checks; no live service qualification |
| AAR-05 / rename | Named package API, source organization, thin CLI wrappers, UUID continuity | Fresh package loading, module identity, focused codec/config/install checks, relocated legacy export loading | New import name requires downstream migration; historical records remain unchanged |
| AAR-02 / RAR-04 | Owned-memory FITS reader and explicit axis/type/extent validation | Non-square and square ordering, numeric boundaries, hashes, image/HDU/axis rejection, no raw files | Cold preparation library; owners/live updates qualify separately |
| AAR-04 | Package-owned scientific owner entrypoints | No dependency `src` includes; Preparing/cancel/cleanup and exact identity checks | Initial Classic JFG profile, then FGN/Copper/SPIDERS separately |
| AAR-06 | Public graph introspection upstream | Catalog equals declared and configured properties/parameter formats; no private layout reflection | Registered immutable scientific API version |
| AAR-03 | Configuration/FITS-driven AOS owner | Exact geometry/order/mask equivalence and deterministic science comparison | Selected backend/preferences preserved; no blanket numerical claim |
| AAR-01 / releases | Registered immutable dependency closure and small application | Fresh-depot instantiate; relocate; no copied code/path dependencies/raw artifacts | Local registry entries must resolve committed source; no dirty scientific release |
| AAR-07 | Additional instrument acquisition identity contract | Frozen v1 Classic/Copper IDs unchanged; explicit SPIDERS profile/capabilities | Generic session support does not imply generic acquisition support |
| RAR-02/03 | Phase-attributed warmup/Quit investigation | Isolated lifecycle traces identify remaining-budget consumption and exact cleanup | Existing failures remain unresolved until discriminating evidence |

For the final application gate, exercise held startup, property control, parameter adoption, cancellation, calibration restoration and exact cleanup on isolated owned services. Software checks, simulation, numerical comparison, resource/latency measurement and hardware validation are distinct evidence. No hardware claim follows from package loading or a successful simulation.

## Review correction

The initial RAR-01 wrong-arity trigger was incorrect: the actual `session.lua` dispatch wrapper catches pre-effect assertions and emits a negative correlated completion without faulting. This protection was present at the audited baseline. Isolated reproduction confirmed it; the review omitted this wrapper. The narrower reproduced defect concerns operation 14 forwarding malformed type/shape fields after marking effects issued. Its remediation validates those fields before `begin`, preserving ticket/token and uncertain-effect handling.

## Independent simulators and RTC definitions

Classic, Copper and GPI 2.0 remain independently deployable instrument packages.
Their Julia builders prepare AOS plants; application TOML selects scientific
inputs and compute placement. The simulation workspace pins released AOS 0.2.1
and AdaptiveOpticsSimPipeWireHIL 0.2.2 without common-package path overrides.
The adapter attaches to the existing prepared HIL boundary. Default development
propagation is CUDA; CPU reference execution is an explicit selection.

An RTC application supplies the ordinary PipeWire `filter.graph` configuration,
its FGN or JFG executor, selected calibration artifacts, and a session declaring
exact endpoint connections, rates and owner/resource policy. Reconstruction,
control and woofer/tweeter/tip-tilt allocation belong to that RTC graph, not the
plant or transport adapter. PipeWireAO supplies scheduling and transport;
WirePlumberAO owns managed admission, links and lifecycle; systemd supervises
processes. Direct isolated-core graph tests do not require a managed session.
Neither the GUI nor the VS Code workspace supplies runtime authority.

The integration path is:

```text
instrument Julia builder -> prepared AOS HIL boundary -> shared PipeWire adapter
    -> WFS data port -> RTC controller graph -> physical-command port
    -> shared adapter -> next plant exposure
```

Matching shapes alone is insufficient. Admit exact schema, element type,
layout, units, command ordering, rate and acquisition identity. The current
Classic boundary is 352 × 352 pixels with 277 commands; Copper is 64 × 64 with
277 commands. GPI 2.0 is 242 × 240 with 2,403 physical-command coefficients:
97 woofer, 2,304 tweeter, then two tip/tilt OPD-ramp coefficients. GPI's default
wire pixels are input electrons, not raw ADC codes; U16 requires an explicit
ADU calibration. Its wire commands are µm OPD and the adapter converts them to
metre OPD. It must not inherit REVOLT's 277-command graph or HEART's 1,810-mode
interface. Use each prepared instrument's `pipewire_configuration` to obtain
its actual wire contract, including the selected detector encoding.

### Ports, properties and simulator panels

Use existing AOS graph port declarations as the scientific authority. Publish
external WFS/command ports and explicitly selected diagnostic outputs through
PipeWireAO; do not invent another simulator port system or duplicate dimensions
and schemas in GUI code. Keep data ports, sparse ndarray parameter ports and
low-rate scalar properties distinct.

Simulator properties should declare type, units, bounds, defaults and update
semantics. Construction settings such as grid size, device, detector encoding,
seed and calibration identity require stopped preparation unless an existing
owner explicitly supports an atomic live update. No control is advertised as
writable merely because a configuration field exists. Accepted live changes are
applied by the simulation owner between completed exchanges, with requested and
adopted state distinguished. Run, stop and reset use the existing native source
and session contracts rather than direct GUI calls into Julia.

Reuse the GUI's generic PropInfo/Props controls, graph panel, ndarray viewer,
WFS overlays and DM views for simulation sessions. A simulator settings/status
panel can group those advertised controls and show compute/fidelity and model
provenance. The scientific declaration owns meaning and capabilities; the GUI
view configuration owns labels, grouping, layout and selected bindings. Rendered
controls must reflect actual native capabilities and readback.

Observation stays optional and non-gating. Publish diagnostic images through
bounded copy/drop-oldest observation exports; attaching, slowing or closing a
panel must not retain required RTC buffers or stop acquisition. Adding metadata
or a view declaration does not implement native properties, diagnostic sources
or session admission.

### RTC-owned operator views

Specify the panel profile while defining each RTC application, beginning with
Classic's managed integration. The instrument package supplies scientific port
contracts, geometry, units and provenance. The RTC application owns the selected
operator-view TOML, referencing its actual graph, observation endpoints and
native controls. The GUI owns rendering, navigation and saved layout. Keep that
configuration optional so the same RTC runs headless.

Use the GUI's [existing operator-view and component-panel contracts](../../pipewireao-gui/docs/component-panels.md).
The current accepted operator-view schema is 11; generate it from the selected
prepared profile instead of copying the older schema-9 Classic example.
Generation can share the existing REVOLT exporter machinery. It must not require
loading GUI code into the scientific or session owner.

The following is the requested panel specification, not a claim that every
listed source or view is implemented:

| RTC profile | WFS panels | Command panels | Additional observations |
| --- | --- | --- | --- |
| REVOLT Classic | SHWFS detector image; calibrated pixels when exported; prepared subaperture overlay with frame-associated slopes, flux and validity | HSDM277 Demanded and Applied; Offset and Shape control when explicitly exposed | Controller residuals and constraint feedback when exported; optional focal image |
| REVOLT Copper | PWFS detector image; calibrated pixels when exported; prepared pyramid-pupil overlay | HSDM277 Demanded and Applied; Offset and Shape control when explicitly exposed | Reconstruction products and constraint feedback when exported; optional focal image |
| GPI 2.0 | PWFS detector image with declared encoding and pupil geometry; calibrated pixels when exported | Separate 97-channel woofer and 2,304-channel tweeter Demanded/Applied maps; two tip/tilt coefficients in a vector view | Allocation/controller residuals and constraint feedback when exported; optional focal image |

Every profile includes the existing Session, RTC graph Controls and PipeWire
Graph panels. A simulation session additionally selects simulator settings and
status: compute device, fidelity, model period/exposure, seeds, preparation and
calibration identities, and the acquisition generation/sequence that the owner
actually advertises. This remains planned native property/panel integration.
Construction-only fields are read-only during execution; live edits require a
writable advertised capability and adoption readback.

Each panel definition identifies the exact source or control binding, expected
schema/type/shape, units, geometry/command order and provenance where applicable.
It also selects presentation group, title and initial visibility using supported
operator-view fields. Keep scientific facts in the owning instrument/RTC
metadata and derive view bindings from them. A title, dimensions or static
actuator map cannot establish a live source, a compatible calibration or write
authority. A configured missing source shows unavailable; extra diagnostics are
included only when the selected graph/backend exports them.

Keep Demanded, Applied, Offset and independently measured residuals distinct.
Applied comes from the simulation owner's adopted-command observation, not from
assuming the controller demand was applied. Shape control needs the actual
engineering-offset parameter, supported shapes and bounds. Displaying an actuator
map does not enable editing. WFS overlays must satisfy their existing acquisition
association contracts; independently advancing samples cannot substitute for a
coherent product group.

GPI component maps come from `GPI2Sim.actuator_index_map`; command ranges come
from `GPI2Sim.command_layout()`. The owner will need bounded component observation
exports for the woofer, tweeter and tip/tilt products, derived from the declared
combined vector without changing its control boundary. Do not assume a new GUI
slice field or component-stream API already exists. Tip/tilt values are OPD-ramp
coefficients with declared units, not automatically milliarcseconds. The two
padding rows in the 242 × 240 GPI frame remain explicitly identified; they are
not qualified camera overscan. A focal image must retain its declared optical
quantity and acquisition provenance rather than acquire a science-camera label.

For each instrument increment, generate and parse the operator-view configuration
with the actual GUI schema, verify source/parameter bindings and geometry against
the prepared profile, and inspect the rendered default layout. Exercise source
loss/reset, slow observation and panel detach/reattach while checking the RTC
continues. Headless lifecycle/closed-loop verification remains a separate gate.
Existing panels can cover the first views; missing simulator controls or GPI
component exports are implementation work with their own acceptance evidence.

### Current verification boundary

The shared private-core simulator checks exercise GPU preparation, actual wire
payloads, command scaling/adoption, acquisition identity and deterministic reset.
Their controller peers are transport tests, not reconstruction/control graphs.
Existing Classic/Copper session evidence retains its exact historical package
closure. GPI 2.0 needs its own controller graph, calibration and physical-command
allocation before full RTC-loop qualification can be claimed. The shared AOS
owner's retained TOML/FITS application route is separate from the independent
instrument packages' Julia builders; dependency compatibility does not by itself
migrate those applications or provide a managed instrument-owner entrypoint.
