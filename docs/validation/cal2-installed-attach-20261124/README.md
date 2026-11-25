# CAL2 attachment using the installed RTC configuration

An installed RTC can reconnect to the same independent camera and graph services.
Systemd starts MediaSession with the fixed `systemd/rtc.conf`. The RTC binds
the current process and native endpoint identities in memory and verifies the
declared Links, graph Hold acknowledgements and placement before publishing
Ready. Its private systemd directory contains one replaceable `launch.json`
receipt. The CUDA simulator, pupil feeder and two controller graph services
continue running when the RTC quits. [Service installation and operation](../../SYSTEMD_SESSION_STARTUP.md#keep-controller-graph-services-running-across-an-rtc-restart)

## Matched comparison

Each row is a fresh CAL2 RTC process on the same private core, with the same
already-publishing CUDA simulator, retained CPU graphs and placements. Both
installations used Julia 1.13.3's distribution image. The timers cover the
operator's systemd request through its successful return. Ready requires
positive native admission and held graphs. Start is a separate command.
The camera columns start at the Start acknowledgement and end at the first
observed usable open-loop output for a matching, newly published acquisition.
SCC requires a valid pair. These times include waiting for the simulator's
next exposures.

| Installation | Trial | Attach to held Ready (s) | Detach to stopped (s) | First LLOWFS output (s) | First SCC pair (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Prior | 1 | 6.119 | 4.385 | 0.348 | 4.385 |
| Prior | 2 | 6.219 | 4.582 | 0.166 | 3.179 |
| Prior | 3 | 6.276 | 4.533 | 0.429 | 2.942 |
| Fixed configuration | 1 | 6.049 | 3.223 | 0.190 | 4.216 |
| Fixed configuration | 2 | 6.205 | 3.169 | 0.402 | 4.918 |
| Fixed configuration | 3 | 6.206 | 3.228 | 0.079 | 2.595 |

Median attach was 6.219 s before and 6.205 s after the change. The two
ranges overlap. Median detach fell from 4.533 s to 3.223 s (28.9%).
The largest change was after the RTC process exited. The median remaining
wait for systemd to return fell from 1.860 s to 0.403 s after removing
the separate post-stop cleanup process. The direct service still uses a
fresh management client to request native Quit. From the stop request to
native Quit submission, the median went from 2.034 s to 2.128 s. From
submission to RTC process exit, the median went from 0.615 s to 0.691 s.
The three component medians are taken independently.

All six attachments admitted ten exact Links. The held RTC reported Open and
unprimed for both controllers. After Start, each trial produced a finite
nonzero modal residual and an exactly zero physical offset from the matching
live camera observations. Neither loop received Close. Both cameras advanced
after every Quit with the same provider and graph process identities.
The fixed configuration was unchanged and the RTC unit directory contained
only `launch.json` at both Ready and stopped. The benchmark kept its own
per-trial observations separately.

The prior installation used RTC source `a4cacb8`, which has the same runtime
source as the comparison base `bc829d7`. The installed comparison used
`b24edf9785c7ee8e5b958a2ce98f2e8dc5d8729d`. Its package tree, manifests, unit,
fixed configuration and graph installation are identified in the archive.
An earlier development run failed at a systemd query before native admission
because systemd omitted the empty post-stop command array. A subsequent
negative control supplied a deliberately incorrect activation seal. The tested development build (`807a698`)
refused startup, preserved the last terminal receipt and recovered on the
valid installation. The operator verified Start via the public SessionRuntime
client and a clean Quit. One preliminary baseline with an invalid observer
deadline was excluded. [Trial timestamps](timings.csv) ·
[Development comparison and negative activation control](installed-direct-cal2-receipts.tar.gz)

An additional operator check attached to the named unit, verified Running
and called `SessionRuntime.stop!` on the already-connected Julia client. It
returned in 2.432 s with the exact invocation's successful systemd exit. The
stable file recorded the native cleanup. Across the observation window the
independent receiver counted 12,690 LLOWFS and 2,538 SCC acquisitions with
zero sequence gaps. Both RTC instances were inactive at the cutoff and the
simulator was still publishing. [Final installed configuration, six timed runs, operator check and reproduction scripts](installed-direct-cal2-final-receipts.tar.gz)

## Other instruments

The normal installer generated the fixed RTC configuration, graph units and any
declared companions for each private CPU application. Classic had five sparse
parameter sources and a WFS analysis service. GPI2 had eight sources and a
pupil-flux analysis service. Fitted dual SPIDERS had one parameter source and
two graph services. CAL2 had two graph services and used its existing
installation for them. SPIDERS used the qualified FilterGraphPipeWire
composition-observer backport. The Classic, GPI2 and SPIDERS checks verified
installation, native configuration and service dependencies. Live attach
timings in this record are for CAL2 only. The same `b24edf9` runtime was
installed and selected as the installer for all three CPU profiles. Each RTC
retained its own companion names, and each graph had an independent service
lifetime. [Final instrument configurations and hashes](instrument-companions.tar.gz)
· [Site-owned graph and SDK override checks](instrument-installation.tar.gz) · [Instrument priming declarations and companion versions](../direct-session-launch-20261124/instruments.md)

A generated parameter publisher on a separate private core passed two service
incarnations. The checks covered the exact bootstrap and control identities,
rejection of a mismatched shape, delivery of all four floating-point values in
a matrix and acknowledged native Quit. Those explicit test values were confined
to the protocol fixture. CAL2 primed both graphs from its publishing simulator.

The installed parameter service also passed its real systemd and mapped-library
identity checks. Admission rejected a different installation even when its
unit contents had the expected digest. Separate shutdown fixtures verified a
successful process exit and rejected a failed exit despite an otherwise clean
native receipt. [Parameter and shutdown selectors](parameter-and-shutdown-checks.tar.gz)

## Package verification

The full RTC suite on `b24edf9` passed all 12,355 assertions in 561 testsets.
It used Julia 1.13.4, the matching PipeWireAO JLL prefix, and
`--compiled-modules=existing`. An earlier run used a temporary directory
long enough to exceed the private fixture's Unix socket path limit. The
private core and the full suite passed under the shorter `/var/tmp` root.
[Complete test output](rtc-full-suite.log.gz)
