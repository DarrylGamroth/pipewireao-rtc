# Cancel optional analysis during startup

Native Quit dispatches `QuitRequested` to the MediaSession HSM. Optional
analysis follows the RTC unit lifetime through systemd's `PartOf` and
shares invocation cleanup. Its process termination is a systemd action.

In the [earlier Classic run](../managed-stop-20261111/README.md), systemd
sent SIGTERM while the optional worker was compiling the PipeWireNode
constructor. The journal showed Julia's signal backtrace in LLVM, followed
by the 15-second stop timeout and SIGKILL. Julia's SIGTERM path can stall
when its exit work reaches an occupied runtime thread. SIGHUP is outside
Julia's signal wait set. The optional analysis unit now uses SIGHUP with
its existing control-group kill policy, so the kernel can terminate the
worker and its children during compilation.
[Julia signal handling source](https://raw.githubusercontent.com/JuliaLang/julia/v1.13.3/src/signals-unix.c)

## Private-core verification

The Classic CPU application used Julia 1.13.3, PipeWireAO 0.9.2,
PipeWireAO_jll 4.0.2+0, FilterGraphPipeWire 0.5.5 and HIL 0.5.1.
Its temporary Manifest selected RTC candidate tree
`370dcfb6d58fed865bfcef2a7df73a8584ddc3b4`.

After admission, the test observed the WFS analysis service running with
`KillSignal=1` and a live Julia PID before its analysis-ready notice.
It requested the managed stop at that point, during early worker startup.
systemd stopped the WFS service 33 ms after beginning its stop job.
The complete managed stop took 41.7 seconds, including native Quit and
invocation cleanup.

The retained record showed one accepted Quit, `phase=stopped`,
`cleanup_complete=true` and `unit_files_removed=true`. All owner MainPIDs
were zero, the private socket was gone, and no invocation journal recorded
SIGKILL. Focused analysis, systemd owner and session stop tests passed.
