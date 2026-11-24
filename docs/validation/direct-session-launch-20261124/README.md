# Direct RTC startup and graph restart checks

## Installed service

Systemd starts the pinned RTC executable once. The main process validates the
installation and claims the current invocation. The same process connects the
declared PipeWire Links, admits the held graph and signals Ready. The unit
pins the SHA-256 of the installation description. A replacement checks the
recorded executable, application manifests and calibration file identities.
A Git-backed installation also checks the pinned export. Native admission
checks the current process, graph owners, control endpoint, negotiated Links
and CPU placement. The [startup procedure](../../SYSTEMD_SESSION_STARTUP.md)
defines the operator-visible sequence.

The legacy comparator runs its preparation command before starting the RTC
main process. Both commands load the same RTC implementation as the direct
service. During the comparison the independent optical source keeps its model
clock and continues publishing through the same private PipeWire core.
The simulator initializes its optical model when its own service starts.
The measured RTC activates while that service is already publishing, and
primes only on its camera acquisitions after the native Start command.

## Measurement boundaries

| Interval | Start | End |
| --- | --- | --- |
| Service restart to Ready | Caller requests systemd start | Start returns after MediaSession verifies the held graph and notifies systemd |
| Start to usable measurement | Native Start acknowledgement | First observed qualifying output for the current graph attachment, with correction open |
| Close to first correction | Explicit native Close request for that loop | First observed corrected physical offset matching the live acquisition and optical reference |

Each measurement uses monotonic wall time. SCC requires a chopped pair and
LLOWFS a single valid camera measurement. Simulator model time, frame
delivery, graph execution and service activation have different boundaries.
The fixture observes the held cameras before it sends Start. That test interval
is outside both service startup and Start-to-measurement time. The correction
timestamp is the observer receipt for the first physical offset matching the
camera and signed reference.

## Startup regression and preliminary pair

The direct process rejects an unexpected command line before creating the
invocation directory. Regression cases also cover a replaced calibration, an
unrecognized activation digest, a second Julia manifest, a graph template
added after installation, and application of session-only environment settings
under the original systemd PID. The cold export selector passed 12 checks.
The full measurement uses the SHA-bound installed unit, with the same stop
and cleanup hooks in both arms.

One earlier pair on `3c964d3` took 15.285 s with the helper and 13.013 s with
direct startup. Both reached native Ready with 10 Links. The two graph services
kept their identities and the independent tap saw LLOWFS frames 28 and 30 while
the RTC was absent. A later package build was compiling elsewhere on the host.
These two commissioning runs are excluded from the repeated comparison. [Preliminary receipts](cal2-preliminary.tar.gz)

## CAL2 before the detector publication change

On RTC `47ada5e`, the first measured helper start took **11.332 s**. The
next two direct starts took **11.504 s** and **12.149 s**, with the last
following loss of the prior RTC process. The last scheduler samples before
Ready recorded 2.010 s of helper CPU time and 7.713 s of RTC main-thread
CPU time in the helper run. The direct runs used 10.324 s and 10.826 s of
RTC main-thread CPU time, with 0.168 s and 0.175 s spent runnable waiting
for CPU. The comparison kept the same graph processes and their CPU placement.

Acquisition 42 on the LLOWFS path was generated and staged at 82 ms model
time. The callback could obtain no native output buffer. Frame 43 replaced
the still-pending exposure and reached the independent receiver with the RTC
absent. Later LLOWFS exposures stalled through the open-loop trial, which
prevented LLOWFS closure. SCC continued on the same simulator and core. It
primed on live exposure 11. The first correction after explicit Close, on
exposure 12, agreed with the signed reference on all 2,304 channels. The
maximum absolute error was 4.79 × 10⁻¹⁷ m against a tolerance of
1.43 × 10⁻¹⁵ m. The original optical comparison ended at this failed LLOWFS
gate. [Original launch, native and optical receipts](cal2-original.tar.gz) · [Camera, receiver and graph acquisition joins and HIL regression results](cal2-original-lineage.tar.gz)

## CAL2 with retries on the optical control thread

The second cohort kept RTC `47ada5e`, the CAL2 graphs, calibration, camera
exposures and core placement. The independent simulator used the HIL change
`ff27436`. If the native output callback cannot dequeue a buffer, the control
thread can request another publication of the still-pending exposure. A
newer exposure may supersede it. The optical model continues on its own clock.

The helper arm reached Ready in 12.194 s. The loop remained open through
LLOWFS acquisition 11 and SCC acquisition 4. After explicit closure the
first LLOWFS correction, acquisition 21, matched all 2,304 reference
channels within 3.16 × 10⁻¹⁶ m. The SCC correction, acquisition 5, matched
all 2,304 channels within 4.79 × 10⁻¹⁷ m. During the subsequent forced RTC
outage, the native callback recorded a buffer miss on LLOWFS acquisition
28. The first retry queued that same exposure 65.262 µs after the miss. The
independent receiver accepted and drained it.

The direct replacement reached Ready in 11.442 s. LLOWFS primed on acquisition
36 and its first correction was 46. SCC primed on 9 and first corrected 10.
Both again matched the signed reference on all channels. The continuity
gate still failed. LLOWFS acquisitions 40 and 45 reached the source callback
and encountered a busy buffer. The optical owner was already computing, and
the next completed exposure replaced each pending sample before the control
thread dispatched its retry. Acquisitions 52 and 53 showed the same sequence
during the next RTC outage. A further direct activation reached Ready in
20.807 s. It timed out waiting for a fresh held LLOWFS camera frame.
Acquisition 60 had encountered a busy output buffer on the initial attempt and
on all three bounded retries within 104 µs. The tests therefore distinguish correct
open-loop priming and correction from continuous detector publication.

| Launch | Camera | Request to Ready | Start acknowledgement to first usable output | Camera queued to graph input for that output | Close request to first verified correction |
| --- | --- | ---: | ---: | ---: | ---: |
| Helper | LLOWFS | 12.194 s | 30.260 s | 160 µs | 30.180 s |
| Direct | LLOWFS | 11.442 s | 29.821 s | 72 µs | 32.065 s |
| Helper | SCC | 12.194 s | 318.733 s | 84 µs | 159.408 s |
| Direct | SCC | 11.442 s | 327.033 s | 94 µs | 153.530 s |

The first usable SCC result requires a live chopped pair. The independent
CPU simulator took tens of wall-clock seconds to advance milliseconds of
model time. These are workstation first-frame observations. A camera operating
at its specified physical cadence needs its own measurement. Each mode had
one complete optical trial in this cohort. Across the two cohorts, neither
mode consistently reached Ready first. [Matched optical, timing and restart receipts](cal2-control-thread-retry.tar.gz)

## Software verification

The RTC suite on the final implementation `61b77ca` passed 11,886 assertions
across 553 testsets with Julia 1.13.3 and its resolved PipeWireAO JLL. Earlier
attempts include a five-second calibration request expiry on the shared test
placement and an invalid run restricted to CPUs 0/1 for a selector that
requires a CPU numbered 2 or higher. The passing suite used CPUs 0, 1, 14
and 15 and the original deadlines. [Full RTC test output](rtc-full-suite.log.gz)

Selected checks separately passed 64 installed-activation assertions, 273
analysis and configuration assertions, 12 cold-install checks and 33
calibration/graph extension assertions. HIL `030bed3` passed 345 array and
publication checks with default Julia optimization, including 105 on a private
core, 16 for bounded retries and the warmed zero-allocation metadata check.
The exploratory `-O0` HIL run passed the retry checks and failed the metadata
allocation assertion. [Selected test output](selected-checks.tar.gz)
