# RTC streamlining — 2026-11-06

Started at clean `463e39c`, branch `codex/julia-session-policy-20261104`, dedicated
worktree `pipewireao-rtc-cleanup`. The user approved the remaining cleanup review.
Optional workstation feature retirement remains a separate scope choice; current
features and active scientific/instrument contracts are preserved.

## Legacy export-input retirement and current guidance

Removed `legacy_export_input` from deployment validation together with the
marker-only owner shapes, marker-name validation, conflict sets and request-file
staging checks used only by that mode. Every new application must declare its
current native owner protocols. Exact protocol identities and required native
bootstrap/source checks remain. Earlier conversion evidence and old sealed
applications retain their original scope and tools.

The root version guard and deployment guide now require Julia 1.13, matching
Project compatibility. Current README ownership/installation text describes
Julia MediaSession, public PipeWireAO interfaces and registered application
dependencies; the resource docstring describes package-relative lookup.

Verified with Julia 1.13.3 and the explicitly selected PipeWireAO artifact prefix:
556 assertions in 37 testsets pass in
`/tmp/rtc-streamline-admission-20261106.log` (exit 0). Selectors cover auxiliary
sources, registered applications, instrument export/profiles, session
configuration and package entrypoints. The auxiliary-source suite includes
rejection of each old marker field and a complete old marker-only declaration.
JuliaFormatter 2.14.8 preserves syntax/literals and is idempotent for all three
changed Julia files (`/tmp/rtc-streamline-format-20261106.log`). No core, owner or
service was launched. No deployment or instrument source was rewritten.

## Measured-influence scientific ownership

AOS commit `8f7f09bc`, dedicated branch `codex/rtc-scientific-ownership-20261106`
in `AdaptiveOpticsSim-rtc-ownership`, adds the transport-neutral public
`Optics.resample_measured_influences`. Its glossary and docstring define the
source-grid coordinates, full-square bilinear sampling, physical-command columns,
signed reference command, OPD scaling and Float32 output. The interpolation
expression and evaluation order are preserved. AOS version 0.3.20 owns the new
interface and Interpolations dependency; no registry or release was published.

RTC removes coordinate construction and interpolation, and its AOS-only extension
calls that interface after artifact admission. FITS path/hash/HDU/axes/type/shape
checks, storage bounds, identity-registration admission and provenance remain in
RTC. The cold extension call uses `invokelatest` because explicit optional science
loading can occur within the same preparation call. Missing AOS fails clearly;
there is no numerical fallback and HIL is not required. RTC weak compatibility
now requires the receiving AOS 0.3.20 API. The package environment is regenerated
with Pkg; removing Interpolations eliminates 14 entries from its current manifest
closure. Application/instrument pins are not rewritten.

Verified with Julia 1.13.3:

| Gate | Passing assertions | Log under `/tmp/` |
| --- | ---: | --- |
| AOS core optics, including sampler | 1,352 | `aos-rtc-core-optics-tests.log` |
| Standalone AOS sampler | 47 | `aos-rtc-measured-tests.log` |
| Exact comparison against frozen RTC `463e39c` coordinate/interpolation code | 48 | `aos-rtc-sampler-equivalence.log` |
| RTC artifact admission without AOS | 16 | `rtc-influence-admission-20261106.log` |
| Original RTC FITS/provenance tests plus late AOS load and no-HIL checks | 43 | `rtc-influence-science-final-20261106.log` |

The comparison covers Float32/Float64 cubes, square/rectangular source grids,
resolutions 1/2/3/8, physical-command permutation and signed reference commands.
All compared matrices are exactly equal. New scientific tests also cover views,
source precision, boundary coverage and invalid/nonfinite inputs. Root source
review checked coordinate signs, scaling, interpolation order and retained input
admission. The first AOS core-optics attempt exposed the missing reviewed public
API entry; it was declared consistently with the glossary before the passing run.

RTC science checks use `/tmp/rtc-scientific-ownership-env-20261106`, derived from
the existing optional environment in a new directory and resolved with the new
AOS worktree. AOS checks use `/tmp/aos-rtc-ownership-env`. Existing environments
were preserved. The positive FITS selector remains outside the core suite; the
core retains artifact admission without importing optional scientific packages.
These software checks do not qualify live lifecycle, GPU execution or deadlines.

## Detector layout scientific ownership

AOS commit `6a966ccd` moves detector layout to its built-in AlgorithmGraphs node
registry. This reuses the existing graph node/factory interfaces without another
detector owner wrapper, executor or public constructor. The node keeps selector
`detector_frame_layout_f32`, config fields, ports, schema declarations,
Float32/UInt16 output contracts, zero-based origin, padding, affine conversion,
clipping, nearest-even rounding, reset and fixed-address capture capability.
The graph parser reuses its existing named-field/string/tuple validation.

RTC deletes its 305-line node implementation. Its factory composition retains
only application-relative optical path handling around the AOS builtins. The
scientific CPU/GPU tests move upstream; RTC retains a small public graph-load and
execution integration check. AOS version 0.3.21 owns the node; RTC's weak compat
requires that version. Pkg regenerates manifests; no source overrides are added
to exported applications and no release or registry is published.

| Gate | Passing assertions | Log under `/tmp/` |
| --- | ---: | --- |
| AOS detector layout CPU | 76 | `aos-rtc-detector-layout-tests.log` |
| AOS algorithm graphs | 1,472 | `aos-rtc-algorithm-graphs-tests.log` |
| CUDA stream and captured execution | 60 | `aos-rtc-detector-layout-cuda-tests.log` |
| AMDGPU stream and captured execution | 60 | `aos-rtc-detector-layout-amdgpu-tests.log` |
| Fresh stable YAML parse/load/prepare/step/reset | 2 | `aos-rtc-detector-stable-load.log` |
| RTC factory composition and UInt16 processing | 5 | `rtc-detector-integration-20261106.log` |
| Full RTC core suite after legacy/influence changes | 10,832 in 503 testsets | `rtc-streamline-core-20261106.log` |

All processes exit 0. The core explicitly selects the PipeWireAO artifact prefix;
optional graph checks open no core/service. The full core does not import optional
science, so the separate factory integration and upstream graph/GPU checks cover
the detector transfer. Root review checked the copied conversion order, buffer
shape/device/alias checks, zero padding, retained ROI view and capture traits.

The algorithm-graphs log retains a precompile warning about a missing AOS build ID
in an AOSYAMLExt cache. CUDA environment setup overlapped that first test process;
this was a validation setup error, not a confirmed cause of the cache warning.
Fresh AOS/YAML loading and the stable YAML execution probe pass without warnings
after setup ends (`aos-rtc-detector-cache-recheck.log`). AMDGPU uses its own
`/tmp/aos-rtc-ownership-amdgpu-env`; no environment is mutated during final probes.
GPU software execution is demonstrated; no hardware-control or deadline
qualification follows.

## Capture interface under discussion

The user clarified that instrument repositories should remain declarative rather
than acquire per-instrument Julia packages. A receiving-source inspection at
instrument revision `7eed0543` confirms that guidance, and finds no instrument
tool callers of the current Classic capture-file product. Its private-core RTC
test remains an active caller. No existing receiving capture API was identified.
The feature remains intact; it is not silently retired or moved into deployments.

The missing boundary is a generic bounded capture contract: select channels as
data and derive their admitted types, shapes, layout, rate, metadata and schemas
from prepared ports. Reuse `NdArrayFormat`, `payload_size`, semantic metadata and
the existing completed acquisition snapshots. The existing native Capture command
already carries probe/cursor/frame count; its cold-bound owner contract can fix
channel layout without dynamic per-request selection or a protocol replacement.

Classic channel roles, dimensions and scientific quality diagnostics must stop
being generic transport policy. Preserve their declared meanings and saved schema
readability when designing the replacement. Generic file persistence has no
drop-in interface in PipeWireAO today; placing it there is not an accepted scope
decision. The inspected `DataRecorder.jl` is an AeronTensorPool recorder and is
not an established replacement for metadata-preserving PipeWire calibration
capture. Continuous archiving remains deferred to its separate service. No new
capture framework or persistence dependency is introduced during this discussion.
