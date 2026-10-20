# Released simulator dependencies and RTC boundary

The integration branch starts from RTC `5a054b3`. Existing dirty canonical RTC,
REVOLT application and GUI worktrees, sealed applications and running services
were left untouched. The new `rtc.code-workspace` selects its containing RTC
checkout explicitly and retains independent sibling repositories.

## Released closure

- AOS 0.2.1: tree `1a809e78c898ce01a58915b7f4fb71dc92d4711e`.
- Shared adapter 0.2.2: commit `87375e8d2fb1d0f63f279f20e4c445bdae517aa1`,
  tree `b86b36d35bf428be1f9b5bbf98eaf288302d2789`.
- PipeWireAO 0.6.18: tree `14dcef6fff816e5fc89459aca21cd1742b497be3`.
- Native artifact 1.7.1; local CUDA device NVIDIA GeForce RTX 3080.

The adapter patch integrates the existing `e57c6f0` timing API and `963bd48`
retry correction onto its AOS 0.2 release line. The former RTC bounds excluded
AOS 0.2 and HIL 0.2. Its tracked PipeWireAO 0.6.17 source lacked
`AcquisitionTriggerState`; after selecting 0.6.18, the RTC exposed its dependence
on `PipeWireExchangeTiming`, absent in HIL 0.2.1. The patch fixes both dependency
requirements without changing optical algorithms, calibration or native v1 IDs.

Registry publication initially introduced overlapping PipeWireAO ranges; Julia's
resolver rejected these. Follow-up registry commit `de5a3a0` uses disjoint ranges,
and all four simulator application environments resolve successfully. Older
unpublished installed-registry commits were preserved and were not pushed.

## Verification

Adapter full `Pkg.test` on Julia 1.13.2 with released AOS 0.2.1 and PipeWireAO
0.6.18 passed 1,753 assertions, including isolated native-core tests. The focused
retry/exchange selector passed 368 after correction; the same retry regression
failed before correction. Default timing helpers compile to a bare return.
An independent Astra source review found no open implementation defects. Its
extra Julia 1.12 focused run used a 1.13 manifest and had dependency warnings;
it is not counted as a clean minimum-version environment gate.

A fresh Julia 1.13.2 RTC environment uses only the local RTC path; AOS, adapter
and PipeWireAO are registry sources. Owner-loading checks pass 22, phase timing
18 and source configuration/report checks 97. Read-only cold preparation of the
existing Classic TOML/FITS configuration succeeds with 352 × 352 pixels and
277 commands. The phase test originally compared a captured cumulative GC time
with a later counter after possible compilation/GC. It now brackets the captured
value with counters before and after recording; the warmed zero-allocation
assertion remains and passes.

The shared simulator checks run with Julia 1.12.7 and default CUDA, disabling
scalar GPU indexing. Each check owns a temporary private core and command peer:

```sh
julia --startup-file=no --project=environments/classic --threads=3,0 test/private_core.jl classic
julia --startup-file=no --project=environments/copper --threads=3,0 test/private_core.jl copper
julia --startup-file=no --project=environments/gpi2 --threads=3,0 test/private_core.jl gpi2
```

Run from the independent simulation workspace. They check exact row-major pixel
payloads, same-boundary attachment, command scaling/adoption, acquisition identity,
reset and next-frame response. Test peers do not execute a controller graph.

## Limits and evidence

These checks do not qualify a complete managed Classic/Copper/GPI RTC session
with the new closure, GPI reconstruction/calibration/allocation, GUI attachment,
scientific fidelity, hardware or latency. Existing installed applications retain
their original dependency closures and evidence. The retained RTC TOML/FITS owner
route is separate from independent instrument Julia builders; a shared managed
builder entrypoint remains to be implemented rather than inferred from package
compatibility. No simulator panel or new live property is implemented by the
workspace and contract documentation.

Raw commands, manifests, failures, successful logs, publication receipts and the
independent review are retained at
`/home/dgamroth/workspaces/codex/worktrees/rtc-simulator-integration-20261019/`.
See `hil-patch/COMMANDS.md`, `hil-patch-review.md`, `registry-final/`,
`workspace-release-update-final.log` and `*-cuda-adapter022.log`.
