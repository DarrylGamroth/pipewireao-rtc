# PipeWireAO 4.0.2+0 package build receipt

Date: 2026-11-06. This packaging-stage receipt predates publication. The parent [release record](README.md) records the published cohort. The build worker did not push, upload, tag, register, or launch a daemon/session.

## Inputs and changes

Start state and remotes: `/tmp/pipewireao-402-start-state.md`.

- Native GitSource: `https://github.com/DarrylGamroth/PipeWireAO.git`, exact revision `156daf39e1ecfab590d045c6b6672acdbed3f49f`. Annotated source tag `v4.0.2` was independently observed to peel to that revision before building.
- Recipe worktree: `/home/dgamroth/workspaces/codex/pipewire/Yggdrasil-rtc-release-402`, branch `release/pipewireao-4.0.2`, commit `a0003175bd782ec18ec6441d549d01109218c4a3`, based on `affdbb97be9fb2422fa241ed353a703b9b234d27`.
- The recipe changes only version `4.0.1` → `4.0.2` and the exact GitSource pin. Bundled patch, products, dependencies, GCC selection, features, ISA flags, augmentation, and all five platforms remain unchanged.
- Generated JLL worktree: `/home/dgamroth/workspaces/codex/pipewire/PipeWireAO_jll-rtc-release-402`, branch `release/pipewireao-4.0.2`, commit `ac0e573ec1957ce877c7d1fe5508fb754db80ab7`, Git tree `e72d799afe8f304b662ecd6db358f2f08a1dab88`, based on `09c4f4e9f293376fdd1a2cf73a21d8744be66585`.
- BinaryBuilder generated all outputs through `rebuild_jll_package`; no generated files were edited by hand. Final diff contains only `Artifacts.toml`, `Project.toml`, and `README.md`; wrappers and platform augmentation regenerate identically.

## Tooling and commands

Julia 1.13.3; BinaryBuilder 0.6.6; BinaryBuilderBase 1.44.0; UserNSRunner; recipe preferred GCC 11. Host: AMD Ryzen 7 6800H, AVX2/FMA available, AVX-512 unavailable.

The cached bb environment was copied to `/tmp/pipewireao-402-bb-env`; its already locked BinaryBuilderBase dependency was added as a direct dependency because the recipe imports it directly. No dependency upgrades or modifications to the original environment were made.

From the recipe directory:

```sh
julia --project=/tmp/pipewireao-402-bb-env build_tarballs.jl --meta-json=/tmp/pipewireao-402-meta.json
julia --project=/tmp/pipewireao-402-bb-env build_tarballs.jl --verbose
julia --project=/tmp/pipewireao-402-bb-env /tmp/pipewireao-402-generate-jll.jl
```

Build log: `/tmp/pipewireao-402-build.log` (exit 0). Generator helper: `/tmp/pipewireao-402-generate-jll.jl`; final generation log: `/tmp/pipewireao-402-jll-generation.log` (exit 0). The helper loads authoritative recipe variables through metadata mode and calls BinaryBuilder's generator with an explicitly typed empty dependency vector, the dedicated JLL `code_dir`, exact version `4.0.2+0`, and the official future release URL. It performs no deployment.

## Products and artifact metadata

Product tarballs and matching `PipeWireAO-logs.v4.0.2.*.tar.gz` logs reside at:

`/home/dgamroth/workspaces/codex/pipewire/Yggdrasil-rtc-release-402/P/PipeWireAO/products/`

Each product filename is `PipeWireAO.v4.0.2.<platform>.tar.gz`.

| Platform | SHA256 | Artifact Git tree |
| --- | --- | --- |
| aarch64-linux-gnu | `7c11ad423c8a793206846cd42135182e64c0ee8979a3a52eb9a6a80cd75f5e39` | `c7bd388331361e52147a0c840fd7901c62d07f3c` |
| x86_64-linux-gnu | `55dfdba8eeee6eada025fecc983931ab6c719fc70c8792432e8223728be87ef4` | `72b97753fbbc1417efc9339009a6abf82657e6e3` |
| x86_64-linux-gnu-march+x86_64 | `55dfdba8eeee6eada025fecc983931ab6c719fc70c8792432e8223728be87ef4` | `72b97753fbbc1417efc9339009a6abf82657e6e3` |
| x86_64-linux-gnu-march+avx2 | `0f01585ae9cae1e5405af2a5589f426d158a76327e5df550f97c9143d295a4d5` | `b84754cc61ae9a8e33d31ec4352f188fa5405581` |
| x86_64-linux-gnu-march+avx512 | `dfe4655338d031f41d5546eb071d5ac1280f5a78485fff7505c182405b62edd4` | `c6d03c40bde2e6b72bffe338a6362c3a68ae54f7` |

Official generated URL prefix: `https://github.com/DarrylGamroth/PipeWireAO_jll.jl/releases/download/PipeWireAO-v4.0.2+0/`.

Machine-readable metadata and installed artifact paths: `/tmp/pipewireao-402-artifact-validation.tsv`. Product and log tarball SHA256 records: `/tmp/pipewireao-402-tarball-sha256.txt` and `/tmp/pipewireao-402-log-tarball-sha256.txt`.

## Verification

Observed for all five artifacts: expected ELF architecture; all three declared library products; SONAMEs and no build-workspace RPATHs; installed license; exported `pw_get_library_version` and `pw_ndarray_filter_get_loop`; native `4.0.2` version string; generated 4.0.2 header macros; installed `ndarray-filter.h` byte-for-byte equal to source. All generated release URLs, tarball SHA256 values, and installed artifact trees match. Tagged and untagged baseline tarballs are byte-identical.

Validation script: `/tmp/pipewireao-402-validate-artifacts.jl`; result `/tmp/pipewireao-402-artifact-validation.tsv` and empty error log `/tmp/pipewireao-402-artifact-validation.log`. Final generated metadata result: `/tmp/pipewireao-402-generated-metadata-validation.log`.

Observed host checks: baseline and AVX2 native product dlopen, support plugin factory symbol, native version 4.0.2, `pw_ndarray_filter_get_loop(NULL) == NULL`, and `pipewire-ao --version` compiled/linked 4.0.2. Generated JLL import selects the expected AVX2 tree and passes package version, product path, native version and accessor smoke. Logs: `/tmp/pipewireao-402-baseline-smoke.log`, `/tmp/pipewireao-402-avx2-smoke.log`, `/tmp/pipewireao-402-generated-jll-smoke.log`; smoke script `/tmp/pipewireao-402-native-smoke.jl`.

Both dedicated worktrees pass `git diff --check` and are clean after commits. Original worktrees were not edited.

## Warnings and scope

Retained 64 BinaryBuilder ISA audit warnings at `/tmp/pipewireao-402-audit-warnings.txt`, plus the full build log. Warnings include objects using less than their selected tier, CPUID-aware objects that the scanner conservatively classifies as baseline, and the existing CPU-dispatched audioconvert/filter-graph libraries. Their CPU feature dispatch is visible in `spa/plugins/audioconvert/audioconvert.c`, the conversion operation tables, and `spa/plugins/filter-graph/audio-dsp.c`. All three baseline dispatch libraries reported above the baseline tier have `.text` sections byte-identical to published 4.0.1: `/tmp/pipewireao-402-baseline-dispatch-comparison.log`.

The AVX2 client-node warning was specifically discriminated: the scanner's only AVX-512-category mnemonics are four VEX-encoded `vpgatherqd` operations in `do_port_use_buffers` at `0x18cd1`, `0x18ce3`, `0x18d00`, `0x18d0f`. GNU and LLVM decode them identically with YMM indices and XMM masks; no EVEX/ZMM/opmask instructions were found. BinaryBuilder's mnemonic-only table lists `vpgatherqd` as AVX-512 without accounting for the encoding. The [Intel SDM](https://cdrdv2-public.intel.com/671200/325462-sdm-vol-1-2abcd-3abcd.pdf) defines the VEX encoding as AVX2. This module's entire `.text` section is byte-identical to published 4.0.1 AVX2 (SHA256 `7fd63057ab65bab08f1d9eb21959c85a62f32798f67a373500a5de6df96d46a4`). Exact module SHA256 is `f9ba53b437f3491a1685e3ac82b624dec07e2e7bc80a69f4cd8bcf3bac888c26`. Inspection files: `/tmp/pipewireao-402-avx2-client-node-disassembly.txt`, `/tmp/pipewireao-402-avx2-client-node-isa.txt`.

Compiler warnings retained in the build log include unavailable gettext translations, unused functions and ignored `retain` attributes under the unchanged GCC 11 build; bundled patch applied with an existing one-line context offset. No feature or compiler flag changes were introduced to silence warnings.

These checks establish software packaging, static binary integrity, and the stated host smoke behavior. This worker did not execute aarch64 or AVX-512 binaries, run a live core/session, qualify deadlines, or qualify hardware. The primary owns any additional native host evidence and publication; the receiving-package worker owns the full PipeWireAO.jl suite against this generated JLL.

The instruction classification was also checked against the [LLVM AVX2 intrinsic reference](https://clang.llvm.org/doxygen/avx2intrin_8h.html), which maps the AVX2 gather intrinsic to `VPGATHERQD`; the recorded disassembly identifies its VEX encoding.
