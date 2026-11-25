# Installed RTC shutdown and package boundaries

Reviewed local `main` at `c523d3f` on 2026-11-25. The review covers
installation, direct stop, retained reports and the dependency between
MediaSession and the operator CLI. The probes used Julia 1.13.4, a temporary
Unix socket, temporary records and generated shell launchers. Scope is software
behavior. The [previous CAL2 run](../../validation/native-admission-queries-20261124/README.md#installed-package-cache)
remains the timing and optical evidence for its recorded build and deployment.

## RTC-MAINT-01 — Bound authentication during direct stop

**Priority 1 · confirmed in the direct-stop helper.** Before sending native
Quit, `SessionRuntime.stop!(handle)` opens a dedicated user-bus connection and
acquires a systemd unit reference. This keeps the unit's exit fields available
through reconciliation. The helper sets a method timeout and calls `RefUnit`
without the deadline-controlled authentication loop used by admission.
[Stop and reference lifetime](../../../src/deployment/session_runtime.jl) ·
[Existing bus authentication](../../../src/deployment/systemd_bus.jl) ·
[systemd manager API](https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.systemd1.html)

A local listener accepted the helper's connection and sent no D-Bus handshake.
With a 400 ms caller deadline, the child was still waiting 1.5 s after accept.
Closing the peer caused the helper to return an error after 1.524 s. This
exercises the unit-reference acquisition before Quit. The measured CAL2 detach
used the ordinary systemd stop path.

**Action.** Put bounded connection opening, authentication and close in
`SystemdOwners`. Use it for the dedicated unit reference and the admission
watch. Subscribe only where admission needs signals. Keep the reference alive
until the caller has collected the exit status. Extend the
[silent-bus test](../../../test/systemd_bus.jl) to cover reference acquisition
and verify that a successful native Quit still retains the systemd exit result.

## RTC-MAINT-02 — Bind strict shutdown hooks when preserving an older launcher

**Priority 2 · confirmed command mismatch for a supported installation combination.**
The installer accepts several exact historical client scripts when a package
seals its launcher. It preserves those bytes. The newer unit template can
therefore start the main process with strict Julia cache loading and invoke
the older client script for `ExecStop` or `ExecStopPost`.
[Installer](../../../src/deployment/session_install.jl) ·
[Sealed launcher compatibility cases](../../../test/runtime_install.jl)

I rendered the current managed template and ran its selected shell launcher
against an argument-recording executable. The current client passed the strict
flag and selected the installed depot for both `stop` and `cleanup`. The accepted
older script passed neither. This establishes that rebuilding during shutdown
is possible if the shared image is missing. The probe did not time a rebuild.
The previous CAL2 run exercised the newly generated client.

**Action.** For a new unit that requires the installed cache, bind and verify
an installation-generated service hook even when the historical operator
script must be preserved. Keep existing sealed scripts byte-identical. Test
the combination by hiding the shared compiled caches, invoking stop and cleanup
and checking the verified hook arguments. Cover direct stop and managed cleanup.
[Unit templates](../../../assets/deployment) ·
[Existing cache replacement test](../../../test/test_registered_application.jl)

## RTC-MAINT-03 — Honor explicit identity when reading a staged final report

**Priority 2 · confirmed in the report reader.** With a staged `session.json`,
`SessionRuntime.final_record(path; unit, invocation)` overwrites both arguments
with values from the receipt. In separate calls, a request for invocation B
returned invocation A, and a request for a different unit returned the receipt's
unit. The receipt and final report agreed with each other in both probes.
This affects report attribution. The live stop path has separate identity checks.
[Report reader](../../../src/deployment/session_runtime.jl) ·
[Existing direct and staged coverage](../../../test/test_session_configuration.jl)

**Action.** Fill omitted identities from the receipt and reject a supplied
value that disagrees. Test omitted, matching and mismatched identities in both
supported layouts. Preserve the stage-only call used by instrument qualification.

## RTC-MAINT-04 — Give installed admission an internal Julia module

**Design improvement · source verified.** MediaSession's admission context
contains `SessionCLI.InstalledAdmission`. Its runtime calls into the CLI module
to verify placement and identity, publish discovery, recheck units, signal
Ready and retire discovery. The same CLI module parses operator commands and
implements restart. This arrangement makes a change to evidence required for
Ready cross a client boundary. [MediaSession admission](../../../src/media_session/admission.jl) ·
[Operator commands](../../../src/deployment/session_cli.jl) ·
[Installed admission](../../../src/deployment/session_admission.jl)

**Action.** After the focused fixes, move the installed context, direct attachment and
systemd/discovery operations to an internal deployment module within
PipeWireAORTC. MediaSession should retain decision authority and the final
ordering of service identity checks, PipeWire synchronization and held-Link
verification. Keep the public session command entry point and the existing
direct, managed and foreground launch behavior. Exercise wrong-core rejection,
service replacement during admission, open-loop Ready and clean Quit.

A later small installer cleanup can put package-image staging and verification
in a Julia file executed by the selected runtime. Today these programs are
embedded as strings alongside unit rendering and historical launcher matching.
Keep the separate-process check, the installed dependency cache and the
unchanged foreground command. There is no measured startup benefit attributed
to this source reorganization. [Current cache logic](../../../src/deployment/session_install.jl)

## Scope across instruments

Apply the fixes in the shared RTC. The reviewed instrument checkout
`adaptive-optics-simulations@356f441` declares an exact RTC 0.7.29 for GPI2
and 0.7.26 for REVOLT Classic. CAL2 and SPIDERS declare a compatible 0.7.28
range. These are authored constraints. Each deployed Manifest selects the
actual build. Preserve the pinned launchers and qualify any promoted build
on the instruments' applicable direct or managed paths. The prior
[instrument results](../../validation/direct-session-launch-20261124/instruments.md)
identify their different live priming signals. No production code, release
pins or scientific settings were changed by this review.

## Implementation and verification

The fixes apply in the shared RTC. The following checks used Julia 1.13.4
on the development host.

| Finding | Disposition and evidence |
| --- | --- |
| RTC-MAINT-01 | `ec4c91b` uses the same bounded bus authentication for the direct-stop unit reference and admission watch. The 400 ms silent-peer probe previously blocked through 1.502 s and returned in 0.469 s after the fix, including child teardown. The disposable native Quit test retained the invocation's exact systemd exit fields and checked collection after release. The bus selector passed 53 assertions. |
| RTC-MAINT-02 | `1cb3281` binds the verified strict hook in both the unit and activation when an older operator launcher is sealed. All four supported historical launcher forms retained their exact bytes. With the shared cache withdrawn, the rendered managed stop, managed cleanup and direct stop ran from the installed cache. |
| RTC-MAINT-03 | `ec4c91b` uses receipt identities only for omitted arguments. The final reader rejects an explicit wrong unit or invocation for staged and direct layouts. The runtime selector passed 118 assertions. |
| RTC-MAINT-04 | `66df07e` gives the systemd and discovery bindings to an internal SessionAdmission module. MediaSession owns the final native Status and the readiness decision. Private-core tests verified rejection of a foreign core before endpoint publication, Link cleanup and foreground Quit. |

The independent review also identified that the package search path set by a
Julia App can differ from the path used by an installed service. With an
operator-only path, cache staging failed to import the instrument RTC. New
installations qualify graphs and stage the service cache under the selected
project. Strict units use the same default search path and honor explicit
profile overrides.

The core suite passed all 12,000 assertions in 563 testsets on the code
in `2630261`. The private-core selectors passed 127 assertions. A temporary
registry supplied the candidate RTC tree
`50862761bd091da3926c0b0fec4f4d1d986ba625` to both the instrument environment
and a separate Julia App installation. The installed CLI exported and installed
a detector with no authored Julia Project, preserved the input files, and
copied the site's Project and Manifest. The cold install and relocation
selector passed 336 assertions. These runs reused locally available dependency
sources and native artifacts.
[Software test results](software-tests.log.gz)

### Installed Classic CPU lifecycle

The installed RTC at `66df07e` admitted all 20 declared Links on both
disposable Classic CPU deployments. A fresh native Status confirmed held
Ready. After explicit Start, the integrator primed on the simulated detector
stream and remained open. The session accepted native Quit in both cases.

| Deployment | Start request to held Ready | Stop request to exit | What started during activation |
| --- | ---: | ---: | --- |
| Direct attachment | 75.160 s | 9.458 s | The independent core and CPU source were already publishing. The retained graph and scoped parameter service started with this request. |
| Managed | 137.250 s | 11.333 s | The session launched its private core, graph, parameter service and CPU simulator. |

These are single first activations on the shared development host. Neither
measurement is a warm reattach time. On direct Quit, the scoped parameter
service exited and the same source continued publishing in generation 1
through sequence 552. The harness initially expected the parameter PID to
survive. The terminal receipt, scoped unit list and independent source
cursors establish the actual lifetimes. On managed Quit the private socket
and owned processes were retired.

**Original graph-owner failure at `66df07e`.** The retained graph was idle waiting for a new
attachment after successful direct RTC shutdown. Two seconds later, stopping
that separate graph service sent SIGTERM. PipeWire reported wrong-context
filter destruction and the process aborted during proxy cleanup with heap
corruption. The trace establishes the disposal failure. The service-stop reproduction and repair follow below. All
disposable services were retired.
[Run configurations, lifecycle receipts and graph backtrace](classic-cpu-installed-admission-66df07e.tar.gz)

## Retained graph service shutdown

At `66df07e` the separate graph received SIGTERM after the RTC had quit.
Julia entered process termination with native PipeWire objects still live.
The retained unit now asks the bootstrap monitor to cancel. The graph owner
then leaves the native graph loop, closes the graph on its owning thread and
exits. A native RTC Quit alone still releases only that attachment.

| Installed Classic CPU graph | Stop request to process exit | What was verified |
| --- | ---: | --- |
| After RTC Quit, `f2217e8` | 0.327 s | The RTC admitted all 20 expected Links, primed on live detector frames with correction open and completed native Quit. The retained graph then exited normally with status 0. The same simulator advanced from sequence 5133 to 5142 in generation 1. |
| Prepared before any Connect, `6986033` | 0.279 s | A fresh correlated native Status reported Prepared. The installed graph exited normally with status 0 and the same private core stayed available. |

The graph journals were clean in both runs. A separate private-core test on
`6986033` kept the connected controller alive while requesting service
shutdown, exercised repeated attachments and passed all 11 checks. The
monitor regression also covers a fresh Connect and a pending Connect during
shutdown. The full RTC core suite passed 12,004 checks in 564 testsets. The
offline export selector passed 13 checks. The installed tests used Julia 1.13.4, PipeWireAO_jll 4.0.8+0 and
CPU graphs. The earlier fixture's source-control client bound its own observation
proxy and closed the client while the proxy was still open. Its teardown
logged an error after graph exit and verified continued publication. All disposable units, processes and sockets were retired.
[Stop requests, terminal process status and graph journals](graph-stop-receipts.tar.gz)
