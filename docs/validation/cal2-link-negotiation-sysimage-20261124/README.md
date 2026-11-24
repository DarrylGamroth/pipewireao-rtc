# CAL2 restart with concurrent Links and an optional Julia sysimage

## What moved out of startup

The package image now includes the concrete callback, native binding, subscription
and Status client methods used by MediaSession. Build-time compilation does
not connect to PipeWire or send a frame. The RTC still discovers the current
processes, creates its Links and performs the held admission and public Status
checks on every invocation.

The six fresh processes below loaded the same Julia 1.13.3 dependency cohort.
The benchmark compared `00c5a6b` with `f108452`. The subsequent fix was
confined to reading the installed image identity from Linux process maps.
Each process requested compilation of the same 22 concrete method signatures.
The table gives median elapsed compiler time from three processes per version.
These measurements isolate missing native code at first use. They exclude
PipeWire negotiation, controller admission and service startup.

| First-use path | Method roots | Before | After |
| --- | ---: | ---: | ---: |
| Bind and listen to the registry | 6 | 428.84 ms | 0 ms |
| Connect and subscribe the admission client | 10 | 657.08 ms | 34.74 ms |
| Close the client and release its listeners | 5 | 191.39 ms | 0 ms |
| Request fresh public Status | 1 | 16.33 ms | 0 ms |

The median total fell from 1.294 s to 0.035 s. Imports took 1.210–1.275 s before and
1.279–1.357 s on the candidate.
The integrated RTC package cache grew by 2.58 MiB. Its build took 179 s.
These are package-cache figures, separate from the optional application sysimage. [Compiler probes and build receipts](admission-precompile-receipts.tar.gz)

## What changed in PipeWire

One MediaSession owner requests all eligible Links, then consumes their native
events. A downstream node’s outgoing Links must negotiate before its incoming
Links. Pairs sharing a port retain their previous relative order. Completion
of one branch can unblock its upstream Link while another branch is negotiating.
Ready still requires the complete declared topology, exact live identities,
negotiated formats, held execution and a fresh public Status.

On a private core with two disjoint port pairs, the previous implementation
submitted one Link before waiting. The new implementation submitted both
before consuming either bind notification. Cancellation withdrew both requests.
Other tests cover shared-port ordering, registry-only wakeups and withdrawal
when the deadline expires without another registry event.
[Private-core and owner test receipts](link-admission-checks.tar.gz)

## Installed build and verification

Installation checks the preloaded packages and extensions against the installed
project. The actual image passed with the original Manifest. Selecting registered
JSON 1.13.1 in place of 1.13.4 with the same RTC source caused the installer to
reject the image. Activation, Ready and native Quit verify the mapped image
using its device and inode. An image built for this CPU and installation needs
rebuilding when its pinned dependencies change. [Image provenance controls](sysimage-provenance-receipts.tar.gz)

The final full RTC suite passed 11,845 assertions across 556 testsets. An
earlier run caught an
intermediate callback that dropped one of PipeWire’s two enumeration cursors,
causing the admission client to time out while reading retained parameters.
Restoring the six native arguments passed all 47 private-core calibration owner
assertions and the full suite. [RTC test results](rtc-test-results.tar.gz)

## Installed restart experiment

The final deployments both use RTC `5d0a19527174e6d6ecaa26d50181f2b76fdfbe2f`
and application Manifest SHA-256
`22b275b633f8396b89014b2e28d60d51614cf17103912b188f46028947cf7a60`.
PackageCompiler 2.4.1 with Julia 1.13.3 built the application image for the
host CPU in 615.1 s. It contains 518,599,984 bytes (494.6 MiB), with SHA-256
`3ad7b0fb16262b6fc943291c70d99c7000a1eaced20998b5fe0a1a936030865d`.

An earlier comparison on `f108452` reached held Ready in 8.358 s on the default
image. Its application-image arm stopped before Ready. The kernel padded the
pathname in the MainPID mapping with spaces and the verifier included the padding
in its comparison. The final verifier skips the padding and still checks the
path, device and inode. The corrected image passed against its actual mappings.
The table below uses a fresh four-run block on the final build.
[Earlier installed attempt, process mappings and rejection](installed-cal2-padded-map-failure.tar.gz)

One independently running CAL2 simulator published the LLOWFS and SCC camera
streams on a private PipeWire core. It kept advancing and publishing across
RTC Quit. Both controller graph services were already running. Every activation
created a new RTC process and reacquired its Links and held owners. The only
experimental change between arms was the Julia system image loaded by the RTC.
The controller graph executables, calibrations, CPU placement, threading and
PipeWire libraries were identical. Neither graph used injected warmup data.

Time to Ready runs from the request to start the systemd service until that
request returns after MediaSession's held admission and fresh public Status.
Start is a subsequent operator command which allows the open graphs to process
live frames. A usable LLOWFS measurement pairs a fresh camera exposure with
its residual and zero correction output. An SCC result additionally needs the
two chopped inputs. Exposure arrival depends on the phase of the independently
running simulator when Start is acknowledged.

## Time to held Ready

| Activation order | RTC system image | Start request to Ready | RTC process CPU | Main thread runnable but waiting for a CPU |
| --- | --- | ---: | ---: | ---: |
| 1 | Julia distribution | 8.949 s | 6.82 s | 0.199 s |
| 2 | Application | 4.769 s | 4.07 s | 0.117 s |
| 3 | Application | 4.764 s | 4.06 s | 0.138 s |
| 4 | Julia distribution | 6.660 s | 5.92 s | 0.161 s |

The application image saved 4.179 s in the first pair and 1.896 s in the
reverse-order pair. Mean Ready time fell from 7.804 s to 4.767 s, a saving
of 3.038 s (38.9%). Mean RTC process CPU near Ready fell from 6.370 s to
4.065 s. The RTC main thread's observed runqueue wait was under 0.20 s in
every arm. The CPU counters are from the last process sample around the
service response. Service time also includes work outside the RTC process.
The two runs per image establish the observed range on this shared host.
They do not estimate a tail percentile, isolate the Link change's contribution
to service time, or establish a target instrument's restart deadline.

## Live open-loop measurements

| Activation | First complete LLOWFS output after Start acknowledgement | First complete SCC pair after Start acknowledgement |
| --- | ---: | ---: |
| 1, distribution | 30.302 s (exposure 110) | Not sampled |
| 2, application | 30.904 s (exposure 113) | 254.893 s (exposure 24) |
| 3, application | 31.464 s (exposure 123) | Not sampled |
| 4, distribution | 31.033 s (exposure 126) | 318.777 s (exposure 27) |

All four RTC invocations reached held Ready, rejected premature closure for
both controllers and produced a fresh LLOWFS residual with zero physical
offset after Start. In the two extended runs the SCC pair status also became
valid with zero physical offset. The system image shortened service startup.
Time to the next usable measurement includes the independently paced simulator
and, for SCC, the real chopped exposure pair. Each RTC accepted native Quit.

Through the post-Quit cutoff, all 141 LLOWFS exposures and all 28 SCC
exposures were staged, queued natively and drained by the independent receiver.
The receiver saw LLOWFS 136–141 and SCC 28 after the fourth RTC quit. Final
fixture teardown stopped its services and removed its private socket and units.
The [installed CAL2 receipts](installed-cal2-sysimage.tar.gz) contain the four
lifecycle records, frame identities, installation inputs, CPU samples, commands,
image verification and teardown checks. These measurements used CPU optical
simulation on the development workstation.
