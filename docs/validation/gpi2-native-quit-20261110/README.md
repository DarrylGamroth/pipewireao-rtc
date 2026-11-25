# GPI2 native Quit on the managed CPU profile

## Failure and correction

The RTC 0.7.7 release check reached Running and passed both operator
controls, then lost the native Quit reply from the session. The stop hook
recorded an unknown outcome and systemd emergency cleanup removed the
private core and its owners. [RTC 0.7.7 release verification](../rtc-077-20261110/README.md)

A fresh private-core run reproduced the failure with temporary timing probes
around the RTC's effects and bootstrap owner requests. The final Status reply
and the failed ShutdownOwners effect were 6.53 s apart. The RTC's cumulative
Julia compile counter advanced by 3.04 s in that interval. Within
ShutdownOwners, entering the first owner's retirement took 1.119 s, including
1.115 s of Julia compilation. The simulator returned its stopped receipt.
The shared Quit deadline expired during controller retirement, before the
parameter owner could receive Quit. The launch record retained
`systemd_quit.accepted=false` and confirmed emergency cleanup.

The RTC previously prepared the shutdown backend for Configuring jobs.
Ready and Running use different job types, so they could compile when the
shutdown effect already had a deadline. Preparation now covers all three
origins and explicitly compiles the bootstrap retirement method reached
through the abstract owner collection. The probes are absent from the
verified candidate. The patch preserves the existing Hsm sequence, ownership
checks, one-shot Quit and five-second effect budget.

## Verification

The instrument source was `6a1fbfddb7bf03212077a8f512af661d9b0ecc27` with
Julia 1.13.3, FilterGraphPipeWire 0.5.4, FilterGraphs 0.10.2, standalone HIL
0.5.1 and the registered PipeWireAO 4.0.2 SDK and queue. Each diagnostic
application used the previously exported CPU profile with only the RTC
source tree changed in its Pkg Manifest. The instrument configuration and
workstation placement were the same as in the release check. The source
trees were `d249f2fb38d6d32edd5176f359a4cf0efb8b6a76` for the timing probe
and `2aaf03645d1808cd87e0f2efaa53b9729b8dbd23` for the candidate.

The candidate reached Ready after 494.56 s within the 900 s startup budget.
The session was Running before the managed stop. The installed ExecStop
sent one native Quit and recorded a successful correlated Offline
completion. The retained record reported `phase=stopped`,
`service_result=success`, `systemd_quit.accepted=true` and
`cleanup_complete=true`. The session and all four owner services became
inactive, the private socket was removed, and the journals recorded no
SIGKILL. The systemd stop took 57.24 s end to end, including the client
process's startup and the cleanup hook. That interval measures the whole
managed stop.

The seven focused RTC selectors passed 1255 assertions, including private
Link withdrawal and native process Quit, interrupt and publisher-exit cases.
