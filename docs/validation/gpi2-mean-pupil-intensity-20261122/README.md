# GPI2 mean-pupil-intensity display

## Published versions after the upstream rebase

FilterGraphPipeWire 0.5.11 at `e50809c` has package tree
`601d7d8e32d4a818e3410b3c66bc943a0eca1ee0`. PipeWireAORTC 0.7.29 at
`01c5537` has tree `3dc5cbca8c11f5035a1ac8a4ef11a26cf340d5a8`.
The GPI2 instrument at `356f441` pins both versions. A fresh GPI2 project
resolved these pins from the public registry without a prior Manifest or either
package in its depot. Both downloaded source trees matched the registry and
the trees used for replay. The fresh resolve also passed all 30 exported profile
checks. [Graph-host tag](https://github.com/DarrylGamroth/JuliaFilterGraph.jl/tree/FilterGraphPipeWire-v0.5.11) · [RTC tag](https://github.com/DarrylGamroth/pipewireao-rtc/tree/v0.7.29) · [Registry entries](https://github.com/DarrylGamroth/PackageRegistry/commit/d1f51fb7ba29e872b1a2832134a0782591670554) · [Instrument](https://github.com/DarrylGamroth/adaptive-optics-simulations/commit/356f441101968b42415698b796e5db217cdc9e34)

With the released cohort's other dependencies held fixed, all 62 command
triples in each rebased profile matched the 0.7.28 capture byte for byte.
The live replay held a viewer buffer, removed the optional Link, observed
serial 153 replaced by 229, and checked scalar identities after reattachment.
The rebased RTC passed 10,638 core assertions and 394 focused assertions.
The graph-host observer passed 132 assertions with registered graph
dependencies and again with the rebased monorepo sources. The responsive
native woofer fixture passed all 19 assertions. The installed lockstep
simulator's acknowledgement after required woofer loss remains open.
The installed fault evidence below belongs to the pre-rebase cohort. The later
[shared simulator and RTC review](../../reviews/20261123-lockstep-faults/REVIEW.md)
records a confirmed Hold on the candidate and a separate ordinary Pause defect.

## Initial qualification sources

| Component | Revision |
|---|---|
| PipeWireAORTC | 0.7.29 candidate `7af920a`, package tree `cd4ed2df33c40b4a1e0b0619524cb6bb9a2d9266` |
| FilterGraphPipeWire | 0.5.11 candidate, package tree `601d7d8e32d4a818e3410b3c66bc943a0eca1ee0` |
| GPI2 instrument | `356f441` versus detector-tap baseline `aaa7022` |
| Environment | Julia 1.13.4, PipeWireAO.jl 0.9.6, native SDK 4.0.8, queue module 0.1.0+0 |

The private registry install changed exactly these two Julia package entries in
the released instrument Manifest. The sealed Manifest SHA-256 was
`3e311f686f7b736b7822cd20bd5ffd88fd91cbc0412c71b3a8b266c6afece042`.

## Export and runtime

The logical graph, parameter bindings and all 29 bound FITS assets compare byte for byte. The optional scalar
leaves the native controller output group in both exports. The live profile
deploys a latest-value publisher and a native capacity-one copy/drop-oldest
queue. A profile that omits the pupil-intensity view omits this publisher and
queue. Both session declarations match the baseline after removing the scalar
Port, sink and capture Link. The required woofer, tweeter and tip/tilt Links
remain. The native export checks passed 30 assertions.

The two native publisher fixtures passed 40 assertions. They verify retained
loans, return of fresh acquisition metadata, the native GUI queue identity and
replacement of the optional ingress Link. The graph-owner selectors passed
110 assertions. The FilterGraphPipeWire tests included a throwing observer and
a zero-allocation check on a warmed frame callback. The final RTC core suite
passed 10,641 assertions.

The native publisher accepts the queue's negotiated input pool. An earlier
candidate offered exactly two buffers and failed on the first attached sample
in the instrument replay. The native queue needs three for capacity one. The
bound on pending frames is independent of the upstream pool size.

The initial graph-host revision cleared the observer during native
deactivation. A proxy error can deliver that callback on the main loop while
an admitted frame is completing on the data loop. Commit `d4045d0` leaves
the last valid observation in place through Stop and clears it on a stopped
Graph Reset. The regression failed on the earlier revision and passed on
the corrected host along with all 132 focused observer assertions. Previously
delivered loans retain their acquisition identity and timestamp across Reset.

## Science across viewer loss and attachment

The released graph owner and the two candidate owners each processed the
same 62 changing detector images from the GPI2 corpus, exposures 1,001–1,062.
On native acquisition 18 the viewer retained a buffer. It detached at 28,
the optional ingress Link was removed, and the viewer reattached at 45. The
Link serial changed from 152 to 229 and the scalar matched its acquisition
after reattachment. All 62 woofer, tweeter and tip/tilt triples matched a
separate logical-graph replay and each other across the three cases, with
acquisition identity, PTS and exposure duration checked in each run. The
595,944 concatenated command bytes shared SHA-256
`7d36ad7d31f3dd0d980fb639994c4830a66ff495bea0dd565d6f39b2493c7d3e`.
The input was paced to check identities and numerical equality. This CPU
qualification establishes neither the 500 µs deadline nor physical corrector
application.

## Required Link policy

The production MediaSession fixture used real PipeWire Links and the exported
woofer port contract. All 19 checks passed against the final Julia package
trees. Removal of the woofer Link in Running entered Fault and produced a
stopped native Run acknowledgement, token 4 after token 3, at stable source
sequence 9. The graph and corrector endpoints survived the injection. The
fixture uses a responsive test source.

## Installed GPI2 source

The final installed profile reached Ready in 81.1 s. With the display detached,
removing the optional ingress Link replaced serial 203 with 311 while all 31
managed Links retained their identities. The simulator stayed Running with
token 11, its sequence advanced from 12 to 20, all three command observations
advanced, and reattachment delivered fresh scalar data. [Managed display
receipt](display-attachment.json) · [Independent command comparison](science-commands.txt)

In that same invocation the test removed required woofer Link 253/254
(native ID/serial) after observing source acquisition 201. MediaSession
entered Fault. A socket trace identified stopped-Run token 27 in the RTC
send and the simulator receive. No matching stopped acknowledgement was
observed. The RTC reported that Fault cleanup expired. The simulator later
timed out waiting for command set 208. The qualified result is **Hold
delivered, applied Hold unconfirmed**. The pre-migration managed simulator
also failed to confirm Hold after required Link loss.

The source consumes the control mailbox between lockstep exchanges. A wait
for the lost corrector could strand a staged Hold, but this run did not
observe the internal mailbox consumption point. Qualify cancellation of an
incomplete exposure and the source's correlated acknowledgement before
deployment. Local qualification used versioned trees in a private registry.
[Wire receipt](hold-wire.json) · [Source and Link observations](woofer-hold.json)
· [Installed session journal](journal.txt.gz)
