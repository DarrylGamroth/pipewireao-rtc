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

## Publication and public-registry verification

Main integration, tag/release publication and LocalRegistry registration are
in progress. The final public consumer will resolve all nine package versions
from the public registry without the temporary candidate registry or local
source paths, then verify package/artifact trees, extension activation and cold
export/install/software relocation. Final identities and results will be
recorded after these gates complete.

The release does not replace installed applications or start/stop a session.
CPU/package verification does not qualify new hardware, accelerator behavior,
cadence or real-time deadlines.
