# RTC 0.7.8 release and GPI2 registry-only verification

RTC 0.7.8 includes precompilation for admitted Quit effects and bootstrap
owner retirement. Pkg refreshed the workspace Manifest with the new RTC
version and `PipeWireAOQueue_jll` 0.1.0+0. The release tags commit
`20897c905de6b7a1034a79d66f61ded2dac89428` and registers source tree
`11fe48eec7f189e58bf54f48bf1feeb165bf91cb`.
[Release](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.8),
[Registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/ad096286b2f81deb08dd45f17900bcf1cd8502cc)

The full RTC core suite passed 10,823 assertions in 12 min 28 s on Julia
1.13.3. It used the resolved package workspace and the PipeWireAO 4.0.2
artifact. The workspace Manifest SHA-256 is
`ff7e0b4f369fe46a80ffe8349c29d7f8b1d38d8a631ca09f54d856634759f13b`.

## GPI2 installed profile

The test started with an empty Julia depot and fetched General at tree
`0b065fa97e125eb10451c1c5ce96a5088d2e817e` and DarrylGamrothRegistry at
`ad096286b2f81deb08dd45f17900bcf1cd8502cc`. It exported the managed GPI2 CPU
profile from instrument commit `6a1fbfddb7bf03212077a8f512af661d9b0ecc27`
with the proposed RTC 0.7.8 pin. FilterGraphPipeWire remained at 0.5.4.
The installed Project and Manifest matched the resolved files byte for
byte. The GPI2 Manifest SHA-256 is
`4be503018e91c66e6fd03aba68339340d8609ddb2f6752947b4aa49aeb1a5872`.

The source hashes of 11 packages matched the registry, including the RTC
release, FilterGraphPipeWire and both JLLs. The test used the PipeWireAO
4.0.2 artifact and the registered queue artifact with no source or artifact
overrides. The RTC and its Julia owners used the fresh depot. Compared with
the 0.7.7 registry run, Pkg selected PrecompileTools 1.4.0 in place of 1.3.4
as the only other source version change. Its effect on Quit is unmeasured.

The test used the same 10 Hz CPU host profile and systemd startup budget as
the 0.7.7 registry check. Export and package compilation took 9 min 14 s.
The installed private core reached Ready in **516.36 s** of the 900 s
budget, and a native Start reached Running.
[RTC 0.7.7 registry check](../rtc-077-20261110/README.md)

## Native Quit failure

The installed stop hook attempted native Quit once. The RTC reported
`Session effect expired; outcome unknown` and `object is not captured`
during cleanup. The simulator reported `native owner request deadline
expired`. The controller and parameter owner later reported that their
retained bootstrap controller had been revoked. The stop hook lost its
owner proxy and retained `systemd_quit.accepted=false`. The available logs
do not identify what consumed the remaining deadline in this run.

Systemd recorded a failed service and confirmed emergency cleanup. The
private socket and unit files were removed, the session and all four
owners exited, and their journals recorded no SIGKILL. The GPI2 pin failed
its release gate and instrument main retains RTC 0.7.7. The earlier passing
candidate run remains evidence for that tested cohort.
[Candidate verification](../gpi2-native-quit-20261110/README.md)
