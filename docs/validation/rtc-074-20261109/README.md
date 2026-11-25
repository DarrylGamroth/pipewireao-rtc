# RTC 0.7.4 telemetry queue export

[PipeWireAORTC 0.7.4](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.4)
tags `edf047aa9db373f69a3c1e7c4351fa4a863ebb77`.
[DarrylGamrothRegistry](https://github.com/DarrylGamroth/PackageRegistry/commit/0dfdb0d13ed0a04d7ca19de415ed01e0772c0db1)
records the same tree, `5eef03f0ef911470358442cb9b6e1aada97dfd14`.

Julia 1.13.3 instantiated a copy of the updated instrument Project in an empty
depot using General and DarrylGamrothRegistry. The General tree was
`aaf931b400f2d87e8beef9ac05c6a5a4e03a95e4`. The two instrument Projects were
identical. The resolved Manifest contained 200 dependency records with RTC as
the only change in version or tree hash from the previous fitted-dual
validation. Its SHA-256 was
`8f12fd103f4c495906b64a3fda384b3dccc0487e3ca8c2bee23c3361fa21bc39`.
All 51 environment checks passed, including registry tracking, source tree
hashes, Manifest consistency and availability of the separate queue artifact.

The instrument `tools/build.jl` entry point exported the profiles below using
their `cpu.yaml` selections, the example CPU host files and the resolved
Manifest. Both SPIDERS exports used the fitted-controller host file. Each
sealed application passed deployment validation and retained the exact Project
and Manifest. The checks covered the linked producer format and core ownership
of each generated queue sink.

| Profile | Links | Derived queue sinks | Export checks passed |
| --- | ---: | ---: | ---: |
| SPIDERS fitted dual controller | 21 | 16 | 264 |
| CAL2 simulator with controller | 10 | 8 | 133 |
| SPIDERS fitted single controller | 10 | 6 | 101 |

The fitted-dual core and session files matched the previous verified export
byte for byte. The ownership map also matched. An interrupted export was
retried from the same registry-only installation. The final run exited zero
and covered software export and configuration.

The instrument branch was fast-forwarded to main after the three exports
passed. [Instrument pin update](https://github.com/DarrylGamroth/adaptive-optics-simulations/commit/0f378a14c5e088371521205eaf41ac177eb54255)
