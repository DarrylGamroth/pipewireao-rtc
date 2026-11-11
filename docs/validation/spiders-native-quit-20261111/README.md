# SPIDERS fitted-dual native Quit

The previous installed CPU run reached Running. During native Quit its
FilterGraphPipeWire controller exited with `pw_ndarray_filter_run` reporting
`EPIPE`. The RTC then reported that a required registry object's serial
had changed. The ndarray filter treats removal of a retained input buffer
as a failure even after the graph has acknowledged Hold.

Quit now holds the sources and graphs, retires independent graph owners in
consumer-first order, withdraws the remaining links with the existing Core
synchronization fence, then shuts down the other owners. It verifies the
graph owner's exact bootstrap identity and requires its correlated Stopped
receipt. Its incident links are marked for retirement before filter close.
Fault compensation retains its existing Hold and withdrawal sequence.

The private fitted-dual CPU test used RTC runtime code `c59a0f6`, HIL
`233cef6`, Julia 1.13.3, FilterGraphPipeWire 0.5.5, and PipeWireAO 4.0.2.
The fresh simulator mapped its installed optical startup image. The RTC
passed fresh Ready and Running checks and the SCC pair-status queue
published a chopped pair before the stop request.

The systemd stop hook submitted native Quit once and acknowledged Offline.
The retained ledger reported `phase=stopped`, `systemd_quit.accepted=true`,
`service_result=success`, `cleanup_complete=true`, and
`unit_files_removed=true`. The private socket and owner processes were gone.
The journal recorded no controller EPIPE or SIGKILL. Focused RTC and HIL
tests passed 1,045 and 169 assertions, respectively.
