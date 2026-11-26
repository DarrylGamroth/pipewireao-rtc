# Shared RTC Quit regression and Classic CUDA focal-image check

## CPU Quit regression

The installed direct-session fixture exports a small instrument from YAML and
uses an independent CPU producer and private PipeWire core. Native admission
creates the single Link from the producer to the core's capacity-one capture
queue. The producer publishes one sample after Ready with no playback
consumer, leaving one capture loan outstanding. The test samples native queue
counters immediately before and after native Quit.

| Native capture counter | Before Quit | After Quit |
| --- | ---: | ---: |
| Capture buffers | 3 | 0 |
| Pending loans | 1 | 0 |

The queue returned exactly one loan. The core cookie, queue serial and capture
generation matched between the snapshots. No playback delivery, dropped
arrival or ownership protocol error occurred. The independent provider, its
published Port and the private core survived Quit, and the RTC Link retired.

All 140 checks in the installed private-core selector passed, including the
existing abrupt-exit and placement checks. The 20 counter checks exercise
missing, inconsistent and regressing native evidence. The same verifier also
accepted both retained CAL2 queue snapshots when each queue name was supplied
from the command line. See the [shared selector and counter verifier](../../../test/integration/README.md#capture-buffer-release-on-quit).

The feedback exporters resolve calibration references under the namespace in
the composition recipe. Both CPU feedback selectors used a different namespace
and passed all 85 checks. The native acquisition lifecycle's version 1
identifiers stay in its wire codec. Deployment and session control use the
same mapping.

## Classic CUDA focal-image link

[Issue #11](https://github.com/DarrylGamroth/pipewireao-rtc/issues/11) reports a
required focal-image Link loss after about eight minutes in the 2026-10-23
cohort. This run uses the current authored instrument at `e403690`,
registered RTC 0.7.33,
PipeWireAO.jl 0.9.6, native SDK 4.0.10+0 and CUDA.jl 6.5.1 on an RTX 3080.
The simulator uses its 500 Hz model and a wall-clock pacing target of 500 Hz.
The normal observation client subscribes to all eight declared products on
the private core. The focal-image capture Link retains its exact port and
Node endpoints throughout the witness.

The first startup reached Ready in 306.659 s and delivered detector and
focal-image frames. The optional analysis process could not read its decoded
configuration while the host's `/tmp` filesystem was full. The measured
restart reused the compiled package cache and reached Ready in 86.325 s.
The WFS analysis ran as an independent CPU client using the installed
configuration and `TMPDIR=/var/tmp`. It verified all four analysis Links.

The measured run held Running for 601.776 s with 213,411 additional
detector publications and 11,060 additional focal-image publications.
The required Link kept ID 179 and serial 180 through all 198 snapshots.
The focal queue retained its three capture buffers and reported zero
protocol errors. A separate observer reconfiguration used slow driving for
15 s, removed observation clients for 15 s, and reattached. The same focal
Link and producer remained active and all eight outputs advanced after
reattachment. Native Quit and cleanup completed in 11.059 s. This run
exceeded both the reported elapsed duration and detector sequence in #11.
The result establishes behavior on the supported build exercised here.

## Runtime configuration and command output

The released config reader failed when the optional analysis launcher
inherited a full temporary directory. The same installed analysis
configuration also failed with `TMPDIR=/proc`, where the subprocess
runner could not create its capture directory. The revised runner captures
bounded stdout and stderr through pipes. The config exporter checks
generated SPA-JSON through an anonymous memory-backed file before creating
its requested output. Both the real analysis config and the native
serialization checks pass with `TMPDIR=/proc`.

The CUDA driver also updated cache metadata under the user's home directory
during the Classic run. The managed launcher defaults its cache path to the
containing systemd runtime directory so the driver can reuse it across
restarts of that instance on the same RAM-backed filesystem. Native session
discovery and lifecycle receipts already use the systemd runtime directory.
The managed CPU fixture passed all 24 checks with `TMPDIR=/proc` and observed
the default CUDA cache path in the live owner's environment.
Service journaling, explicitly requested exports and operator recordings have
their own output paths.

The final core suite passed all 12,369 checks across 582 testsets, including Aqua.
