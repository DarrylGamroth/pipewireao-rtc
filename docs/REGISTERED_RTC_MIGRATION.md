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
