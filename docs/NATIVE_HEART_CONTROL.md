# Native HEART wrapper control

RTC-DEV-030, issue #5. This is the cold control profile of the existing
supervised HEART wrapper, not a replacement for vendor HEART TCP commands,
pixel processing, reconstruction, integration or DM transport.

## Wire contract

Use the common version 1 control envelope and lifecycle bounds: 16 KiB request,
64 KiB reply, finite remaining request budget bounded at 30 seconds. Actual
reset keeps the existing 12-second absolute owner bound. Profile advertisement
is `pipewireao.rtc.heart/1`; capability fields use the exact six-field
`pipewireao.rtc.heart` namespace and actual controller incarnation proof.

Operation Id 1 is Status; Id 2 is Reset; Id 3 is Connect; Id 4 is Shutdown.
All payloads are empty Structs.
Lifecycle Ids are Preparing=1, Ready=2, Fault=3, Stopped=4.
Ingress Ids are Streaming=1, Deferred=2. No state or operation is inferred from
file presence, an unverified name or a guessed process ID.

Completion payload is a three-field Struct: lifecycle Id, snapshot Struct
(or explicit None for a failed request without an available snapshot), and
bounded UTF-8 message. A successful completion requires a snapshot. A queued
request's expiry/removal preserves actual owner lifecycle and uses None;
it must not invent a child exit, generation reset or ingress mode.
Rejection payload is lifecycle Id and bounded message. It can echo an unknown
operation in a correlated rejection or use the zero-identity initial sentinel.

The snapshot has nine exact fields:

| Field | SPA representation |
| --- | --- |
| Generation | nonnegative Long |
| Child PID | positive Id or None |
| Child return code | Int or None |
| Child alive | Bool |
| Ingress mode | closed Id |
| Placement validated | Bool |
| Diagnostics disabled | Bool |
| Immutable generation report path | bounded UTF-8 String, maximum 4,096 bytes |
| Report SHA-256 | empty or 64 lowercase hexadecimal characters |

A Ready snapshot requires positive generation, alive child, assigned PID,
absent exit code and nonempty report path/hash. Message limit is 8,192 bytes.
Fields retain exact type/width; numeric conversion does not admit malformed
Float/Int substitutions.

## Owner and caller obligations

The wrapper publishes Preparing on one no-port endpoint before child startup.
The supervisor binds the actual spawned wrapper PID and declared incarnation,
waits for Ready under its original preparation deadline, then requests fresh
Status and Connect completions. Connect acknowledges preparation; the runner
still owns graph links. There are no HEART preparation, connection or shutdown
marker files. The owner descriptor declares `control-protocol` and an exact
`control-node` instead of those four marker fields.

Shutdown runs the existing finite child-stop path outside callbacks and publishes
Stopped with a nonalive snapshot after child exit. A public core synchronization
acknowledgement flushes the terminal publication before endpoint removal, under
the accepted deadline. It does not prove that a disconnected caller received
the reply. Unresolved shutdown remains an unknown outcome; final owned-process
group cleanup revokes remaining children without reconnecting or retrying it.

The wrapper owns one no-port endpoint on its control loop. Existing serialized
owner code executes restart outside PipeWire callbacks. It checks the accepted
ticket before effects, observes caller/core lifetime and uses the original
deadline. Reset completes only after the old child exits, replacement startup
acknowledgements succeed, placement is validated and a new generation report
is sealed. Unknown outcomes must not be retried or sent through a file fallback.

The complete generation report remains a saved artifact, verified against the
path/hash from a fresh native completion. It is not live health authority.
HEART calibration/correction consumers retain their config, executable,
calibration, ingress and acknowledgement checks using that verified report.
Native capability/completion subscriptions fence later owner faults, changed
generation/child identity and control transport loss without rereading mutable
status JSON per frame.

A latest completion with no snapshot cannot authorize a health check, even if
the owner remains Ready. The client reports an unknown outcome until a fresh
successful status provides the current child identity. This prevents a failed
request from erasing evidence of an intervening reset. The actual owner lifecycle
is preserved; a missing snapshot does not fabricate a child fault.

Implementation and deployment qualification remain partial until these owner
and caller obligations are wired and tested on the unchanged HEART executable.
