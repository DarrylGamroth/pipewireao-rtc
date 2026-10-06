# Acquisition Connect failure diagnostic

The first installed Classic Collect attempt failed before admission. Its
[retained failure evidence](../actual-four-functional/README.md) establishes
neither the underlying exception nor successful calibration actions.
The typed lifecycle client previously discarded a failed Connect reply behind
`acquisition owner Connect did not complete`. The parent authorised a diagnostic
repair without changing acceptance or effect semantics.

Private methods dispatch on `Completion` and `Rejection`. Failure text retains
result, lifecycle, endpoint instance, token, operation, snapshot presence and
the quoted complete bounded message. Successful Connect still requires a
Completion, result zero, Connected and a nonempty Snapshot. A Rejection cannot
satisfy these conditions. No RPC, capability, wire, deadline, retry, cleanup,
SCI callback or ownership behavior changes.

Source inspection confirmed the same detail loss in failed Status and in a
successful Status whose lifecycle changed before discovery completed. Those
paths share the diagnostic while preserving their existing conditions. The
capability readiness policy remains unchanged.

The [same cold injected oracle](native_acquisition_connect_diagnostic_oracle-20261006.jl)
extracts the original Connect checks from the exact e01 source retained with
the actual failed run. It supplies result -5, Fault and a known message. The
old checks reject the reply but lose all six requested fields: 1 pass/6 fail.
The repaired checks retain them: 7/7 pass. See
[before](native-acquisition-connect-diagnostic-before-20261006.log) and
[after](native-acquisition-connect-diagnostic-oracle-after-20261006.log).

Focused checks cover accepted replies, failed result, Fault, absent Snapshot,
Rejection, empty messages and the 8192-byte wire message limit. The client,
codec and deployment suite passes 329/329; calibration and correction qualifier
regressions pass 330/330. A first ad-hoc runner's missing module `include`
definition is recorded in the receipt and its original log retained; the
corrected separate runners passed all suites.

This is cold software evidence only. Existing installed packages remain
unchanged and sealed. The helper must be copied into a fresh sealed runtime
before a parent-authorised retry can capture the actual owner fault details.
