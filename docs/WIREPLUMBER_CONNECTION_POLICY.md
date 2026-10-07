# WirePlumber declared connection policy

This records the observer/monitor increment before link ownership transfer.
Use the [current roadmap](roadmap.md#current-work) and
[realization design](WIREPLUMBER_REALIZATION_DESIGN.md) for the subsequent
pre-admission opt-in integration; the baseline states below are historical.

Baseline: RTC `e605831`, clean dedicated branch
`feat/wireplumber-connection-policy-20261007` at
`/tmp/rtc-wireplumber-policy-20261007`. CPU FGN/JFG with CUDA AOS, Copper
complete-frame, unchanged scientific artifacts, non-actuating private core.
CPU0/1 remain excluded. HEART and the desktop session are outside this change.

## Delivery and ownership

The approved sequence resolves declared endpoints, checks connections while RTC
owns links, verifies loss/replacement/readmission, then evaluates transfer.
Cleanup of duplicated link management follows demonstrated parity and an
accepted ownership change; removing it earlier would remove current admission
and cleanup behavior.

At baseline the periodic monitor did not consume required link state, and
external node/port snapshots used reusable IDs. Both are corrected through the
existing serialized lifecycle: required link failures/removals and external
removal events stay latched until reload. The exact checks, preserved failures
and independent review are in [the qualification](validation/wireplumber-connection-policy-20261007/README.md).

The installed optional WirePlumber service currently starts after RTC admission
and source release. It cannot become the initial link realizer without changing
that startup boundary. Link ownership transfer also needs realization-scoped
withdrawal across unload/retry within the same runtime process. Existing native
PipeWire links and ObjectManager operations supply the mechanism, but the
current native lifecycle exposes no such connection transaction. An observer
journal or saved file is not admission authority.

Keep RTC link ownership during the declared-policy checks. After the loss and
replacement checks, adjudicate the transfer against the architecture review's
requirement that it reduce maintained responsibilities. Do not add a new command
bus solely to replace link create/drop calls. A transfer remains unproved until
its exact live authority, cancellation, bounds and cleanup pass.

## Coverage plan

| Contract / finding | Implementation allocation | Verification | State |
| --- | --- | --- | --- |
| RTC-DEV-002/003, AAR-02/09 | Standard session configuration supplies names, ports, schema, shape, element type, rate and passive links; bind exact observed IDs/serials and native role owner PIDs | Reject missing/duplicate endpoints, wrong owners/contracts; check multiple sources/sinks sharing an owner | Cold 26/9 assertions and selected live native Format checks pass; general multiple-endpoint AOS runtime remains unqualified |
| RTC-DEV-006 | Optional observations remain outside required topology and source release; WirePlumber remains an optional metadata observer | Observer loss does not revoke RTC; unrelated/optional objects do not substitute for required declarations | Both readmission runs preserve exact prefixes after observer death; cold optional-node checks pass; existing broader observation evidence retains its own scope |
| RTC-DEV-004/013/021, WPA-01/02 | Periodic RTC monitor checks required link failure/removal and captured external endpoint incarnation through existing failure handling | Fail-before/pass-after link removal in Ready/Running; replacement/ID reuse; source revocation, bounded cleanup and fresh admission | Private-core checks and both selected deployed loss/readmission paths pass; same-ID behavior is unit coverage; graceful fault teardown and revocation latency remain unqualified |
| AAR-01/02/04/09 | One designated owner; downstream order, passive semantics, finite admission and realization-scoped withdrawal before transfer | Runtime/WP/core loss, pending withdrawal, failed intermediate link and delayed callbacks cannot recreate/release stale work | Missing transfer interface; retained RTC ownership |
| RTC-DEV-030 | Native supervisor/runner/owner controls retain admission and source authority | Fresh live identities, no JSON-valued live control metadata or readiness files | Existing interface retained; no new protocol |

Multiple declared endpoints can share one AOS lifecycle owner. This does not
qualify a general mixed-rate multi-output optical simulation. Every object/link
in the current RTC session configuration is required; optional observation
branches use the existing separate observation boundary. Do not silently make
required declarations optional or extend the configuration grammar under a
policy helper.

Step 4 remains unproved; current link-management code is still required.
The scoped observer/monitor correction can be merged independently, but it
does not authorize deletion of the RTC's link realization or cleanup machinery.
The architecture review explicitly permits retained RTC ownership when transfer
does not reduce maintained responsibilities. Reevaluate a transfer only with
the missing startup/withdrawal boundary made concrete.

## Naming and layout

`deployment/julia/` is an idiomatic Julia package root: Project/Manifest, src,
test and assets. Its parent `deployment/` describes installation/export assets,
but also contains qualification entrypoints and runtime resources. After the
parity gate, separate those responsibilities while retaining the Julia package's
public identity and installed entrypoints. A directory rename alone is not a
package-layout correction.

Julia does not prescribe the name of a package's parent directory. A later
source-layout cleanup can follow JFG's existing `julia/<Package>/` pattern:
`julia/PipeWireAODeployment/` for this runtime package, `deployment/` for units,
profiles and installation assets, and development qualification tools alongside
the existing scripts/tests. Installed package paths are a separate compatibility
boundary. JFG's current `deployment/Project.toml` is a runnable environment, not
a second library package; its name describes that purpose. Do not relocate
working entrypoints solely to claim Julia convention compliance.

Use the existing domain terms: session, required object, external endpoint,
observer, deployment profile, graph configuration and test data. WirePlumber's
own tests do use `fixture` (`tests/common/base-test-fixture.*`), as do PipeWire's
pytest tests. That term is appropriate for test setup; current operator-facing
uses for an installed profile or simulation should name the profile or run.
Historical receipts, quoted results and external identifiers retain their names.
New policy names use WirePlumber's ObjectManager, port, link, Format and standard
SPA-JSON component arguments; no alternate graph-authoring format is selected.
