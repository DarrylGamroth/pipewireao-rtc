# Installed native calibration qualifier: independent review

Date: 2026-10-06. Initial source:
`987297ba5fc6a9a358b19a2be2347ee6784c0586`, clean worktree
`pipewireao-rtc-native-calibration-consumer`. Independent documentation worktree:
`rtc-bootstrap-allocation-review`, initially clean at `e79a153`. This review
covers `deployment/qualify_calibration_native.jl`, its focused tests and
`docs/NATIVE_CALIBRATION_CONSUMER_QUALIFICATION.md`, with supporting native
clients, campaign validators and retained cold preparation evidence.

No production edit, build, SCI execution or test rerun was performed. Source
and cold evidence were inspected; lightweight data reads used CPU 11. The
qualifier is development evidence tooling under RTC-DEV-029/030. It does not
establish matrix accuracy, inverse quality, correction performance, latency,
allocation or physical-device acceptance.

## CAL-QUAL-R001 — Success precedes retained-client cleanup

**Severity:** high. **Confidence:** high. **Classification:** observed source
control flow; injected failure validation required. **Affected:** `main` success,
outer catch/finally and exit reduction.

At `987297b`, the callback passed to `D.wait_state` sets `record["success"] = true`
before returning. `D.wait_state` then closes the retained native supervisor in
its `finally`. Native client close can throw aggregated cleanup failures.
The qualifier's outer catch records `failure` without clearing success, and
its final return tests success alone. Therefore a close failure after an
otherwise complete run yields `success=true`, a recorded failure, and exit zero.
Outer action/lifecycle cleanup errors are similarly recorded without
invalidating success. This is a confirmed acceptance defect; no actual
installed calibration failure is inferred.

**Proposed remediation:** assign success only after the full normal callback
scope has returned, clear it on every primary/client-cleanup failure, and make
the final reducer require failure-free restoration, release, shutdown and
complete owned cleanup. Preserve diagnostics and conservative ownership behavior.
**Required validation:** an injected post-callback close failure must yield a
failed record and nonzero exit with the same discriminator before and after;
ordinary success remains accepted. **Disposition:** primary notified before SCI;
remediation worker independently confirmed and is preparing the narrow fix.

## CAL-QUAL-R002 — Reset oracle omits lifecycle and publication facts

**Severity:** medium. **Confidence:** high. **Classification:** observed source
acceptance gap; no owner misbehavior observed. **Affected:**
`verify_reset_rejection` and its `facts_unchanged` claim.

The oracle requires a Connected rejection with result -95, then compares the
before/after current cursor, phase, hold, restored, completed and running facts.
It does not compare the subsequent lifecycle or published report cursor.
A successful Status completion with Stopped lifecycle or a missing/changed
report cursor would pass if the listed fields match. Before Reset, those facts
were explicitly established as Connected and published at the current cursor.

**Proposed remediation:** compare lifecycle and the optional report cursor, with
absence handled explicitly, and preserve the snapshot failure fact where
available. **Required validation:** injected otherwise-identical completions
with changed lifecycle and lost/moved report cursor are rejected; unchanged
unsupported Reset remains accepted. **Disposition:** sent to primary and
remediation worker for adjudication; not an observed reset implementation bug.

## Reviewed boundaries

- Foreground launch is fresh and owned. The retained admission client is checked
  against live supervisor UUID and exact launcher PID. Child identities include
  observed parent/group/session and process start time before any cleanup audit.
- Lifecycle and action connections use explicit remote, node, owner PID and
  incarnation. Existing public clients additionally validate native node/global
  serial/profile/capability and correlated controller/request identity. Saved
  startup metadata is compared with the fresh native cursor and plant hash;
  it does not establish readiness by itself.
- Rust Collect uses the installed finite plan and a 180-second bounded
  subprocess/output budget. The oracle checks the declared four batches,
  response extents, finite Float32 values, domain/generation/duration, ordered
  contributing exposures and discarded-exposure gaps. It does not compare
  response values with an independently computed interaction matrix.
- Julia Capture sequences Hold, Adopt, Settle, two-frame Capture, immutable
  artifact verification, Restore and Release. It checks unchanged/unclipped
  adopted and restored figures. The existing capture validator binds run,
  request serial, stage, probe, exposure/channel contracts, payload byte counts
  and hashes to the native completion and admitted settings.
- The 20-second absolute Capture transaction deadline is shared across its
  action sequence; individual actions do not reset it. Native report polling
  has its own finite deadline, requires released/unheld/restored Connected facts
  and matching current/publication cursors, then checks saved report bytes.
- Julia failure handling does not issue speculative Restore/Release after
  unknown action completion. Its client retires unknown outcomes. The Rust
  transport also retires resources on unknown transport failure; the existing
  coordinator's recovery effect cannot silently reconnect a retired endpoint.
- Normal cleanup uses native session stop/quit on the retained admitted client,
  launcher exit and saved stopped report, private-instance removal, then an
  observed detached-child group audit. Failure fallback signals only the owned
  `Base.Process` with bounded waits, preserving unknown detached-group status.
  No arbitrary numeric PID/group is signalled.

Capture request records are returned into the result only when `capture!`
completes. A failed intermediate capture may therefore retain its error and
owner/deployment logs without the complete sequence of known action replies in
the qualifier JSON. This is an evidence-retention limitation, not a claim that
unknown actions were safely resolved or that failed qualification is accepted.

## Cold evidence inspected

Cache root: `~/.cache/rtc-native-calibration-final-20261006/`.

- Original focused log has 26 passing assertions: four report-publication,
  seventeen Collect evidence and five unsupported-Reset checks. It does not
  exercise real calibration or the outer failure reducer.
- Preparation index reports 560 sealed artifacts, 332 unchanged protected
  scientific files, 500,504-byte capture budget and a 2,568-byte Collect reply.
  The independent pass inspected the index/validation document and verified
  their relationship; it did not repeat all package hashes or run a plant.
- Frozen plan SHA-256 is
  `f6d8d2a29119ac437a0b36e60d0d88cbe986f4dce27c1691179f8ac1c181d011`.
  The installed provenance declares `calibration_stage=native-functional`,
  matching the Capture verifier's expected stage.
- Preparation validation SHA-256 is
  `45194a6e00a780c3a2d99e98ac38c67eba69ea020a9243949fc145cea0d6a6f3`;
  original index SHA-256 is
  `3605363c17c231b3fbe24357a79d0289214c4180aab369730365c228c15c1cfb`.
  These identify the initial cold checkpoint, not later coordinator repairs.

## Initial disposition

Do not promote `987297b` as ready for accepted SCI qualification until
CAL-QUAL-R001 is corrected and verified. The remaining reviewed orchestration
is suitable for a bounded functional experiment after adjudication. Actual
installed Collect, Capture, restoration, unsupported Reset, immutable evidence
and normal cleanup are still experimental gates. The first Classic FGN fixture
does not silently replace the broader Classic/Copper, FGN/JFG and unchanged
HEART consumer matrix.

## Independent remediation verification

Primary adjudicated both findings; the remediation worker independently
confirmed them before modifying source. Final clean repair commit
`f2ad4229a2b8d833b232191abe383ad070c31bf2` was independently inspected.

- R001: success now follows the entire normal `wait_state` and log scope.
  Primary errors and client/fallback cleanup errors explicitly clear success.
  The final reducer requires no failure, restoration/release, shutdown,
  launcher exit and a nonempty set of completely retired owned groups. Saved
  success is normalized through that reducer before writing evidence; exit uses
  the same reducer. Normal cleanup ordering remains unchanged.
- R002: Reset now requires before/after Connected lifecycle equality and exact
  nullable publication-cursor equality as well as the prior snapshot fields.
  The current Snapshot has no separate failure field. Stopped, missing report
  cursor and changed report cursor are each covered by discriminating fixtures.

The retained close oracle uses an actual private-core native supervisor and
`D.wait_state`. It injects `client.active=true` just before callback return so
the real close method refuses cleanup; diagnostic cleanup then clears the flag
and closes the client. The identical failure-containing record yields exit zero
before the fix (two pass, one fail) and exit one under the corrected reducer
(three pass). This proves the native close error and reducer behavior; complete
`main` callback-scope ordering is verified by source, not a full installed run.
The fixture printed registered SDK source `PipeWireAO/QRGDD`; it makes no
allocation or installed-science claim. The repaired pure suite passes 44/44,
including the previously failing Reset invariants and twelve reducer checks.

Evidence is committed with the source under
`docs/validation/native-calibration-20261006/`. All five file hashes in
`remediation-receipt.json` were independently recomputed and matched, as did
the repaired qualifier source hash
`234adfc24695e1ff8a49eadf17587f0b8ab1d13816990ef5812512d17ee629f3`.
The receipt correctly notes that the after log printed baseline `987297b` while
running the then-uncommitted repair; the recorded source hash identifies the
actual repaired bytes. This reviewer read source, fixtures, logs and hashes but
did not rerun tests.

**Final review disposition:** CAL-QUAL-R001 and CAL-QUAL-R002 are corrected and
accepted by independent source/evidence review. No further confirmed qualifier
blocker was found. The coordinator is ready for the primary's separately
reserved functional SCI attempt; installed Collect/Capture and broader consumer
qualification remain pending. This does not override independent runner
availability findings in `NATIVE_RUNNER_MAINTENANCE_REVIEW.md`.
