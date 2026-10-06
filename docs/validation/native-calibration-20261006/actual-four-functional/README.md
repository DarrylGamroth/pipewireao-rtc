# First installed calibration action attempt

The parent reserved agent-owned SCI/GPU execution for four serial installed
functional cases: Classic FGN Collect/Capture, then Copper FGN Collect/Capture.
Only Classic Collect was launched. It returned exit 1 before native Running
admission, and the remaining three cases were stopped without launching.

The package passed all 575 sealed artifact checks and selected runner `750059d1…`
and calibration CLI `ce0ba26c…`. A cold installed SDK import resolved to its own
sealed `hil/packages/PipeWireAO` with d514 thread-loop SHA `d6221155…`.
The frozen run82 plan and exact command/source hashes are in [receipt](receipt.json).
No environment remote selector was present. Known pre-existing user GUI,
GC and Kaimon processes were preserved; this was a functional attempt with no
isolation or timing claim.

## Observed failure

- The coordinator returned `success=false` and
  `native control outcome unknown: owner proxy was removed`.
- The installed supervisor ended with
  `acquisition owner Connect did not complete`.
- The source log records SIGTERM 15 and a Julia compiler stack in `showerror`.
  Its final `ERROR: LoadError:` line has no completed exception message.
- No native admission, Hold, Collect, Capture, Restore, Release or successful
  shutdown completion was observed. No action or scientific gate passed.

See [deployment log](classic-collect-v1-deployment.log) and the unchanged
[qualification result](classic-collect-v1-qualification.json).

The underlying source exception is **not identified**. A separately confirmed
SDK hook removal defect is not established as this failure's cause; the
retained source log does not show SIGSEGV. The current lifecycle client's
`connect_owner!` replaces a rejected or incomplete completion with a generic
message, losing the available typed result/lifecycle/message at that seam.
Retaining those details is the smallest useful diagnostic before any retry;
this increment makes no production change.

## Cleanup evidence and limits

The qualifier never received admitted process identities and correctly retained
cleanup status `unknown`. A separate [PID absence proof](classic-collect-v1-owned-pid-absence.json)
confirms the previously observed qualifier, supervisor, registered private core
and source PIDs are absent, and the owned private runtime has been removed.
The final startup state is retained as bookkeeping only, without granting it
native control authority or promoting it to an admitted group identity proof.
All identified owned processes are gone; their pre-admission group/start-time
identities were not retained. The SCI reservation was released after this
observation. The three unexecuted cases still require fresh authority and a
new parent reservation.
