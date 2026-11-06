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

Detector layout transfer is the next slice. Classic capture ownership and optional
workstation features retain the reviewed scope/prerequisites until implemented.
