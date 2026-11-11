# Managed stop and direct native Quit

The deployed runtime has one host-facing stop operation, `SessionRuntime.stop!`.
Its systemd stop hook retains the native Quit attempt and acknowledgement in
`launch.json`. `reconcile_stop!` observes that cleanup without replaying the
stop. Direct PipeWire clients still send Quit through the session control
endpoint and receive the correlated Offline completion.

## Private Classic CPU sessions

Julia 1.13.3, PipeWireAO 0.9.2, PipeWireAO_jll 4.0.2+0,
FilterGraphPipeWire 0.5.5 and HIL 0.5.1. The test used an existing Classic
export with its WFS analysis graph and a deliberately failing optional
analysis graph. A temporary Manifest selected RTC candidate tree
`1e4f14a9a5ea0adb8c8733b21dc7f097ee534db4`.

The first managed stop acknowledged native Quit and completed invocation
cleanup, but systemd reached the stop timeout and killed the WFS analysis
process during first-use compilation. The managed rerun waited for WFS
analysis readiness and the deliberate analysis failure before sending Quit.

| Entry point | Native completion | Cleanup verified |
| --- | --- | ---: |
| `SessionRuntime.stop!` | ExecStop retained one accepted Quit | 63.3 s |
| `SessionRuntime.control!` with native Quit | Client received Offline and `shutdown=true` | 35.0 s |

Each passed on a separate private core after Ready and Running. The managed
caller also reconciled the result without a second stop. The direct caller
read the final record after the unit exited and confirmed that ExecStop
had submitted no second Quit. Both successful runs removed the private
socket and owner fragments, left no invocation jobs or live units, and
recorded no SIGKILL. Times include verification and are functional
observations.

The focused session stop, runtime, configuration and installer selectors
passed. The three migrated integration scripts parsed. The standalone
fault-helper selector reproduced the same three pre-existing artifact
validation assertion failures on `5338530` and the candidate. Those
assertions are outside the shutdown path.
