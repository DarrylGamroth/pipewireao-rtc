# RTC 0.7.1 publication

Date: 2026-11-07. Source baseline: migration commit
`00b2b28368ba5289e45bf291347f9127d0b06c02`, based on cleanup `0048cfc`.
Release branch/worktree: `codex/rtc-071-release-20261107` /
`pipewireao-rtc-release-071`. Both source worktrees were clean. Original main
and cleanup worktrees, installed applications and live sessions are preserved.

## Release scope and retained verification

RTC 0.7.1 selects FilterGraphs 0.10.0 with FGA 0.12.0, FGPW 0.5.2,
PipeWireAO 0.9.2 / JLL 4.0.2+0, AOS 0.3.21, HIL 0.5.0 and calibration 0.17.3.
The [migration receipt](README.md) records the unchanged production code,
separately corrected optional test data and all verified package gates. Release
preparation changes only documentation; dependency metadata and runtime/test
implementations remain identical to the verified migration.

Full CPU gates are reused: RTC core 11,049, FilterGraphs 23,459, FGPW 2,921
plus 6 child assertions, fourteen RTC science selectors 826 and private-core
selectors 512. Unchanged native/PipeWireAO/FGA/AOS sources and artifacts retain
their [cohort release evidence](../rtc-cohort-402-20261106/README.md).

## Published identities

The verified migration was fast-forwarded into remote main with its three
commits preserved, followed by the documentation-only release preparation.
The annotated `v0.7.1` tag points to that release preparation commit. No published
history or existing tag was rewritten.

| Identity | Value |
| --- | --- |
| Release commit | `90efe78273de5ab90fee19135f828fbc77bbeff9` |
| Registered RTC package tree | `2d77e822939061b8d1d73efad1d647e749b7ef8c` |
| Annotated tag object | `7e42430883e7a20b90993ebe405bba6c89dfab10` |
| Public registry commit | `c484d81daa23545d7e09dfdf605a2c6c5c905735` |

[RTC 0.7.1 is public](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.1)
and [registered in DarrylGamrothRegistry](https://github.com/DarrylGamroth/PackageRegistry/commit/c484d81daa23545d7e09dfdf605a2c6c5c905735).
LocalRegistry generated the registry changes. Older version hashes are
unchanged; FilterGraphs 0.9 remains selected through RTC 0.7.0, while 0.7.1
selects 0.10. The temporary candidate registry was not published or used for
the final consumer.

The GitHub release was kept in draft during the public-registry gates, then
published after both passed. The [captured release metadata](publication.json)
is generated directly by `gh release view v0.7.1 --repo
DarrylGamroth/pipewireao-rtc --json
name,tagName,isDraft,isPrerelease,publishedAt,url,targetCommitish`. This strict
JSON capture retains the API output without an injected header.

## Final public-registry verification

| Gate | Result |
| --- | --- |
| Registry-tracked consumer, source/artifact integrity and extension activation | 45 assertions; pass |
| Cold export/install/software relocation from the registered package | 235 assertions; pass |
| Documentation links, structure and requirement-ID preservation | Pass |

Both runtime selectors exit 0. A fresh consumer Project/Manifest resolves all
nine exact package versions from the actual public registry at `c484d81`, using
the existing public package/artifact cache. No candidate registry, local source
path, repository-tracking override, SDK preference or artifact override is
present. The core import remains independent of optional science packages;
loading the selected science packages activates the expected RTC extensions.
Each package filesystem tree and the loaded AVX2 artifact tree matches its
immutable hash. The artifact remains
`b84754cc61ae9a8e33d31ec4352f188fa5405581` with native library version 4.0.2.

The [generated public cohort receipt](public-cohort.toml) records the actual
versions, source paths and trees. The [public consumer Project](public-consumer/Project.toml)
and [compressed Pkg-generated Manifest](public-consumer/Manifest.toml.gz)
preserve the exact resolved environment. The registered RTC tree differs from
the [earlier candidate receipt](cohort.toml); the final consumer checks that
registered release tree rather than reusing the candidate source. The cold
installation selector runs from the newly installed registry package and
checks that exported applications depend on RTC without copying its package
or development tests into deployed runtimes.

The [compressed publication archive](publication.log.gz) preserves setup and
verification scripts, registration/install/check logs and release notes from
`/tmp/rtc-071-*-20261107.*`. The 45-assertion verifier is unchanged from the
candidate gate except for its generated receipt's provenance header; expected
versions already match the final cohort. Generated manifests, registry records
and receipts were produced by their owning tools, without hand-edited hashes.

The first final documentation check preceded archive generation and reported
one missing archive link. Generating the archive and rerunning the same check
resolves that packaging-order failure; its original log is preserved alongside
the final passing result.

An independent read-only publication audit confirms source/tag/registry
agreement, the consumer's registered source selection, unchanged runtime and
test metadata, and preservation of historical registrations. The final
evidence-only commit does not alter runtime code or dependency metadata and
does not move the release tag.

The release does not replace installed applications or start/stop a session.
CPU/package verification does not qualify new hardware, accelerator behavior,
cadence or real-time deadlines.
