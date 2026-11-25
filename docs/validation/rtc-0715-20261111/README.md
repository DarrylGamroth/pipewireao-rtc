# RTC 0.7.15 release verification

- Release commit `82bdb9d422e3f8a5af10f6732cc4565b30e9919c` and
  [tag v0.7.15](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.15).
- Registered source tree `9e039723521915e3505f240ca8c629fd5f62c43c` in
  [DarrylGamrothRegistry at 5768688](https://github.com/DarrylGamroth/PackageRegistry/commit/5768688638cc4f4dc7186a50262e81385357af33).
- The tagged source and tests match the
  [verified RTC and owner precompilation changes](../classic-quit-event-20261111/README.md).
  The release commit updates only the package and workspace Manifest versions.

## Fresh Classic CPU installation

The test copied the [0.7.14 Classic application](../rtc-0714-20261111/README.md)
and changed the temporary RTC compat entry to `=0.7.15`. Pkg resolved the
application on Julia 1.13.3 in a fresh depot using General and
DarrylGamrothRegistry. Every other Manifest dependency entry matched
the 0.7.14 environment. The installed RTC source matched the public
release tree. There were no source or artifact overrides.

Pkg precompiled the selected dependencies in 279.9 s before launch.
The installed Project and Manifest matched the resolved application
byte for byte. Both checks used the installed systemd commands,
the PipeWireAO_jll 4.0.2+0 daemon on a private core, and passive
sampling of the launch record and owner processes.

## First launch

Classic reached Ready in 359.8 s. The test requested managed stop
while WFS analysis was still starting. The analysis worker stopped
in 58 ms. The launch record's Quit submission fence was first
observed 8.42 s after systemd began stopping the session.

The RTC logged that its effect deadline expired. The client recorded
an attempted Quit without an accepted acknowledgement. Fallback
cleanup completed after 29.79 s of total managed stop time. It removed
the invocation unit files and private socket, and all owner MainPIDs
were zero. No SIGKILL was recorded. This run failed the native Quit
gate and does not establish clean native shutdown timing.

## Repeat on a new private core

The repeat reused the same installed application and fresh-depot package
caches. Classic reached Ready in 423.8 s. Stop began before the optional
WFS analysis worker reported ready. It had used 2.095 s of cgroup CPU
time and stopped in 66 ms.

| Measurement | RTC 0.7.14 release | RTC 0.7.15 repeat |
| --- | ---: | ---: |
| Managed stop elapsed | 14.71 s | 16.14 s |
| Stop job to submission fence observed | 4.59 s | 5.54 s |
| Submission fence to accepted Quit observed | 5.40 s | 5.05 s |
| First post-stop sample to core PID gone | 2.61 s | 3.19 s |
| Private core stop job | 9 ms | 9 ms |

RTC acknowledged native Quit. The invocation recorded a successful
service result, complete cleanup and removed unit files. The private
socket was gone, all owner MainPIDs were zero, and no invocation jobs
or SIGKILL entries remained.

The release check reproduced clean native Quit on the second launch.
It did not reproduce the local candidate's 12.42 s managed stop or
establish a consistent wall-time improvement. The timings exclude
package precompilation and launch.
