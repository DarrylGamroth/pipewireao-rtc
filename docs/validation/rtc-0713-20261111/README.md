# RTC 0.7.13 release verification

- Release commit `fffa1997a42b60241586737ad4284bc698cf27e6` and
  [tag v0.7.13](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.13).
- Registered tree `88e51a3d460e20d97901dc5a03d64808ee995c6a` in
  [DarrylGamrothRegistry at dc7f4cb](https://github.com/DarrylGamroth/PackageRegistry/commit/dc7f4cb23f0fb32e6b1c30684af6d76f021b348f).
- The full RTC core suite passed on Julia 1.13.3 with the registered
  PipeWireAO JLL artifact selected as the native prefix.

## Classic CPU on a private PipeWire core

The test copied an existing exported Classic CPU application into a
temporary directory and changed its RTC compat entry from `=0.7.9` to
`=0.7.13`. Pkg resolved the application using General and
DarrylGamrothRegistry in a fresh depot. It pruned Proper, AcceleratedKernels,
ArgCheck and GPUArraysCore from the lock. Every other dependency entry
was unchanged, including PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
FilterGraphPipeWire 0.5.5, FilterGraphs 0.10.2, AdaptiveOpticsSim 0.3.22 and
AdaptiveOpticsSimPipeWireHIL 0.5.1.

The resolved Manifest was current and had no path or repository overrides.
The installed RTC source tree matched the registered hash. The private
core used the JLL artifact with no artifact overrides.

Classic reached admission in 925.6 seconds of elapsed `systemctl start`
time. This run encountered simulator precompile linker crash traces while
the user runtime filesystem was 99% full. Compiled caches from completed
test invocations were moved to disk during the run. The simulator also
logged world-age and missing-cache warnings during startup. This run
establishes admission and cancellation under those conditions.

The test requested managed stop while the WFS analysis worker had a live
Julia PID, had loaded libLLVM, and had consumed 2.084 seconds of cgroup CPU
time. The worker had yet to emit `PIPEWIREAO_ANALYSIS_READY`. systemd
stopped the worker in 38 ms using SIGHUP. The full managed stop took
66.0 seconds and recorded an accepted native Quit, successful service
result, complete cleanup and removal of the invocation unit files.
The private socket was gone, all owner MainPIDs were zero, and the
invocation journals contained no SIGKILL. The installed Project and Manifest
matched the tested application copies byte for byte.
