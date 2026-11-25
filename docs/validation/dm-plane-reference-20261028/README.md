# Optional runtime-OPD relay reference — 2026-10-28

Software evidence only. No live session, service, GUI or selected calibration was
changed. Work starts at AOS `6892b5f8`, RTC `cbb5704`, and local instrument
`feefdfc`; implementation branches are `codex/dm-plane-opd-20261028` in AOS/RTC
and `codex/gpi-dm-plane-reference-20261028` in the instrument repository.

## Scope

GPI's new ordinary YAML graph `dm-plane-reference` applies atmosphere, woofer and
the mounted stage OPD at prescription surface 48, then tweeter OPD at surface 60.
A single Proper wavefront propagates from 48 to 77. The fast common-pupil PWFS
and UInt16 detector remain a separate unchanged branch. These screens contain
metres OPD, with existing sign and no extra reflection factor. Native AOS axes
map explicitly to Proper `[y,x]`; amplitude and entrance OPD share one physical
grid. The generic RTC interface only forwards and validates cold declarations.

The old authored production and optical-reference graph files are byte-unchanged.
Generated copies changed only their regeneration header; the supported generator
also added the new graph and refreshed its receipt. Calibration files/receipts
were not changed. Adding a graph changes strict prescription identity; a fresh
qualification is required before activating a newly exported deployment.

## Checks

Julia 1.13.3 on local CPU. Developed task AOS/RTC sources with registered
HIL 0.2.10, Proper 0.4.1, AOC 0.17.3 and JFG 0.4.3/FGA 0.8.11.
The retained environment, scripts and logs are under
`~/.cache/pipewireao/gpi-dm-plane-reference-20261028/`.

| Selector | Result |
| --- | --- |
| AOS `test/proper/runtests.jl`, normal optimization | 431 passed |
| AOS `test/test_zemax_components.jl`, `-O0` | 116 passed |
| RTC `test/test_zemax_components.jl`, `-O0` | 47 passed |
| RTC `test/zemax_component_preparation.jl`, `-O0` | 85 passed |
| Instruments `test/gpi2_dm_planes.jl`, normal optimization | 35 passed |
| Instruments `test/gpi2_zemax.jl`, `-O0` | 30 passed |
| Instrument `tools/prepare-proper.jl gpi2 --check` | Authored inputs validated |

Commands use `julia --project=<retained-environment> [optional -O0] <selector>`
from the owning repository. No PipeWire core or hardware is opened.

The tests cover source/generated equality, actual surface-ID insertion, unchanged
nominal ray maps, malformed contracts, rectangular/asymmetric axis and center
mapping, direct-Proper agreement, cancellation, screen mutation, reset, cold
rejection of unsupported targets/modes, and warmed allocations. Extended sampled
trains admit at most 256 operations; the legacy path's admission is unchanged.

The complete 35-step relay initially allocated 10,976 bytes with both normal and
reduced optimization. Allocation profiling identified boxed recursive tuple
tails; forcing inline did not fix them. Bounded literal-index traversal reduced
the same isolated relay to zero warmed bytes. A heterogeneous 40-step regression
independently agrees with direct Proper and changes 30,224/30,688 bytes to zero
for Float32/Float64. Independent review confirmed ordered accesses and matching
input/map/mask tuple lengths.

An earlier independent finding identified a half-pixel entrance-amplitude shift.
The opt-in `pupil_grid` now maps amplitude and OPD through the same bilinear plan.
Asymmetric direct-Proper and cancellation tests distinguish this fix from the
legacy padding result. Independent review closed the finding. Legacy behavior
remains unchanged.

## Grid study

A separate CPU Float64 experiment uses the same relay with an analytic annular
entrance amplitude (obscuration ratio 0.14) and fixed smooth asymmetric OPD maps.
It changes source and propagation resolution together, retaining the same
physical screen diameters; it is not an atmospheric or closed-loop replay.
`convergence.jl` and `final-integration.log` retain the exact inputs and results.

| Source / propagation samples | Output pitch (µm) | Sampled intensity integral | RMS radius (mm) |
| --- | --- | --- | --- |
| 60 / 120 | 201.937855 | 0.000110837032 | 4.291648 |
| 120 / 240 | 100.968928 | 0.000111856505 | 4.307355 |
| 240 / 480 | 50.484464 | 0.000112474563 | 4.317512 |

The integral changes by 0.55% and RMS radius by 0.24% between the two finest
grids. This is a sampling trend, not a selected accuracy tolerance or physical
throughput calibration. Grid sizes and hard aperture sampling still affect the
result. Informational single-step durations in the log are not a latency or
capacity benchmark.

At 120/240 source/propagation samples, six successive warmed steps allocate
1,408 bytes each; at 240/480 they allocate 1,568 bytes each, unchanged after
20 additional warmups. Partitioned allocation traces locate 1,408 bytes in
11 existing Proper 0.4.1 `ka_apply_shifted_mask!` CPU launches. The larger
propagation grid adds 160 bytes in `ka_copy_shifted_intensity!`. Entrance
interpolation and the new traversal allocate zero. These library kernel-launch
allocations are retained as a measured limitation; Proper was not modified.
See `allocation-profile.jl` and `allocation-profile.log`.

## Limits

The provided design omits the upgraded PWFS prescription. Off-axis aberrations,
transverse coordinate breaks, measured DM registration/parity and CAL2 coherent
handoff are not implemented here. The 40 mm woofer and 17.6 mm tweeter illuminated
diameters are provisional historical-design inputs. No hardware, physical-loop,
absolute photometry, deadline or optical-accuracy qualification is claimed.
Runtime sampled screens currently support scalar CPU propagation only; finite
bands, fixed-output resampling and accelerator execution reject cold. Existing
fast GPU selections remain available.
