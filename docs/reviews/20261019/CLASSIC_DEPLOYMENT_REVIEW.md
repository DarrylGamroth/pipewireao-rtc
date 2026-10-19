# Classic registered deployment review — 2026-10-19

## Scope and baseline

Independent review of the in-progress Classic CPU JFG / CUDA AOS migration,
against [REGISTERED_RTC_MIGRATION.md](../../REGISTERED_RTC_MIGRATION.md),
[CLASSIC_REGISTERED_DEPLOYMENT.md](../../CLASSIC_REGISTERED_DEPLOYMENT.md),
RTC-ARCH-024/025 and RTC-DEV-003/004/006/009/013/021/022/030. This review examines
source behavior and focused software checks. It does not establish physical
authority, optical accuracy, cadence, latency, or hardware qualification.

| Repository | Worktree | Baseline and reviewed state |
| --- | --- | --- |
| PipeWireAORTC | `PipeWireAORTC-classic-20261019` | `fdc2c559c7755b89ac58b9dfe823761cb406fc96` plus ongoing changes, branch `codex/classic-registered-20261019` |
| JuliaFilterGraph | `JFG-classic-20261019` | `71585ee` plus four modified FilterGraphIsland files, branch `codex/classic-deployment-20261019` |
| AdaptiveOpticsSimPipeWireHIL | `AdaptiveOpticsSimPipeWireHIL-classic-20261019` | Clean `48407618405ce8e906f245b59fd49d5a9ba5c00e`, compared with main `3c3de5b` |

The RTC and JFG changes existed before this reviewer began. They were preserved.
Only this review document was written by the reviewer. No services, registries,
package environments, or production files were changed by the reviewer. Source
files continued to advance during the review; finding dispositions below name
the observed remediation separately from the initial finding.

## Findings

### CL-R01 — Registered environment validation accepts an incomplete, unsealed environment

- **Severity:** P2, deployment contract defect.
- **Confidence:** high; directly established from the initial implementation.
- **Authority:** AAR-01 in the registered migration contract requires immutable
  registered dependency closure and a relocatable application. The new helper
  describes its result as a validated immutable application environment.
- **Affected code:** `application_environment` in
  `src/configuration/deployment_configuration.jl`, initially lines 172–194;
  installer and registered launch paths trust this result.
- **Observed evidence:** the initial helper accepted a Project containing the
  required PipeWireAORTC dependency and a Manifest containing only
  `manifest_format = "2.0"`. Its loop iterated
  `values(get(manifest, "deps", Dict()))`, so absent dependencies produced no
  rejection. It also did not require either environment file to be included in
  the deployment artifact hash mapping. Existing artifact validation checked
  only entries supplied in that mapping.
- **Derived consequence:** validation could certify a missing dependency closure
  or allow an environment change without invalidating the sealed deployment.
  This does not prove that a malformed application would reach live admission;
  loading could instead fail later. It does invalidate the claimed cold
  immutable-environment check and moves errors beyond the intended boundary.
- **Remediation:** require sealed Project and Manifest hashes, a nonempty
  dependency mapping, exact direct dependency UUID resolution, immutable tree
  identities for non-bundled packages, and a present transitive dependency
  closure. Preserve legitimate Julia standard-library identities. Reject
  path/repository overrides.
- **Required validation:** positive registered environment; absent dependencies;
  absent/wrong direct dependency identity; missing tree identity; missing
  transitive dependency; missing/mismatched seal; source overrides; containment.
  Final application acceptance additionally requires fresh registry-only
  instantiate and relocation; a syntactically valid hash is not proof of a
  registered or fetchable tree.
- **Disposition:** accepted by the primary agent and remediated during this
  review. Source inspection confirms the new hash checks, dependency-presence
  checks and UUID/tree checks. The focused post-change check passed with 19
  assertions. CL-R01 is closed for the confirmed empty-closure and missing-seal
  defects; final application provenance/instantiate remains a separate gate.
  No executable pre-change reproduction was retained; the pre-change evidence
  is source analysis, not a claimed fail-before test run.

### CL-R02 — AOS default loaders resolve optional packages from the wrong module

- **Severity:** P1, blocks the selected registered Classic deployment.
- **Confidence:** high; observed in the live startup journal and reproduced in
  a fresh process without services, with the identical invocation passing
  after the change.
- **Authority:** AAR-03/04 require a package-owned configuration/FITS AOS owner;
  optional integrations must preserve cold clients and load through the
  instrument's registered environment. AAR-01 requires an actually runnable
  registered application.
- **Affected code:** `src/owners/aos_owner.jl:157`, the three default
  `Base.require` calls for AdaptiveOpticsSim, AdaptiveOpticsSimPipeWireHIL and
  CUDA. The defect is present in committed `8ed4358`, published as RTC 0.1.2.
- **Observed evidence:**
  `/home/dgamroth/.local/state/classic-registered-20261019/session-integration-002-simulator.log`
  records the simulator exiting with status 1 at 13:58:14 after
  `Cannot load ... AdaptiveOpticsSim into module PipeWireAORTC.AOSOwner ...
  because package PipeWireAORTC does not have AdaptiveOpticsSim in its dependencies`.
  The owner resolved each optional package relative to its own package module,
  where these packages are weak dependencies. Declaring them directly in the
  application environment did not authorize that package-relative load.
- **Derived consequence:** startup cannot complete the selected AOS owner or
  reach session admission. CPU loading fails at the same first import; the CUDA
  default also used the same incorrect resolution context.
- **Coverage gap:** the initial declaration/load-order test injected fake
  `load_science` and `load_cuda` callbacks. The scientific preparation tests
  imported AOS/HIL before calling preparation. Neither exercised the actual
  `_main` default loaders. The first independent review missed this path;
  its earlier source-only conclusion did not establish entrypoint execution.
- **Remediation:** resolve the three optional imports through `Main`, using the
  application's direct dependencies, matching the existing GraphOwner loader.
  Keep the bootstrap call before imports and keep optional packages as weak
  dependencies of PipeWireAORTC. Publish a new immutable RTC version; do not
  rewrite the already published 0.1.2 tree.
- **Required validation:** a fresh process that imports only PipeWireAORTC,
  calls `_main` with its real default loaders, checks the AOS extension becomes
  available, verifies CPU does not load CUDA, and verifies the CUDA selection
  loads CUDA after bootstrap. Repeat actual isolated registered startup with
  the new release before claiming deployment readiness.
- **Disposition:** source fix independently verified. A fresh-process invocation
  with the actual application `simulation.conf` and only bootstrap transport
  and the final scientific loop substituted exited 1 before the patch and
  exited 0 after it, printing `DEFAULT_LOADER_REACHED_RUN`. The same command,
  environment and configuration were used for both runs. The new maintained
  regression passed independently in fresh CPU and CUDA processes (22 and 21
  assertions). These runs do not start a service or compute on the GPU. Final
  immutable release and live admission remain open deployment gates.

## Reviewed obligations and evidence limits

| Obligation | Source analysis | Remaining deployment evidence |
| --- | --- | --- |
| Optional science and early Preparing | GraphOwner and AOSOwner publish bootstrap Preparing before loading optional science; imports use package entrypoints/extensions | Exercise cold startup and cancellation with exact registered releases |
| FITS ownership, types and axes | Declarations bound retained arrays to 512 MiB; artifact preparation bounds snapshot/image extents, requires explicit multidimensional axes, rejects nonfinite and inexact integral/Boolean conversion; the Int32 addition preserves two's-complement packed bytes | Final artifact hashes and exact Classic science comparison belong in the delivery record |
| JFG parameter ordering | `prepare_service_graph` checks all startup bindings, adopts copied values before capture, and closes CPU workers on failure; graph owner closes node before execution | Live parameter submission and observed active adoption |
| Source admission | AOS activates connected streams while its science state remains held; it does not exchange frames until native source control releases it | Exact native session READY proof and pre-release source silence |
| Frame/command ordering | HIL's mandatory exchange remains unchanged from main: publish frame, validate matching command, adopt command, then return; AOS consumes source controls between completed exchanges | Live start/stop/reset and calibration restoration |
| Reset and observation | AOS drains and joins optical work before resetting HIL; HIL clears optional image snapshots under their independent native loop lock; observation has bounded owned snapshots and can drop samples | Attach/stall/detach/reattach comparison on the actual selected application |
| Cleanup | JFG closes the scientific node and CPU execution; AOS stops optical work and closes HIL endpoints; HIL attempts all optional/mandatory resource cleanup and reports failures | Exact owner process/resource absence, including startup cancellation and failed preparation |
| Sole lifecycle authority | New entrypoints implement scientific owner preparation/control only. Existing native WirePlumber and systemd paths retain admission and process ownership | Isolated real service integration with selected native 1.7.1 overlay |
| HIL acquisition preservation | Diff against `3c3de5b` adds optional image ownership; acquisition-source file is unchanged, and mandatory command-adoption body is unchanged | Existing HIL evidence is reusable only with its documented native SDK and package closure |
| Registered installation | Installer selects the application's project and package-owned CLI/template implementation; parameter owner uses the registered entrypoint; config paths resolve relative to the copied application | Final registry-only manifest, clean-depot instantiate, relocate, install, launch and GUI attach |

The initial source review found no additional confirmed defect in the examined
owner, initial-parameter, or HIL merge paths. Subsequent real startup exposed
CL-R02 above; the default-loader regression now covers that missed path. No
claim is made that pending live-service gates passed. GPU preparation and the
final application were being completed by other agents during the first pass.

## Focused independent software checks

Julia executable:
`/home/dgamroth/.julia/juliaup/julia-1.13.2+0.x64.linux.gnu/bin/julia`.
Read-only existing test environment:
`/home/dgamroth/.local/state/classic-registered-20261019/development`.
Invocations used `--startup-file=no --threads=2,0`, with the RTC worktree as the
working directory. This development environment contains path references to the
three reviewed worktrees; it is deliberately not final immutable-deployment
evidence.

| Check | Result | Evidence scope |
| --- | --- | --- |
| `include("test/test_graph_owner_integration.jl")` | Passed: 15 testset assertions plus top-level cold-loading/extension checks | Complete-frame and row-block JFG preparation, square FITS axis order, copied ownership, resulting row outputs |
| `include("test/aos_preparation.jl")` | Passed: 14 assertions | CPU AOS FITS preparation, exact command-induced output, deterministic reset, declaration rejection and cancellation; no service or GPU |
| `include("test/test_registered_application.jl")` | Passed: 19 assertions | CL-R01 empty-closure/missing-seal rejection, direct identity/tree/source checks, containment and generated launcher selection |
| `test/test_aos_owner_loading.jl cpu` in a fresh process | Passed: 22 assertions | CL-R02 actual default imports, bootstrap-before-import order, AOS extension activation and CUDA remaining unloaded |
| `test/test_aos_owner_loading.jl cuda` in a fresh process | Passed: 21 assertions | CL-R02 actual default AOS/HIL/CUDA imports and AOS extension activation; no GPU computation |
| RTC and HIL `git diff --check` | Passed at the review snapshot | Whitespace only |
| HIL `git diff --quiet 3c3de5b -- src/acquisition_source.jl` | Passed | Acquisition source identical to main |

The HIL integration record reports 1,678 assertions including private-core
transport checks. This reviewer inspected its source changes and evidence
description but did not independently rerun that full suite. The record also
retains the native 1.7.0 incompatibility; the selected native 1.7.1 artifact is
required for its v3 acquisition tests.

## Follow-up before final acceptance

1. Attach final immutable registered package trees, environment files, FITS
   hashes, native prefix identity, and relocation/instantiate result.
2. Complete isolated held startup, source release, property and parameter
   adoption, stop/reset, cancellation, calibration restoration and exact
   shutdown evidence. Preserve any failed gate and its actual cause.
3. Record the basis for the application's current 900000 ms startup timeout.
   The governing deployment document disallows silently increasing the startup
   budget to mask failures; this review has not established whether that value
   is retained from the accepted baseline.
4. Repeat this review's affected portions after final source changes. Keep
   physical and real-time qualification explicitly outside this increment.
5. For CL-R02, publish the corrected source as a new immutable version, update
   the registered application and repeat isolated startup through live
   admission. The loader checks alone do not close this deployment gate.

## Reviewed source fingerprints

These SHA-256 values identify the mutable files at the source-review snapshot;
later updates require an explicit affected-file check.

| RTC file | SHA-256 |
| --- | --- |
| `src/owners/graph_owner.jl` | `55095bbcf0dd6b9c5e4c462b77a035e4365c51d13e093ee1af1ae057d833f863` |
| `src/owners/aos_owner.jl` | `8c5df3f3c88c6ce58a322eba78d4c9f7fe6b7542bd96a150bea4977b497a360b` |
| `ext/PipeWireAORTCGraphExt.jl` | `3c42c1941d0c0c95f61a52ea034c68bfb049721857879db19af7898efb92a3e5` |
| `ext/PipeWireAORTCAOSExt.jl` | `9ae1dfd23120a6c2911987c7a4da2e0e4bd4efe8a08473f2886edf10f1d76fa3` |
| `ext/aos/optical_observation.jl` | `51b9e93473062fe31bb8c43ada45a196c5ea52f3070bb96a9a1066a91c0f4d12` |
| `src/configuration/deployment_configuration.jl` | `a22d437c0d70873218d6aecf8dcb8c57096b6b71a2ad702717894631976eefee` |
| `src/deployment/wireplumber_install.jl` | `2b07e5330eeaae3e6038a88115cefb50fa29a260b95d26fc86683eb05382205b` |
| `src/artifacts.jl` | `7777012fb9410d5e0664d8ce11f22e561922010eb8bb40169fe53e57c248b0b6` |

CL-R02 follow-up fingerprints, after the three-call loader remediation:

| RTC file | SHA-256 |
| --- | --- |
| `src/owners/aos_owner.jl` | `46b03815133cc1413a2fc8cb767fa2f7907c2710ebda33fd8b8f1984e9707a74` |
| `test/test_aos_owner_loading.jl` | `94980f15b4bfb0cd1fae2c9ec5ed611bd7216bfa4a98533406bb59024b0e2454` |
