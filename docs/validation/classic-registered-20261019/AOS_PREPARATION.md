# Classic AOS configuration/FITS preparation

Observed on 2026-10-19. This record covers cold software preparation and same-backend migration parity for the selected Classic profile. It does not establish live lifecycle, observation transport, cadence, latency, physical hardware or other-profile qualification.

## Source and environment

- RTC starting revision: `fdc2c559c7755b89ac58b9dfe823761cb406fc96`; owner/extension and `Int32` artifact changes were uncommitted during these checks.
- Julia: `/home/dgamroth/.julia/juliaup/julia-1.13.2+0.x64.linux.gnu/bin/julia`, version 1.13.2. Initial exploratory commands used the directory's Julia 1.12.7 override; all acceptance checks listed below were repeated with explicit 1.13.2.
- Development environment: `/home/dgamroth/.local/state/classic-registered-20261019/development`.
- AOS: registered 0.1.0, tree `ee0a2a24f600954045d08d48971f1ce0d0d61b4b`; CUDA 6.4.2.
- HIL: 0.1.3 source at `48407618405ce8e906f245b59fd49d5a9ba5c00e`.
- Classic oracle: public `REVOLTClassicSim` APIs at `e0fbdab9a5483d92fa6df5539019624d40b84f1e`; this package is loaded only by the optional diagnostic test.
- Application declarations: `/home/dgamroth/workspaces/revolt-classic-rtc/simulation.conf` and `simulation.toml`.
- CUDA selection: `CUDA_VISIBLE_DEVICES=GPU-ace438b4-a57b-9194-d519-bdcbe42cb770`, logical device 0.

## Results

| Check | Observed result | Log |
| --- | --- | --- |
| Cold argument/configuration declarations and package load order | 40/40; bootstrap callback precedes optional science/CUDA callbacks; cancellation prevents loading | `/home/dgamroth/aos-owner-focused-1.13.2-20261019.log` |
| AOS FITS ordering, ownership and cancellation | 7/7 | same log |
| Existing artifact suite plus exact signed Int32 conversion and packing | 140/140 | `/home/dgamroth/aos-artifacts-1.13.2-20261019.log` |
| Generic 2×3 frame, three-command graph, Float32 basis and Bool pupil FITS | 14/14; deterministic command adoption/reset; no CUDA package loaded | `/home/dgamroth/aos-preparation-1.13.2-20261019.log` |
| Actual Classic CPU graph | 20/20 | `/home/dgamroth/aos-classic-cpu-1.13.2-20261019.log` |
| Actual Classic CUDA graph | 20/20 | `/home/dgamroth/aos-classic-cuda-1.13.2-20261019.log` |

Classic checks compare the parsed simulation TOML to the public reference graph, the complete prepared `Int32[277]` actuator grid to `actuator_grid_indices()`, declared command count and frame extent, and three detector frames plus pupil/PDM OPD arrays. Both owners use the same backend and the established warm/reset sequence. Commands change from zero to a finite probe, then back to zero, with adoption after each completed frame. All compared arrays were exactly equal. No cross-backend equality or broader numerical tolerance claim follows.

The reusable implementation imports no `REVOLTClassicSim`, embeds no Classic command/frame counts, and includes only its own extension helper. The signed artifact addition is required because AOS's public grid Gaussian parameter contract is `Int32`, preserving the original geometry representation.

## Reproduction

Run cold tests from the RTC worktree with `--project=test`, including `test/test_artifacts.jl` and `test/test_aos_owner.jl`. Run `test/aos_preparation.jl` in an environment containing the RTC checkout, AOS and HIL. Run the optional Classic diagnostic as:

```text
julia --project=DEVELOPMENT --startup-file=no --threads=2,0 test/aos_classic_preparation.jl APPLICATION/simulation.conf REFERENCE_PACKAGE_DIRECTORY cpu
CUDA_VISIBLE_DEVICES=GPU-ace438b4-a57b-9194-d519-bdcbe42cb770 julia --project=DEVELOPMENT --startup-file=no --threads=2,0 test/aos_classic_preparation.jl APPLICATION/simulation.conf REFERENCE_PACKAGE_DIRECTORY cuda
```

Select the explicit Julia 1.13.2 executable above. `REFERENCE_PACKAGE_DIRECTORY` contains the historical `REVOLTClassicSim.jl` package directory. The diagnostic's reference package is not a runtime dependency of the owner or application.

Live Preparing/Prepared/Connect, held run/reset/query, cancellation, exact cleanup, and optional image publication remain separate application gates. No services were started or stopped by these preparation tests.
