# RTC package cohort with native/JLL 4.0.2

This release follows the cleanup-branch reconciliation. Started 2026-11-06; completed 2026-11-07. This record covers the verified source,
artifact, public-registry and cold registered installation gates.
The original checkout, deployed applications and live sessions remain unchanged.

## Selected cohort

| Package | Version | State |
| --- | --- | --- |
| Native PipeWireAO | 4.0.2 | Source `156daf39e`, published `v4.0.2` |
| PipeWireAO_jll | 4.0.2+0 | Generated source `ac0e573`, five artifacts published |
| PipeWireAO | 0.9.2 | Source `b8f34f3`, published; strict JLL/native 4.0.2 guards |
| FilterGraphAlgorithms | 0.12.0 | Existing registered numerical package; complete CPU suite passes 129,664 assertions |
| FilterGraphs | 0.9.0 | Existing registered graph engine; complete CPU suite passes 4,719 assertions |
| FilterGraphPipeWire | 0.5.2 | Published `fc89980`; runtime source unchanged from the verified endpoint port |
| AdaptiveOpticsSim | 0.3.21 | Published `06482bc8`; full CPU gate passes 12,187 assertions |
| AdaptiveOpticsSimPipeWireHIL | 0.5.0 | Existing registered adapter, selected for integration |
| AdaptiveOpticsCalibration | 0.17.3 | Existing registered calibration APIs |
| PipeWireAORTC | 0.7.0 | Published tag at `4252cab`; registry-only lock and full core gate pass |

RTC uses a minor release because the accepted cleanup renames public modules from
RTC 0.6.0. Existing pinned applications retain their matching APIs and environments.

## Published native and wrapper slices

The [BinaryBuilder receipt](JLL.md) records unchanged platform selection, source
revision, generated JLL metadata, tarball checksums, artifact trees and warning
adjudication. All five builds passed product/header/symbol/version checks.
The aarch64 archive was also extracted in an owned temporary directory on
`raspberrypi` (aarch64, glibc 2.36): the daemon reported compiled/linked 4.0.2,
all three shared libraries loaded, the public accessor accepted NULL and the
packaged header declared it. Its SHA256 was
`7c11ad423c8a793206846cd42135182e64c0ee8979a3a52eb9a6a80cd75f5e39`.
No remote service or installed runtime was changed.

PipeWireAO's full suite passes 2,327 reported assertions across 87 reported
summaries using the generated JLL's AVX2 artifact without SDK preferences.
Old JLL and native 4.0.1 are rejected before use. Binding regeneration was
unnecessary: the new artifact header exactly matches the prior generated source.

## Verification and corrected failures

| Gate | Result |
| --- | --- |
| PipeWireAO full package against generated artifacts | 2,327 reported assertions / 87 summaries; pass |
| FilterGraphAlgorithms complete CPU suite | 129,664 assertions; pass |
| FilterGraphs 0.9 complete CPU suite | 4,719 assertions; pass |
| FilterGraphPipeWire complete CPU suite, `--threads=4,0` | 2,921 assertions plus 6 child-process assertions; pass |
| FilterGraphPipeWire endpoint, port and control checks on FilterGraphs 0.10 | 714 assertions; pass |
| AOS complete CPU suite | 12,187 assertions / 259 summaries; pass |
| RTC complete core suite with registry dependencies and artifact SDK | 11,048 assertions / 514 summaries; pass |
| RTC calibration worker/private core | 206 assertions; pass |
| RTC named multi-command transport/private core | 133 assertions; pass |
| RTC generic capture/private core | 173 assertions; pass |
| Offline export and package metadata | 54 assertions; pass |
| Empty-depot public registry/JLL download and library load | Pass; no source paths, preferences or artifact overrides |
| Complete registered consumer integrity and extension activation | 45 assertions; pass |
| Public-registry cold export/install/software relocation | 235 assertions; pass |

The first FilterGraphPipeWire run used `--threads=4,1`; only two standalone
placement checks failed because that deployment contract requires `N,0`.
The corrected focused placement gate passed 3 assertions, then the full suite
passed with `4,0`. The unsupported-invocation failure log remains preserved.
RTC's separate message-worker selectors intentionally require an interactive
thread and retain their documented `3,1` / `4,1` layouts.

AOS's first release run found two existing pixel-integration kernels absent from
its CPU coverage inventory. Commit `7ee44940` adds actual Float32/Float64 kernel
execution against analytic geometry and scalar results, including invalid-flux
flags, before classifying them. The same KA CPU gate changes from 1,208 passes
and one inventory failure to 1,225 passes. No numerical production code changes.
The full run also exposed a redundant test-array constructor warning;
`06482bc8` removes that duplicate and its focused 76-assertion selector passes
without the warning. The full run's original warning remains in its log.

## Concurrent graph release

An independent controller release was already preparing FilterGraphPipeWire
0.5.1 and FilterGraphs 0.10. The endpoint release uses 0.5.2 to avoid replacing
that immutable version. The published controller code/evidence is merged
unchanged; FGPW's runtime source remains exactly `e9305cb87c3ac0acb86c329ccac2753b606c22bd`.
Its compatibility includes both graph versions, with 714 targeted assertions on
0.10 in addition to the full 0.9 gate. RTC 0.7 continues to select FilterGraphs
0.9; this work does not silently migrate RTC to 0.10.

## Public registry and installation receipts

All selected package versions are published in DarrylGamrothRegistry. The complete
consumer first resolved the exact release candidate from a private registry copy
with canonical public package repository URLs. After registry commit
`e01d79787d80cd7469ad4ebc3087e38f25d97ef4` was pushed, that copy was removed from
the consumer depot and the registry was cloned from GitHub. Re-resolution changed
neither Project nor Manifest. The same 45 checks and the 235-assertion cold
installation/relocation selector then passed against public registry metadata.

The [generated package/artifact receipt](registered-cohort.toml) records actual
versions, source trees and loaded artifact. The [consumer Project](consumer/Project.toml)
and [Manifest](consumer/Manifest.toml) reproduce the exact selected environment.
There are no path/repository tracking overrides, SDK preferences or artifact
Overrides.toml files. Every selected package tree and the complete JLL artifact
tree matches its immutable hash. Core import stays science-independent; optional
extensions activate only after their packages load. The installed application
manifest excludes the development workspace, source overrides and Test; no RTC
or test source trees are copied into the application.

A first consumer bootstrap failed because its generated compat string incorrectly
included JLL build metadata (`=4.0.2+0`). Regenerating the constraint as `=4.0.2`
fixed parsing; the manifest and verifier still pin/check build `4.0.2+0`. This was
validation-environment setup, not a package or native defect. The original log
remains `/tmp/rtc-complete-consumer-install-20261106.log`.

Published releases: [native SDK](https://github.com/DarrylGamroth/PipeWireAO/releases/tag/v4.0.2),
[JLL](https://github.com/DarrylGamroth/PipeWireAO_jll.jl/releases/tag/PipeWireAO-v4.0.2%2B0),
[PipeWireAO.jl](https://github.com/DarrylGamroth/PipeWireAO.jl/releases/tag/v0.9.2),
[FilterGraphPipeWire](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/releases/tag/FilterGraphPipeWire-v0.5.2),
[AOS](https://github.com/DarrylGamroth/AdaptiveOpticsSim.jl/releases/tag/v0.3.21)
and [RTC](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.0).
FilterGraphs itself needs no change for the borrowed-loop accessor. Its existing
0.10 controller release and [PR 47](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/pull/47)
are preserved; RTC's selected engine remains 0.9.

## Commands, artifacts and limits

Full and focused logs use `/tmp/rtc-release-*.log`,
`/tmp/fgpw-jll402-*.log`, `/tmp/pipewireao-jll402-*.log` and
`/tmp/rtc-fga-fg-core-DSiGGy/{fga,fg}.log`. The exact artifact metadata and build
commands are in the BinaryBuilder receipt above. The empty-depot check uses
`/tmp/rtc-cold-native-depot-20261106` and its log is
`/tmp/rtc-cold-native-public-20261106.log`. Final public metadata, consumer and
installation logs are `/tmp/rtc-complete-consumer-public-resolve-20261106.log`,
`/tmp/rtc-complete-consumer-public-check-20261106.log` and
`/tmp/rtc-release-public-cold-install-relocate-20261106.log`.

After resolving the listed versions from the public registry, run
`julia --project=CONSUMER verify.jl OUTPUT.toml` to verify package tree hashes,
registry tracking, inert core import, extension activation and actual artifact
libraries. Write the receipt to the checkout/evidence directory, not into the
installed package cache. The consumer Project and generated receipt identify the
final package trees separately from these earlier source gates.

Actual devices, new accelerator qualification, cadence and real-time deadlines
remain outside this CPU/package release. These actions do not deploy an RTC or
restart a live session.
