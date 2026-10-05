# Simulator live-control allocation investigation

Starting revision: `57337d6d52db7e23d27a55d58e358995f235b3d7`.
Worktree: `pipewireao-rtc-live-controls`.
Branch: `work/hil-live-controls-20261005`; initially clean.
Evidence directory: `~/.cache/rtc-live-controls-20261005`.

## Contract and scope

Preserve RTC-DEV-025/026 and the successful sustained frame path. Measure valid
status, pause and resume controls after exact-method warmup, including request
delivery, validation, reply publication and paused waiting. Historical file
handoff and interim report work remain the fail-before evidence.
The simulator-process counter remains inclusive between the retained prefix
and final adopted command. Moving work to a task in the same process or
excluding pause intervals does not satisfy this gate. GC must remain enabled.

Preparation, stopped reset, final serialization and exceptional rejection are
separate cold paths. Rejections must remain bounded and preserve state; they
are not permission to weaken validation or delivery guarantees. Required
report output must remain available with truthful ownership and sequence.

The supervisor continues to serialize identities and wait for matching ACKs.
Pause applies after the outstanding command is adopted. A staged request stays
owned until native ACK publication succeeds. Preserve stale-identity rejection,
finite control deadlines and
fail-closed behavior for unknown outcomes. No scientific algorithm, calibration,
seed, graph or model-period changes are selected.

## Selected control transport

The user selected native PipeWire serialization for live controls. Replace the
JSON request/reply file handoff with existing Version 1 run/reset control SPA
`Props` contracts. Reuse their native builders/parsers and token/completion
semantics; do not add a bespoke file or socket wire format. Saved reports may
remain JSON. The serialized simulator owner still applies a staged request
only after the outstanding command is adopted; a parameter callback must not
run optical simulation or reset an in-flight exchange.

The migration must update installed profiles and coordinating supervision
together. Retain failed old-path evidence rather than treating different
serialization alone as a zero-allocation or completed deployment result.

## Investigation order

1. Establish warm fail-before measurements for protocol validation, actual
   file handoff, paused waiting and report construction/serialization.
2. Identify reusable prepared storage and public Julia IO before selecting a
   repair. Distinguish required output from temporary allocation and compilation.
3. Review consequential ownership or protocol changes independently. Keep a
   bounded control mechanism within the existing serialized owner lifecycle.
4. Recheck negative controls and causal delivery using the same fixtures.
5. Qualify installed live midrun pause/resume and stopped reset for both RTC
   graph owners, with inclusive allocation/GC counters and exact payloads.

## Current disposition

Existing continuous/reset zero-allocation evidence is unchanged. The selected
native source-owner increment now passes the installed Classic/Copper FGN/JFG
midrun gate in [validation](LIVE_CONTROL_VALIDATION.md). The historical warm
measurements below explain the retired file path; they are not current native
source measurements. Warm measurements on Julia 1.12.7 observe
2,528–2,592 bytes for protocol handling and 6,928–6,992 bytes for complete
file controls with report generation stubbed. A paused 5 ms sleep allocates
112 bytes; the existing yield/safepoint call allocates zero. JSON3 writing into
a prepared IOBuffer still allocates 880 bytes for a status reply. These are
component measurements, not live optical-path totals.

The private-core native parameter probe delivers token 73 from a separate
client to a source stream and receives the matching completed-token Props.
It uses registered PipeWireAO 0.6.14 and its matching native artifact. Initial
probe attempts did not qualify completion; the two-client setup correction
is test-harness work, not evidence of an RTC defect. Native parser wrappers
in the separate `PipeWireAO-native-owner-control` worktree pass 51 focused
assertions, with zero bytes for all four warmed in-place parsers. These component
checks preceded integration and the composed lifecycle measurements above.

The [native contract](LIVE_CONTROL_NATIVE.md) records the selected request,
coherent snapshot/rejection schemas and report semantics. Independent
[review adjudications](LIVE_CONTROL_REVIEW.md) accept retirement of redundant
pause checkpoints while preserving preparation/reset/final artifacts and
unchanged inclusive counters. Native live status replaces those checkpoints;
the old report writer is not claimed allocation-free. Separate calibration
restoration/report guarantees remain intact.
