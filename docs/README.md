# PipeWireAO RTC task index

PipeWireAORTC runs the non-actuating development RTC. MediaSession owns
lifecycle, admission and declared Links. PipeWireAO transports detector and
command arrays. FGN and FilterGraphs execute the instrument's scientific graphs.

| Task | Where to start |
| --- | --- |
| Install the RTC and supply an instrument definition | [Operator CLI and instrument deployment](../README.md#deploy-an-instrument-from-its-definitions) |
| Start, stop or update an installed service | [systemd startup and shutdown](SYSTEMD_SESSION_STARTUP.md) |
| Attach to a simulator that is already publishing | [Independent source binding](HIL_CONFIGURATION.md#attach-an-rtc-to-an-already-publishing-source) |
| Configure the initial loop state and acquire a live measurement | [CAL2 open-loop startup](HIL_CONFIGURATION.md#start-cal2-with-correction-open) and [graph service lifetime](OWNER_BOOTSTRAP_DESIGN.md#graph-service-lifetime-across-rtc-sessions) |
| Use native session controls or discover a running RTC | [Operator commands](../README.md#native-session-control), [discovery](SESSION_DISCOVERY.md) and [management endpoint](MANAGEMENT_ENDPOINT.md) |
| Prepare and validate a calibration bundle | [Bundle and method usage](CALIBRATION_METHOD_USAGE.md) and [live acquisition](JULIA_CALIBRATION_ACQUISITION.md) |
| Change a protocol or the scientific ownership boundary | [Architecture decisions](architecture.md), [operating requirements](operations.md) and [control envelope](CONTROL_ENVELOPE.md) |
| Run software or private-core checks | [Validation commands](../AGENTS.md#validation) and [integration checks](../test/integration/README.md) |
| Find outstanding work or reproduce a measurement | [Current roadmap](roadmap.md#current-work) and [verification records](EVIDENCE_INDEX.md) |

The architecture and operating contract define the `RTC-ARCH-*` and
`RTC-DEV-*` requirements. Each verification record identifies the instrument,
software versions and operating conditions it covers.
