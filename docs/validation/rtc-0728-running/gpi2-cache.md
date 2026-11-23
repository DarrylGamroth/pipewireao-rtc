# GPI2 optical startup cache

The first managed GPI2 attempt on 2026-11-22, unit
`pipewireao-session@2dd27fd425e3.service`, failed before Ready. Its simulator
reported sequence zero and a CPU backend, then exited during
`SIMULATOR_PREPARING` with a GPUCompiler boxed-constant error in
`gpu_report_exception`. The RTC subsequently reported an unexpected owner
lifecycle. The data-flow observer never attached.

The earlier admission on unit `pipewireao-session@72ee532e1dd4.service`
reached Ready in 65.65 s and acknowledged Quit. Its simulator journal
reported `SIMULATOR_CONNECTED sequence=0 held=true`. The previous and current
receipts identify the same sealed deployment and manifest, and both simulator
commands selected Julia 1.13.4 with three default threads and existing native
package images. The previous installation was temporary and had been removed.

| Sealed asset | SHA-256 |
| --- | --- |
| Deployment | `f3e6dd9e70a3af07a48fdb77d532e9d2bb2989b2b7302c71ccebdfd90939b6c0` |
| Manifest | `9a630720bcd6043409da03f9d376ffb0e9e4904756b099a1fda158d8132dac5a` |
| Simulator configuration | `0c5822d4473e63529a3964644d381210217a1babd7923da6d86bec16741ecd3f` |

The registered cohort used RTC 0.7.28, Proper 0.4.3, KernelAbstractions 0.10.8,
GPUCompiler 2.23.4 and PipeWireAO native 4.0.8. The simulator's generated
startup cache had the sealed manifest and recorded its workload's source and
deployment inputs.

## Reproduction

A local run of the installed startup workload with the simulator's Julia
arguments and a fresh writable depot and PoCL cache reproduced the managed
error. The stack reached `GPUCompiler.demote_boxed_constants!` while compiling
Proper's `gpu__ka_apply_shifted_mask_kernel!` through the KernelAbstractions
CPU POCL backend. A standalone call to the same mask kernel also reproduced
the error. Setting `JULIA_KA_CPU_THREADS=1` reproduced the managed error.
A diagnostic `-g0` run omitted the boxed diagnostic call and instead reported
invalid LLVM IR in the same kernel, including dynamic pointer operations.

The default loader trace selected a newer shared RTC native cache and
loaded its Logging dependency. Julia then rejected the installed optical
startup cache because its required Logging build differed. The import fell
back to source and the warm frame attempted the failing kernel compilation.
Julia 1.13.4's `Base.find_all_in_cache_path` orders native cache candidates
across depots by modification time. Depot order alone cannot prefer an older
compatible native cache.

| Native cache in this installation | Required Logging build ID |
| --- | --- |
| Shared RTC `j1cKT_U3Sge.ji`, selected during failure | `fafbfcfd-cdb1-4e98-1d4e-ae4dd95ceebd` |
| Installed RTC `j1cKT_5QTbT.ji`, compatible with startup cache | `fafbfcfd-5867-4a50-8faf-c3c3b407c165` |
| Installed optical startup `ZFkfi_Ect2y.ji` | `fafbfcfd-5867-4a50-8faf-c3c3b407c165` |

## Construct and verify a private compatible depot

Use the sealed simulator's Julia executable and the original installed GPI2
application. Set `application` to its installed directory, `source_depot` to
the depot used by the installer, and `private_depot` to a new directory. Use the
matching registered PipeWireAO SDK through the existing `PIPEWIREAO_PREFIX`.
Choose the startup cache produced by that installation if the image contains
multiple entries. The helper reads Julia cache headers and copies only the
required build IDs and their native object files. Its package, artifact and
Julia distribution aliases resolve the existing installed content. The private
depot has its own compiled-cache directory.

```sh
optical_startup="$application/optical-startup/simulator"
julia --startup-file=no test/integration/copy_gpi2_startup_cache.jl \
  "$optical_startup"/depot/compiled/v1.13/PipeWireAOOpticalStartup/*.ji \
  "$private_depot" "$optical_startup/depot" "$source_depot"

scratch=$(mktemp -d)
JULIA_DEPOT_PATH="$optical_startup/depot:$scratch:$private_depot:" \
JULIA_LOAD_PATH="@:$optical_startup:@stdlib" JULIA_DEBUG=loading \
POCL_CACHE_DIR="$scratch/pocl" XDG_CACHE_HOME="$scratch" \
OPENBLAS_NUM_THREADS=1 CUDA_VISIBLE_DEVICES= ROCR_VISIBLE_DEVICES= \
julia --startup-file=no --threads=3,0 --compiled-modules=existing \
  --pkgimages=existing --project="$application" -e '
    using PipeWireAORTC
    Base.require(Main, :PipeWireAOOpticalStartup)
    using AdaptiveOpticsSimPipeWireHIL
    AdaptiveOpticsSimPipeWireHIL.Simulation.prepare_lockstep_startup(only(ARGS))
    println("SCIENTIFIC_PREPARATION_PASSED")
  ' "$application/simulation.conf"
```

The private-depot check exited successfully. The loader trace shows the matching
Logging, RTC, LLVM, KernelAbstractions and optical startup objects loaded from
the private cache. The scientific preparation and warm frame completed with
the default owner arguments, without starting a PipeWire core. No sealed or
shared compiled-cache bytes were changed.

For the managed retry, give the coordinator `JULIA_DEPOT_PATH="$private_depot:"`
and retain the original sealed owner command and systemd admission checks. The
managed launcher adds the installed startup depot itself. The offline result
qualifies the startup computation. The managed validation records Ready,
Running, data flow and Quit separately.

[Private-depot helper](../../../test/integration/copy_gpi2_startup_cache.jl)
