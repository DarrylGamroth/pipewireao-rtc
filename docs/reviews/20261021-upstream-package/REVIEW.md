# Upstream WirePlumber package review — 2026-10-21

Independent bounded review of WirePlumber package commit
`7a2248b9af477831638eb0eb8c2110443ea77383`, its provenance correction
`85087dfe12b69dc7eb1076f0afef92e8a455f138`, and the RTC ownership-document
changes based on `c099a23b85467f784be3b1ea49c35476e8f4d26e`. Reviewed in the
`wireplumber-upstream-package` and `pipewireao-rtc-upstream-package` worktrees,
both on `codex/upstream-package`. The WirePlumber tree was clean after its
implementation commit; RTC had the intended documentation edits. Review used
the audit-code-slop workflow; mechanical size/wrapper signals did not establish
additional defects.

## Findings

### UPKG-01 — Prepared Lua digest omits directory-symlink contents

- Severity: P2. Confidence: high. Observed defect; no runtime defect inferred.
- Affected code: `packaging/pipewireao/build.py`, `tree_digest` lines 35–38,
  manifest construction line 115, and Lua copy line 132 in the reviewed commit.
- Evidence: `Path.rglob` does not descend through directory symlinks, whereas
  `shutil.copytree` follows them by default. In a temporary prepared Lua tree
  with `src` pointing to another directory, changing `src/lua.h` preserved the
  reported source digest while changing the copied source bytes.
- Consequence: the optional prepared-Lua digest does not identify all source
  contents actually compiled. The ordinary nonsymlinked Lua cohort is unaffected.
- Remediation: digest the copied `source/subprojects/lua-5.5.0` tree, or reject
  directory symlinks in supplied Lua sources.
- Required validation: reproduce the symlink case and show that the recorded
  digest now changes with the copied source bytes; retain ordinary build evidence.
- Disposition: **resolved and independently verified** in
  `85087dfe12b69dc7eb1076f0afef92e8a455f138`. The digest is now computed
  immediately after copying from the actual copied source. An independent
  end-to-end archive/overlay/copy/manifest probe, with only Meson setup/compile
  stubbed, showed fail-before (changed copied bytes, unchanged manifest digest,
  digest did not match copied tree) and pass-after (changed copied bytes changed
  manifest digest, digest matched copied tree). The recorded digest for the
  existing ordinary Lua build remains unchanged. No unresolved finding remains.

## Verified evidence

- The tracked runtime, Meson files and test files match pinned upstream
  `bdc17eb2c419cbe41dbb248cf20cbe93370ee2f7`. Additional files are the recipe
  and historical AO reviews. The new historical-review notices preserve the
  original records and point to current packaging guidance.
- The default overlay changes exactly the two pkg-config dependency names.
  There is no remaining downstream runtime API or AO device-policy overlay.
- Independently exported the pin and checked the archive SHA-256 against
  `/tmp/wp-package-20261021/manifest.json`; checked its default patch hash.
  Its resulting source files match the actual default configured source tree.
- Each optional fix applies independently to the unmodified pin; both compose
  with the dependency overlay. Each patch is byte-identical to the corresponding
  prior-fork diff and contains its regression tests.
- Help for all commands passes. Existing workdir/prefix, overlapping SDK paths
  and a relative prefix are rejected before build mutation.
- The constructed environment contains only the declared keys. Both AO
  pkg-config files resolve inside the specified SDK. Meson dependency records
  select those SDK headers/library; the built library depends on
  `libpipewire-ao-0.3.so.0` and records the SDK library runpath.
- The existing raw Meson JSON records agree exactly with the manifest:
  57 tests, all OK. The test runtime directory has mode 0700.
- RTC wording preserves RTC application authority, separates optional site/device
  policy and does not promote physical-device or timing qualification.

## Limits

The reviewer did not rerun the full upstream suite or compile optional-fix
cohorts; patch application and existing raw default-test evidence were checked.
RTC native/CPU-array/generated-configuration gates are the primary agent’s
separate [validation](../../validation/upstream-package-20261021/README.md). The sibling package-guide links require integrating the
recipe into the canonical `wireplumber` checkout. No simulation, GPU workload,
live device policy, service change or production installation was started by
this review. No real-time, physical-device or hardware qualification is claimed.
