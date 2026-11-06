# Session operation journal removal — 2026-11-06

Baseline: clean `b8fb138`, branch `codex/julia-session-policy-20261104`, dedicated
worktree `pipewireao-rtc-cleanup`. The user explicitly retired the RTC session
operation journal and its write-before-effect requirement. This supersedes that
selection in RTC-DEV-022; its other control requirements retain their meaning.

## Delivered boundary

- Delete the MediaSession SQLite journal, worker, queues and receipt actions.
  Admission dispatches accepted requests without a disk-write gate. Completion
  publishes the correlated reply without waiting for persistence.
- Delete persistence-only Hsm states and mutable attempt bookkeeping. Retain
  exact controller/endpoint identity, canonical duplicate suppression, original
  receipt-based deadlines, Quit supersession, terminal replies and unknown
  outcomes. The native shutdown publication fence remains.
- Stop generating journal paths/properties and remove the journal-only
  `configuration_store_root` keyword from both SessionConfiguration entrypoints.
  Reject stale journal settings before allocating a native loop or connecting;
  regenerate these configurations using the current exporter.
- Generate the session launcher with `--threads=1,0`; the retired writer no longer
  requires an interactive policy thread and a separate default-pool worker.
  The existing shared argument builder still supplies exact process verification.
- Remove `ConfigurationStore.history`, the configuration management `history`
  operation, and operation-event schema/migrations. The native management
  companion rejects that operation. External clients using it need migration.
- Retain Git artifact bytes/manifests and the SQLite catalog. Keep the existing
  `history.sqlite3` filename so existing stores remain accessible. Opening them
  neither deletes historical operation rows nor modifies their old schema.

Optional saved calibration evidence, systemd logs and management job receipts
have separate purposes and remain. SQLite/DBInterface still serve the artifact
catalog; Agent.jl still runs the serialized session control loop. No dependency
can be removed merely because the journal used it too.

## Deferred recording

A separate service may follow SPIDERS `~/spiders-working/archiverservice`:
subscribe to streams, retain verbatim messages in rolling files and build an
index for queries/replay. That working tree was inspected read-only and has
pre-existing edits, which were preserved. No archive implementation, new
recording protocol, retry, rollback or session-restoration mechanism is added.
Asynchronous recording does not restore the retired write-before-effect
guarantee.

## Verification

The catalog/API changeset is `1310196`.

- Julia 1.13.3 catalog, management and analysis-capture selectors: 201 passing
  assertions. Fresh stores lack `operation_events`; reopening a store preserves
  its exact old operation schema/rows and still retrieves/materializes artifacts.
- Management companion build and its five JSON tests pass. Local json-c discovery
  uses `PKG_CONFIG_PATH=/tmp/rtc-management-json-pkgconfig-20261105`, with build
  output in `/tmp/rtc-no-journal-management-build-20261106`.
- Focused ingress, session-configuration, auxiliary-source and instrument
  declarations: 608 assertions pass. This first run precedes the additional
  parameter-dispatch and stale-configuration assertions. The final ingress
  selector passes 225 assertions,
  including immediate property/parameter dispatch and Submitted versus active
  adoption semantics. Log: `/tmp/rtc-journal-ingress-final-20261106.log`.
- Native host: 46 assertions pass with `--threads=1,0` in the existing optional
  source-cohort environment `/tmp/pipewireao-rtc-optical-types-env`. It owns its
  private core and checks mapped-request disconnect, unknown outcomes and Quit
  publication failure/expiry. Log: `/tmp/rtc-journal-host-20261106.log`.
- Native discovery/cleanup: 42 assertions pass with `--threads=1,0` in the same
  source-cohort environment. Startup cancellation, active/pending Link release
  and cleanup after bound-object failure remain valid. Log:
  `/tmp/rtc-journal-private-core-20261106.log`.
- Generated-launcher public process: 8 assertions pass, including exact saved
  process binding, discovery, Warmup/Status/Groups and startup Quit. Initial
  AcquisitionLifecycle Hold/cold Shutdown: 35 assertions pass. Both selectors
  use `--threads=1,0`, the same optional environment and explicit
  `PIPEWIREAO_PREFIX=/tmp/pipewire-command-endpoint-native4-sdk-20261104`.
  Logs: `/tmp/rtc-journal-process-20261106.log` and
  `/tmp/rtc-journal-acquisition-20261106.log`.
- An independent read-only review of ingress/session/configuration changes found
  no defects. It checked duplicate suppression, deadline/late replies, Quit
  completion in either order, slot release before shutdown publication and
  rejection of stale journal configuration before native allocation.

The first core run stopped on two new stale-configuration expectations: its
older PipeWireAO dependency rejected the missing `iterate!` API before reading
configuration. Cold configuration validation now precedes that capability guard;
both remain before native resource allocation. The failure is preserved in
`/tmp/rtc-journal-core-20261106.log`. An initial continuation command resolved
relative includes from the package root and failed before running selectors;
the corrected continuation uses the test directory. Its logs are
`/tmp/rtc-journal-core-remainder-20261106.log` and
`/tmp/rtc-journal-core-remainder-final-20261106.log`, respectively.

The core selectors complete in two segments: 6,203 assertions in 300 passing
summaries before the failed configuration set, then 5,110 assertions in 212
passing summaries from the corrected configuration selector through the end.
That is 11,313 passing assertions across the suite, including its subprocess
selectors, rather than one uninterrupted green command. The continuation also
verifies the changed launcher/export/install paths and the stale-configuration
tests. The final process exits successfully without warnings or test failures.

Formatting checks use the existing JuliaFormatter 2.14.8 environment, preserve
parsed syntax/literals and check idempotence. Documentation checks pass 46
assertions for changed navigation, whitespace/newlines and preserved requirement
identities. Historical evidence is unchanged.
No existing service, installed application, instrument or experiment is modified.
These are software checks, not scientific, hardware, sustained-cadence or RT
qualification.
