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

## Default optional-package loading regression

The isolated application run subsequently found a real startup defect in registered RTC 0.1.2: the default AOS owner loader called `Base.require` in the `AOSOwner` module's dependency context. Its optional packages are weak dependencies of RTC and direct dependencies of the application. Julia rejected the first actual AOS import. The earlier preparation and injected-loader checks above did not exercise this default loader.

`test/test_aos_owner_loading.jl` now runs in a fresh process with only RTC and the test library loaded. It injects the bootstrap transport callback and final science loop, retaining both actual default package loaders. It checks that Preparing precedes imports, the AOS extension is available before the loop, and CPU selection never loads CUDA. Each backend runs in its own process.

Fail-before evidence uses the application's registered immutable RTC 0.1.2 at `/home/dgamroth/.julia/packages/PipeWireAORTC/w7kWE`, Julia 1.13.2 and `--project=/home/dgamroth/workspaces/revolt-classic-rtc`. The CPU check exits 1 with 9 passing checks, one failure and one error at the first `Base.require`; observed events are Preparing, cancellation check, cleanup. Log: `/home/dgamroth/aos-owner-loading-fail-before-20261019.log`.

The correction changes all three default imports to `Base.require(Main, ...)`, resolving packages from the application's selected dependency environment. Their position after the bootstrap callback and cancellation checks is unchanged. Pass-after evidence uses the same test and Julia executable with `--project=/home/dgamroth/.local/state/classic-registered-20261019/development`, resolving the corrected RTC checkout based on `8ed4358539c2fb55573b53383b76af8f606db3c7`:

| Backend | Observed result | Log |
| --- | --- | --- |
| CPU | 22/22, exit 0; AOS/HIL extension loaded after Preparing; CUDA absent | `/home/dgamroth/aos-owner-loading-cpu-pass-after-20261019.log` |
| CUDA | 21/21, exit 0; actual AOS/HIL/CUDA loaders complete after Preparing | `/home/dgamroth/aos-owner-loading-cuda-pass-after-20261019.log` |

Reproduce with the explicit Julia executable above, selecting the desired project, followed by `--startup-file=no test/test_aos_owner_loading.jl cpu` or `cuda`. CUDA used the same UUID selection listed above. These checks establish package resolution and import order without creating scientific streams or starting services; live application startup remains a separate gate.
