# Ordinary systemd services for session startup

Scope: one-shot launcher under RTC-ARCH-026. The headless RTC
owns admission, application links and source release; systemd owns processes.
FGN/JFG algorithms, AOS simulation and native controls are unchanged.

## Startup

The session service executes the native `pipewireao-rtc` application directly. Its finite
`ExecStartPre` helper renders the private configuration and ordinary owner
service files, then starts the private core. After confirming the core socket
and retaining its process identity, it starts the remaining held owners through
one systemd target. This replaces a separate `systemd-run` submission for each
owner. The target has `Wants` and `After`, with no stop propagation.

HEART profiles retain one necessary dependency: the source command contains the
actual HEART owner PID. Start and retain that owner before rendering the source
service. Record all intended unit names before the first start request. Neither
the core nor this staged HEART owner is pulled in by the target, so target start
cannot silently restart either after its identity was retained.

Target activation is not proof that every owner started. Check each loaded unit
definition and actual active PID, invocation, start time and cgroup. Then render
application configuration from those retained identities. Native warmup,
placement inspection and MediaSession admission precede release.

## Cleanup

An explicit service stop first runs the installed `ExecStop` one-shot client.
It verifies the exact service invocation, main PID/start time, caller cgroup,
and native session UUID, then requests native Quit once. The session HSM
decides whether to accept the command. It coordinates source hold and
outstanding command adoption, graph stop, Link withdrawal and terminal owner
acknowledgements within its five-second effect deadline. ExecStop records
the attempt before submission, uses an eight-second request bound, and
waits for the same RTC process to exit within its 30-second helper budget.
That budget begins after package load. systemd's 300-second watchdog also
bounds compilation, I/O and client close.
A failed, missing or unknown acknowledgement is not retried.

Fresh invocation names are exclusive and services use `Restart=no`. On failure
or exit, cancel all cohort/member start jobs, revoke and prove the private core
and source empty, then stop consumers. Stop the target only after owner
quiescence. Remove only exact invocation-owned runtime unit links and files;
retain the launch ledger and fence cleanup on identity or ownership uncertainty.
An unreadable ledger permits ingress revocation but fences consumer/file removal.

The session HSM coordinates required owner shutdown. Optional analysis units
follow the session unit lifetime through `PartOf` and share invocation cleanup.

## Implementation and validation

1. Add literal argument/environment unit rendering; retire unused transient
   coordinator launch and cleanup functions.
2. Render/install exact invocation fragments, launch core then the owner target,
   and retain loaded definitions and actual owner identities.
3. Extend existing cleanup to cancel target and member jobs and remove owned
   fragments after proven quiescence.
4. Check unit escaping and discovery, actual systemd argument round trips,
   selected Copper FGN/JFG startup/native controls/teardown, and obtain an
   independent review of ordering and uncertainty handling.

These are deployment checks. They do not upgrade previous numerical, timing,
hardware, Classic, row-block or HEART qualification claims. Validation evidence
is recorded separately after execution.
