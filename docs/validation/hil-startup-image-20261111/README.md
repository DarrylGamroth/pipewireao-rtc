# HIL-owned optical startup images

AdaptiveOpticsSimPipeWireHIL now selects, builds, and configures loading of
managed CPU optical startup images. RTC selects the HIL source from the
application Manifest and calls its lightweight deployment interface. The
interface does not import HIL or AOS into the installer or launcher. HIL
configures image loading before the managed entry imports RTC dependencies.
An application Manifest without the interface uses the cold launch path.

## Test cohort

- Julia 1.13.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
  FilterGraphPipeWire 0.5.5, and AdaptiveOpticsSim 0.3.23.
- HIL `184da62` and RTC `0da9e26` (source tree `cdf5f77058db947ceb43c2133bd201898525770b`).
  The staged candidate trees were archived into a temporary depot and selected
  by tree hash in copies of the CAL2 simulator CPU and SPIDERS fitted-dual CPU
  exports. Dependencies came from existing validation depots. The package
  versions were unreleased candidates.
- RTC core suite passed. HIL's focused selector passed 11 assertions covering
  launch argument order, missing images, and CPU configuration selection. An
  additional check confirmed the cold fallback for absent and older HIL.
- Installation and systemd admission ran sequentially on separate private
  cores. Startup timing starts at the systemd start request, after the image
  build. Quit timing includes the stop hook and cleanup verification.

## Private-core results

| CPU profile | Install image build | systemd start to Ready | Quit and cleanup |
| --- | ---: | ---: | ---: |
| CAL2 simulator | 349.5 s | 349.1 s | 36.1 s |
| SPIDERS fitted-dual | 428.1 s | 463.8 s | 38.3 s |

Both simulator processes mapped the installed
`PipeWireAOOpticalStartup` shared object. Each session returned fresh Ready
and Running status. Each systemd stop hook received a correlated native
Quit completion and retained `systemd_quit.accepted=true`,
`service_result=success`, `cleanup_complete=true`, and
`unit_files_removed=true`. The private socket disappeared and all
session and owner units were inactive with zero MainPID. No SIGKILL was
recorded for those units. The installed Project and Manifest matched
their inputs byte for byte.

These are functional checks. The runs did not measure a speedup against
the previous implementation or qualify real-time behavior.
