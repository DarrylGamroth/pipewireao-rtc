# RTC 0.7.9 release and GPI2 private-core verification

RTC 0.7.9 starts the shared native Quit effect deadline when the RTC admits
Quit and honors an earlier client deadline. The release tags commit
`79ddbee40525877f267f7f4ad97e7c6992cfba20` and registers tree
`6a9ed7b7f759ade5bbc18339ad4ad0776d07ac97`.
[Release](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.9),
[Registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/3c671408fce93e464451598e673f9af73ecceefa),
[Deadline trace and regression](../gpi2-quit-admission-clock-20261110/README.md)

Pkg refreshed the RTC workspace Manifest for version 0.7.9. The core
suite passed 10,907 assertions in 11 min 50 s on Julia 1.13.3 with the
PipeWireAO 4.0.2 artifact. The workspace Manifest SHA-256 is
`bb77b877aac06c21fdef92e48e06c587950c75da1f5302783f031eea00b7ea20`.

## GPI2 registry-only install

The run began with an empty Julia depot. Pkg fetched General at tree
`85379065f6fab71fc829afb4c8ffda8e8da68e77` and DarrylGamrothRegistry at
`3c671408fce93e464451598e673f9af73ecceefa` from its public GitHub repository.
Pkg resolved the GPI2 Project from instrument commit
`76c958c634e5145bec1c6400bc14a5a2ffad95c0` with the RTC 0.7.9 pin. The
resolved Manifest differed from the RTC 0.7.8 GPI2 release run only in
the RTC entry. Its SHA-256 is
`42905dfc8f11e0c7242074f2d47d1f7a30a33ced7bb571abfbedb01e4774cdfd`.
The resolved, exported and installed Projects and Manifests matched byte
for byte.

The test checked all eleven selected package source trees against Pkg's
registry hashes. The cohort included FilterGraphs 0.10.2,
FilterGraphAlgorithms 0.12.2, FilterGraphPipeWire 0.5.4, PipeWireAO 0.9.2,
PipeWireAO_jll 4.0.2+0, PipeWireAOQueue_jll 0.1.0+0,
AdaptiveOpticsCalibration 0.17.3, AdaptiveOpticsSim 0.3.22,
AdaptiveOpticsSimPipeWireHIL 0.5.1 and Proper 0.4.1. The session and all
three Julia owners used the fresh depot with no development dependencies
or artifact overrides.

## Startup and native Quit

The installed managed GPI2 CPU profile used the same 10 Hz host
configuration and 900 s service budget as the [0.7.8 check](../rtc-078-20261110/README.md).
Dependency resolution and installation took about 4 min 52 s. Export
and package precompilation took 10 min 47 s before the service started.
Systemd reached Ready in **445.49 s**, and a native Start
transitioned the admitted session to Running.

The installed stop hook attempted one native Quit and recorded
`systemd_quit.accepted=true`. Systemd reported success. The RTC and all
four owner services were inactive with no main PID. Cleanup removed the
private socket and unit files. Their journals recorded no SIGKILL. The
full stop and reconciliation took 67.82 s, including service cleanup
outside the native Quit effect. The GPI2 pin was merged after this check.
