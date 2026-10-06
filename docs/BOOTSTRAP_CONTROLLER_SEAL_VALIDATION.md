# Ordinary-owner bootstrap controller retention

## Decision and scope

The ordinary source bootstrap retains the exact controller of its successful
Connect before Connected is published. The supervisor already retains that
same bootstrap client across source reset through Quit. Its public endpoint
continues to discover independent GUI/operator controllers dynamically.

The source closes its separately owned registry listener and calls the public
SDK `stop_global_tracking!` API. It keeps the registry and the accepted bound
Node proxy open. The generic endpoint skips discovery only when this explicit
retained identity is present. Other profiles remain dynamic. No wire schema,
scientific graph, prefix length, allocation budget or GC policy changes.

Bound NodeInfo property proof, proxy node removal and connection errors remain
authoritative. Revocation after Connected faults and cancels the owner. New
independent direct bootstrap clients cannot gain authority after Connected.
Status and Quit use the retained client; there is no rebind or retry. Accepted
Connect/Quit still check their exact controller and absolute deadline.

## Observed mechanism

The SDK global callback copies global/type/property metadata before application
filtering; bootstrap's separate managed registry listener also copies globals.
Refreshing controllers traverses copies and binds temporary operator nodes.
Stopping only wake processing therefore cannot remove the process allocations.
The bound proxy event listener is separate from both registry event listeners.
The SourceControl stream endpoint has no registry listener.

## Same cold allocation discriminator

An ordinary no-SCI private core runs the bootstrap owner in one Julia process.
Its retained primary controller and a foreign publisher run in separate Julia
processes. The foreign publisher exports and removes an actual inactive,
zero-port native controller node during the owner's inclusive `Base.gc_num`
window. Native identities and monotonic event timestamps are verified. The
same assertion requires zero bytes and no GC before and after the change.

| Owner implementation | Bytes | Pool | Malloc | GC | Oracle |
| --- | ---: | ---: | ---: | ---: | --- |
| Unsealed, RTC 92444413e4930e1191821b8a402301307fbaca2a | 3,765,232 | 73,084 | 16 | 0 | 8 pass / 1 fail: zero-byte assertion |
| Sealed candidate | 0 | 0 | 0 | 0 | 9/9 pass |

Both actual birth and removal timestamps lie strictly inside their owner
measurement window. A quiet baseline was zero in both cases. Quit and owned
cleanup completed. `usleep` may return early when interrupted; timestamps prove
the relevant events occurred inside the observed window, rather than assuming
an exact three-second duration.

The initial helper attempted captured assignments from top-level scope and
failed two event witnesses; its allocation number is not accepted evidence.
A second preparation attempt lacked its output directory. Both failed logs
remain preserved. The corrected helper runs the resource lifecycle in a
function and creates its output directory before measurement.

## Reproduction and verification

Standalone scripts are under `deployment/julia/test/`:

- `native_owner_bootstrap_churn.jl SDK_ROOT RTC_JULIA_PROJECT OUTPUT_DIRECTORY`
  launches the external native peers from `native_owner_bootstrap_churn_peer.jl`.
- `native_owner_bootstrap_sealed.jl` tests retained authority, foreign discovery
  rejection, bound proof/node/connection revocation, pending Quit expiry/removal,
  exact lifecycle and cleanup. A warmed direct poll zero-byte check is a
  microbenchmark, separate from the inclusive external-peer measurement.
- Existing `native_owner_bootstrap.jl` preserves Preparing/Prepared behavior,
  exact identity, foreign deadline neutrality, busy, Connect main-thread effects,
  Fault, accepted expiry/removal and terminal flush.
- Existing `native_owner_bootstrap_idle.jl` preserves quiet whole-process zero
  allocation and wake/health checks.
- Generic `native_control_endpoint.jl` and its fault suite exercise unchanged
  dynamic controller discovery outside the sealed bootstrap.

Final focused results are 66 retained-authority assertions, 49 existing bootstrap,
12 idle and 105 generic dynamic endpoint/profile/fault assertions (232/232);
the final repository external-peer fixture passes 9/9 with zero bytes.

Run with Julia 1.12.7, `--threads=2,0`, ordinary CPU15,
`prlimit --rtprio=0:0`, offline cached packages. Load the selected SDK before
adding the RTC project to LOAD_PATH, so an old dependency manifest cannot select
another SDK. No dependency resolution, real-time scheduling or science runs
are part of these checks. Exact commands, logs, source hashes and totals are in
`docs/validation/bootstrap-seal-20261006/receipt.json`.

## Remaining gate

Independent source review is required before production integration. Root must
qualify a freshly sealed installed source package against the unchanged
496-exchange whole-process zero-allocation gate with late GUI attach/retire.
The cold evidence establishes this specific registry-discovery mechanism; it
neither proves every prior SCI allocation's origin nor changes the scientific
trajectory/reset/death/picker gates.
