# RTC 0.7.12 and HIL 0.5.4 release verification

The package tags and their registered source trees were verified in a depot
created empty for this run. Pkg used General and DarrylGamrothRegistry at
`66ced109be7c51177ad3ac24638cf6bb19aad149`. The release sources matched
their tag and Manifest tree hashes.

| Release | Tag commit | Source tree |
| --- | --- | --- |
| [PipeWireAORTC 0.7.12](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.12) | `e31ff952d9afeaee5b50356120d8ce69be539c14` | `08b8ae662f7c6cf8608ababee36f6a8ec8eed394` |
| [AdaptiveOpticsSimPipeWireHIL 0.5.4](https://github.com/DarrylGamroth/AdaptiveOpticsSimPipeWireHIL.jl/releases/tag/v0.5.4) | `0508c3ed2482c4d80aeadf2bcb82129b5f598894` | `8eb63d291eb5f18120bd3637f6603c3cf49c9949` |

The temporary lock advanced only these two packages from instrument main
`97fbb822374730a6aff8adcca7bd37230a6460c8`. The instrument projects and
tracked Manifest were unchanged. The cohort used Julia 1.13.3,
AdaptiveOpticsSim 0.3.23, FilterGraphAlgorithms 0.12.2, FilterGraphs 0.10.2,
FilterGraphPipeWire 0.5.5, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0 and
PipeWireAOQueue_jll 0.1.0+0. The runtime used the JLL artifact with no SDK
overlay, source overrides or path dependencies. Export and install preserved
the selected Project and Manifest byte for byte.

The RTC core suite, HIL image selection and launch order selector, and
standalone HIL external-pupil execution selector passed before publishing.

## Private-core checks

CAL2 used the simulator CPU profile and SPIDERS used the fitted-dual CPU
profile. Each exported from instrument main and ran in a separate private
systemd invocation. The service startup measurements exclude export and
image building. Quit includes retained cleanup verification.

| CPU profile | Install-time image build | Start to Ready | Quit and cleanup |
| --- | ---: | ---: | ---: |
| CAL2 simulator | 201.3 s | 253.9 s | 39.0 s |
| SPIDERS fitted-dual | 237.2 s | 222.1 s | 34.2 s |

Both simulator processes mapped the installed `PipeWireAOOpticalStartup`
shared object. Each session reported fresh Ready and Running status. Each
systemd stop hook received the correlated native Quit acknowledgment.
Both retained ledgers recorded `phase=stopped`,
`systemd_quit.accepted=true`, `service_result=success`,
`cleanup_complete=true`, and `unit_files_removed=true`. The private sockets
disappeared and the session and owner units were inactive with zero MainPID.
The journals recorded no SIGKILL for those units.

These checks verify startup and cleanup in CPU simulation. They do not
qualify hardware or real-time performance.
