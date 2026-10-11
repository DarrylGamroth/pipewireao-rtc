# Ordinary systemd services for session startup

Scope: one-shot launcher simplification under RTC-ARCH-025. WirePlumber Lua
continues to own admission, links and source release; systemd owns processes.
FGN/JFG algorithms, AOS simulation and native controls are unchanged.

## Startup

The session service still executes WirePlumber directly. Its finite
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
WirePlumber configuration from those retained identities. Existing native
warmup, placement inspection and Lua admission remain mandatory before release.

## Cleanup

An explicit service stop first runs the installed `ExecStop` one-shot client.
It verifies the exact service invocation, main PID/start time, caller cgroup,
and native session UUID, then requests native Quit once from an admitted healthy
session. WirePlumber retains authority for source hold and outstanding command
adoption, graph stop, link withdrawal and terminal owner acknowledgements. The
client uses the existing eight-second request bound; Lua retains its five-second
effect deadline. It records the attempt before submission and waits for the
same WirePlumber process to exit within its cooperative 30-second helper budget.
That budget begins after package load and does not interrupt compilation, I/O
or client close; systemd's unchanged 300-second watchdog bounds the process.
A failed, missing or unknown acknowledgement is not retried.

Fresh invocation names are exclusive and services use `Restart=no`. On failure
or exit, cancel all cohort/member start jobs, revoke and prove the private core
and source empty, then stop consumers. Stop the target only after owner
quiescence. Remove only exact invocation-owned runtime unit links and files;
retain the launch ledger and fence cleanup on identity or ownership uncertainty.
An unreadable ledger permits ingress revocation but fences consumer/file removal.

No `PartOf`, `BindsTo` or `Requires` adds a competing automatic consumer shutdown
path. No persistent Julia coordinator or frame scheduler is added.

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
