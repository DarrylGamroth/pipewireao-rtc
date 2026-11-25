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
[CLI and installed admission](../../../src/deployment/session_cli.jl)

After the focused fixes, move the installed context, direct attachment and
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
