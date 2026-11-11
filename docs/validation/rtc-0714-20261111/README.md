# RTC 0.7.14 release verification

- Release commit `84e1e8ce2ad01c12d8ba8c4ed4bffd4164cfa434` and
  [tag v0.7.14](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.14).
- Registered source tree `860070a6aa70f14c5ffcf7f7fec304dc9a7c2ea8` in
  [DarrylGamrothRegistry at 7e6511c](https://github.com/DarrylGamroth/PackageRegistry/commit/7e6511ce91a626d2163631eb40c7d9f933c8fa83).
- The release kept the source and tests from the
  [verified precompilation candidate](../classic-stop-precompile-20261111/README.md).
  Its release changes update the package and workspace Manifest versions.

## Fresh Classic CPU installation

The test copied the exported Classic CPU application used for the
[0.7.13 release check](../rtc-0713-20261111/README.md), changed the
temporary RTC compat entry to `=0.7.14`, and resolved with Julia 1.13.3
using only General and DarrylGamrothRegistry in a new depot. Every
other Manifest dependency entry was unchanged. The installed RTC
source matched the public release tree. The resolved environment
had no path, repository or artifact overrides.

Pkg precompiled RTC and the selected application dependencies in 209.8 s
before launch. The installed Project and Manifest matched the resolved
application byte for byte. The test ran the installed systemd units
with the PipeWireAO_jll 4.0.2+0 private core. Classic reached Ready in
333.4 s from `systemctl start`.

## Managed Quit

The test requested stop while the optional WFS worker was still starting.
The worker had loaded libLLVM and used 2.020 s of cgroup CPU time, and
it had yet to report ready. systemd stopped it in 56 ms.

| Measurement | Release run |
| --- | ---: |
| Managed stop elapsed | 14.71 s |
| Stop job to Quit submission fence observed | 4.59 s |
| Submission fence to accepted Quit observed | 5.40 s |
| First post-stop sample to core PID gone | 2.61 s |
| Private core stop job | 9 ms |

The normal installed hooks ran with a read-only observer sampling the
launch record, control PID and owner processes about every 87 ms.
The result is consistent with the [15.46 s local candidate run and
60.84 s clean baseline](../classic-stop-precompile-20261111/README.md).
Those were separate runs under different host conditions.

The session recorded an accepted native Quit, successful service
result, complete cleanup and removed invocation unit files. The private
socket and all owner processes were gone. No invocation jobs or SIGKILL
entries remained.
