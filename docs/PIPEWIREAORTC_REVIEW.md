# PipeWireAORTC application review and disposition

Date: 2026-10-14 (America/Vancouver). Status: source review complete; production
remediation, package renaming and registration have not started.

Two independent Astra passes reviewed application architecture/organization and
runtime correctness/library reuse. The primary agent checked significant findings
against source and adjudicated them below. This document is the entry point;
detailed evidence, file/line references, versions and coverage are in:

- [Architecture and organization review](reviews/20261014/ARCHITECTURE_REVIEW.md)
- [Runtime and library reuse review](reviews/20261014/RUNTIME_REVIEW.md)
- [Source/dependency inventory](reviews/20261014/INVENTORY.md)
- [Scope, decisions and preserved working state](reviews/20261014/SCOPE.md)

## Conclusions

The shared Julia application should become `PipeWireAORTC`. Its public API
should validate instrument configuration, prepare registered scientific owners,
launch/inspect/control an explicitly selected session, and drive calibration
acquisition. Package code remains in Julia's depot. Instrument projects contain
Project/Manifest, native PipeWire/RTC configuration, the selected simulation graph,
FITS artifacts and their binding metadata. Optional GUI views and generated
reports do not become headless launch prerequisites.

WirePlumber retains session lifecycle/admission authority; systemd retains process
supervision. JFG/AOS/FGN retain scientific execution and owner-local adoption.
The reviewed Rust GUI is already an independent native client. A package rename
must not recreate a Julia session coordinator or change native v1 records.

The ownership relationships to preserve are:

```text
Instrument environment + graphs + FITS
                   |
                   v
          PipeWireAORTC API ---- process configuration ----> systemd
                   |                                         |
                   | native requests                         +--> scientific owners
                   v                                         |
GUI/CLI ------> WirePlumber <---------------------------------+--> WirePlumber
              session authority
                   |
                   +---- admitted native actions ----> scientific owners
                                                       (JFG / FGN / AOS)
```

Scientific owners exchange typed arrays through PipeWireAO. FITS decoding,
configuration validation and package resolution happen outside frame callbacks.
Decoded arrays and transport packing buffers are transient owned memory; the
persistent scientific artifacts are FITS. These are distinct boundaries.

## Adjudicated findings

P1 architecture findings block the user's requested deployment model; that
priority does not imply a demonstrated safety or runtime failure. Source-derived
correctness behavior is distinguished from executed reproductions.

| Finding | Primary disposition | Action and evidence boundary |
|---|---|---|
| **RAR-01: pre-effect request validation faults a healthy session** | **Confirmed source defect; fix first** | Wrong command arity asserts in WirePlumber session dispatch; the ingress catch calls fault, which holds the source and withdraws links. This contradicts RTC-DEV-030's malformed-command rejection rule. Source and selected installed policy match. No new runtime reproduction was performed. |
| **AAR-01: deployment/installer requires copied SDK source and path dependencies** | **Accepted required redesign** | Both shared and instrument exporters copy code; runtime validators require that copied layout. Replace the export/install contract together with registered dependency resolution. This reflects the changed user target; the former source-copy design was deliberate. |
| **AAR-02 / RAR-04: FITS authoring still produces mandatory raw runtime files** | **Accepted required redesign; one work item** | Existing FITS preparation writes packed files, and startup/live parameter readers expect them. Introduce cold validated memory preparation and explicit live-update compatibility. Preserve typed wire encoding; do not silently reinterpret a raw-file v1 request as FITS. |
| **AAR-03: simulator requires instrument code and fixed extents** | **Accepted required redesign** | Classic/Copper imports, detector dimensions, boundary names and 277-command assumptions remain in owner code. Move presets/exact geometry/order/masks to configuration/FITS; generalize reusable preparation against scientific declarations. Do not register REVOLTClassicSim or move its entire implementation into AOS. |
| **AAR-04: dependency source inclusion bypasses package interfaces** | **Accepted interface defect** | Owners include dependency src files under new enclosing modules, coupling paths and creating distinct type/function identities. Replace with package-owned cold entry points, preserving early Preparing publication and cancellation. No cross-module dispatch failure was executed. |
| **AAR-05: install/launch/config implementation is outside the package API** | **Accepted API/organization improvement** | Root scripts hold reusable implementation and are included by pathname. Move implementation under src and provide callable package APIs; retain thin CLI wrappers and exact error/exit behavior. |
| **AAR-06: catalog reflects private PreparedGraph layout** | **Accepted bounded compatibility gap** | Add narrow scientific introspection upstream; use public declarations/format/property accessors. The present catalog is not demonstrated incorrect. Preserve defaults versus configured values and startup versus live capabilities. |
| **AAR-07: acquisition v1 only identifies Classic/Copper** | **Accepted general-instrument capability gap** | Preserve frozen v1 IDs. Define how a new-framework SPIDERS acquisition owner declares identity/capabilities before claiming generic calibration support. Ordinary session startup and this richer acquisition profile are distinct. |
| **RAR-02: Quit deadline exhaustion** | **Open investigation; preserve CTW-02** | A single five-second internal budget covers multiple phases; a recorded run expired. The consuming phase remains unknown. Instrument phase progress and remaining budget before changing behavior or deadlines. Later cleanup is not proof that Quit succeeded. |
| **RAR-03: warmup timeout attribution** | **Open investigation; preserve CTW-01** | Trace submission/receipt/publication/callback/decode/match for an exact token. Cold compilation, scheduling and transport explanations remain hypotheses. |
| **RAR-05: source v1 duplicate payload equivalence** | **Deferred contract clarification** | Same kind/token preserves the original outcome even if requested Run state differs. Current policy uses fresh tokens, and newer cold-owner duplicate rules do not automatically apply. Establish the authoritative v1 contract before changing this intentional behavior. |

The primary source check independently followed RAR-01 from
`wireplumber/src/scripts/ao/session.lua:450` through
`src/scripts/lib/ao-session-control.lua:177` to session fault/hold/withdraw at
`session.lua:180`, and compared it with RTC `docs/operations.md:745`.
It also checked SDK-copy validators, raw-file preparation, source includes,
private catalog reflection, the Classic/Copper enum, and the existing duration
histogram implementation. Specific preservation/compatibility checks remain
required during remediation.

## Filenames, organization and public interfaces

Group files by responsibility. Keep existing protocol types and module bindings
initially; moving files does not require renaming every externally used type.
The proposed physical layout is:

```text
src/
  PipeWireAORTC.jl      # package entry point and curated API
  cli.jl               # argument/report translation
  configuration/       # native config validation and realization
  deployment/          # preparation, installation, systemd units and cleanup
  native/              # envelope, codecs, transport, profiles and discovery
  owners/              # cold bootstrap and reusable owner entry points
  artifacts.jl         # FITS selection, validation, provenance and memory ownership
  acquisition.jl       # calibration action sequencing; estimators stay in AOC
  session.jl           # selected-session client API
```

Move root `wireplumber_*.jl` implementation under the relevant src groups. Shared
file/process helpers should follow their actual ownership; do not create more
forwarding modules or speculative abstractions merely to shorten filenames.
Keep native protocol conformance data under test/data. Retain the legacy sealed
SDK launch path until the new application path has independent validation.

Existing `NativeControlClient.Profile` and owner connection hooks are justified
extension seams. Reuse them. New instruments generally need configuration and
validated scientific declarations, not a mandatory abstract Instrument type or
an alternate lifecycle backend trait. Artifact readers and graph introspection
need clear public contracts with owned values; their details belong in a
reviewable design before implementation.

`native` is meaningful at the wire boundary. The complaint is addressed by a
small public API and excluding implementation from deployments, rather than
mechanically removing that word from every private file.

## Package grouping decisions

- **Proceed with the PipeWireAORTC name** for the existing shared Julia package.
  Check registry identity and downstream manifests, retain UUID continuity, and
  migrate Project/module/imports/commands/documentation as one coherent release.
- **Keep scientific math/execution packages independent:** FGA, JFG, AOS and AOC
  have reusable transport-neutral responsibilities. AOC is already registered
  through 0.17.0 in the installed Local Registry.
- **Revise the earlier immediate adapter-merge recommendation.** FGPW owns graph
  adaptation, captured feedback, layouts and borrowing; AOS HIL maps exposures
  and model-time metadata to PipeWire and preserves AOS-owned frame/command
  causality. Keep these conceptual APIs and initially
  retain separate adapters. Removing source copies does not require merging them.
- **PipeWireAO extensions remain an option**, after specifying parent-owned public
  APIs, concrete type ownership, optional-load behavior and compatibility cases.
  A merge should be an independent change with evidence, not part of every other
  migration at once. Do not force AOS/CUDA into cold operational clients.
- **Remove the REVOLTClassicSim runtime dependency through separation**, with
  exact configuration/artifacts and narrowly reusable AOS code. Registration is
  not the remedy for that instrument coupling.

## Reuse of the user's Julia packages

| Package | Decision | Concrete use or reason |
|---|---|---|
| **HdrHistogram** | **Scoped adoption candidate** | Replace existing sustained-metrics duration buckets. Use fixed bounds and owner-local writes; merge/query after quiescence. Preserve or explicitly version 10 μs interval reporting, overflow, extrema, warmup and deadline-miss populations. Compare memory, precision and integrated cost before claiming a benefit. |
| **Hsm** | **Defer; owner-local only if justified** | Potentially useful for a complex owner protocol/calibration state machine. It does not supply cross-thread serialization, token correlation or Unknown recovery. Preserve WirePlumber's authority. Working orthogonal-region changes are not a reviewed released dependency merely because Project still says 0.3.1. |
| **Clocks** | **Narrow optional reuse** | Typed injectable monotonic clocks can improve deadline tests. Existing clock helpers have no demonstrated precision defect. Preserve process clock domains, units and remaining-budget semantics; avoid a global cached clock service. |
| **Agent** | **Defer** | May simplify an actual owner duty loop. Preserve sticky thread placement, GC safepoints, wakeup races, fault propagation and absolute shutdown budgets; a cooperative stop or repeated wait is not a total deadline. |
| **StaticKV** | **No current adoption** | Existing protocol structs cover the fields. It does not provide transactional/concurrent publication or adoption evidence; its Clocks compatibility also needs attention. |
| **RtcFramework** | **Do not adopt for this application** | Brings Aeron/Hsm lifecycle machinery and an older dependency cohort that conflicts with the selected native PipeWire/WirePlumber architecture. |
| **SnowflakeId** | **No current adoption** | Existing session UUIDs, incarnations and monotonic request tokens already establish identity. Distributed IDs add clock/node/sequence assumptions without fulfilling a missing requirement. |
| **TimerWheels** | **Defer; source/API review incomplete** | Located registry metadata, not a source checkout or installed release. Existing authority-owned timers suffice for the inspected operation count; no verified Julia API fit is asserted. |

HdrHistogram is a concrete implementation reuse opportunity, not permission to
add an unbounded collector or GUI reads of mutable counters. No package's
advertised allocation/performance claim substitutes for measurement of the
integrated RTC path. Detailed version, dependency and concurrency notes are in
the runtime report.

## Ordered implementation and evidence gates

1. **Fix the confirmed command-validation defect.** Establish the same malformed
   request failing before and rejecting safely after, while preserving post-effect
   fault/Unknown handling. This is a distinct WirePlumber change.
2. **Define the registered package API and owner/artifact contracts.** Specify
   importable cold owner entry points, prepared-memory lifetime, FITS selections,
   startup versus live update capability and a native v1 compatibility strategy.
3. **Fill upstream gaps and extract generic owners.** Public graph introspection,
   exact FITS geometry/order and reusable AOS preparation precede a portable
   Classic owner. Resolve acquisition identity for additional instruments without
   renumbering v1 records. Qualify a bounded initial profile, then expand coverage.
4. **Rename/reorganize and register immutable package releases.** Use reviewed
   committed source snapshots, not dirty working trees. Keep optional science
   integrations out of the cold core dependency closure. Decide the selected
   native PipeWire/WirePlumber binary/JLL installation identity independently.
5. **Build a genuinely small Classic application.** Fresh-depot instantiation,
   relocated configuration/FITS loading, exact array/order equivalence, no copied
   source/tests, no path dependencies/authoring checkout paths, and no persistent
   raw artifact files. Preserve simulation graph/backend/preferences. Do not claim
   FGN parity until its selected host's memory parameter path is verified.
6. **Run isolated application and science gates.** Exercise held startup, controls,
   cancellation, adoption, calibration restoration and exact cleanup on owned
   services. Trace CTW-01/02 before claiming reliability. Validate numerical
   preservation independently; new-framework SPIDERS and Copper need their own
   declared profiles. Legacy SPIDERS implementation is not a migration target.
7. **Evaluate HdrHistogram and optional adapter consolidation separately.** Use
   precision/overflow oracles and measured integration costs. Consider Hsm, Agent
   or extensions only against an actual demonstrated simplification and contract.

Future validation includes pure software, native process integration, deterministic
simulation, allocation/load/latency measurements and physical hardware checks at
their respective scopes. None was performed by this review. Existing services,
user changes, sealed packages and registry entries were preserved.

## Coverage and limits

The two Astra reports and inventory cover the scoped application and its owner/
client boundaries. The review is comprehensive at the application architecture
and source-contract level; it is not exhaustive verification of every scientific
kernel, GUI visual interaction, callback interleaving or hardware behavior.
No test suite, runtime reproduction, benchmark, registration or deployment action
was run. The static hotspot scan supplied navigation signals only. A container
renderer pull was attempted for documentation and rejected by its registry with
HTTP 403; this report uses plain text ownership/layout diagrams and introduces
no unrendered Mermaid diagrams.
