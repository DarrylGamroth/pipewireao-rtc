# MediaSession admission on CAL2 with an independent source

The new MediaSession service reached Ready in **14.798 and 14.899 s**, inside the **13.743–15.200 s** range of the two former-helper restarts. Removing the additional Julia process reduced sampled startup CPU use, but these trials establish no elapsed-time improvement. [Per-run measurements](restarts.csv)

| Measured CPU build | Service request to Ready | Ready to first LLOWFS residual | Ready to first SCC pair residual | Startup leader CPU |
| --- | ---: | ---: | ---: | ---: |
| Former helper, optical run | 15.200 s | 4.267 s | 157.796 s | 11.978 s |
| MediaSession, first restart | 14.798 s | 20.159 s | 194.041 s | 9.923 s |
| MediaSession, second restart | 14.899 s | 22.954 s | 147.618 s | 9.984 s |
| Former helper, timing repeat | 13.743 s | — | — | 10.561 s |

The measured leader CPU total adds sampled main-thread CPU time for the preparation process, RTC, and former publication helper when present. It excludes other threads and independent graph and simulator services. The legacy repeat used the same prearmed clients and ended after Start to measure warm service timing. Two samples per build describe these activations only.

## Measurement boundaries

The service interval runs from the monotonic timestamp immediately before the systemd start request until that command returns successfully. The unit must prove its current RTC process, native endpoint, required owner placement, held graphs and ten newly negotiated Links. Ready permits inspection. A separate native Start admits incoming exposures with both integrators open.

The optical milestone is the first qualifying modal residual observed from a post-Start exposure. The observer matches camera, residual and physical offset by acquisition domain, generation, sequence and model time. SCC also requires the corresponding completed chopped pair. Each residual must be finite and each open-loop physical offset must be zero. An independent subscriber's timestamps include transport and observer scheduling. They measure availability to that subscriber.

The same independent CPU optical simulator supplied both cameras across RTC replacements. Its WFS streams have different acquisition cadences. Arrival time relative to the start request affects the optical results. This is software service and optical-stream validation on a shared workstation.

## Live evidence

All four timed restarts reached authenticated Ready with ten fresh Links and accepted native Start and Quit. Both full MediaSession runs reported Open before Start and Open and primed after receiving usable measurements. All eight captured residual values per controller matched the baseline's first qualifying values. Every checked physical offset was zero. The RTC never requested closure during this experiment.

- In the first MediaSession run, the LLOWFS residual came from exposure 52. SCC exposure 11 primed the pair and exposure 12 completed it.
- In the second run, LLOWFS exposure 64 and SCC exposure 14 qualified. The restart was aligned to the same preceding SCC chop parity as the baseline, within 18 ms of the same time since the preceding SCC camera observation.
- In the phase-matched run the SCC residual subscriber observed the answer 3.49 ms before the independent camera subscriber recorded that exposure. The subscriber timestamps cannot establish camera-to-controller compute latency. Including the physical-offset and pair confirmation receipts placed the complete SCC evidence at Ready +147.630 s. It was Ready +194.049 s in the first run and +157.804 s in the baseline.
- In a separate failed activation, pinning the new RTC main to CPU 5 violated the declared placement. The RTC exited with failure. systemd never reported active, the discovery watcher saw no locator for the invocation, and no session Links remained after cleanup. The first diagnostic attempt was interrupted by a permission error in the observer's process inspection and is excluded from that result.

## Build and verification scope

The tested application used Julia 1.13.3 with package images built before the timed service requests. The baseline was RTC `59e328d` and both measured MediaSession runs used `9ba551e`. The installed instrument declaration, PipeWire dependencies and graph-owner implementation were matched. Later changes to optional analysis and test fixtures do not run on this CAL2 profile. An intermediate engineering build at `1b90155` took 20.669 s while another application image was building. It is excluded from the timing comparison.

The full RTC suite passed 543 testsets. The installed stop fixture passed 122 assertions across 12 cases, including wrong process or session identity, missing or uncertain acknowledgements, and the historical pinned service type. A separate user-systemd test verified that optional analysis starts only for the exact active invocation and that delayed optional shutdown allows the RTC's native stop to proceed. Only CAL2 underwent the end-to-end optical restart measurement here.

Both camera domains and acquisition generations continued advancing with the same publishing processes after each RTC stop. The private services were retired after verification. The archive includes the native observations, per-frame receipts, launch and cleanup records, unit templates, package identities, host samples, harness and excluded trials. Its SHA-256 is `0578f88df4ea243289963abce378cbecac30ea45bf05f5a8c59daf0031e4e1cf`. [Raw receipts and reproduction harness](cal2-receipts.tar.gz)
