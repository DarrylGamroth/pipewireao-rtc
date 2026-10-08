# Native WirePlumber control-plane module load

Date: 2026-10-07. RTC baseline `e791361eaa491dae7e99e1d3df69816de58061a3`;
WirePlumber baseline `4c2648faeff714b19e806e747075f6f9f8f4b02c`. Both include
uncommitted migration changes in their isolated review worktrees.

## Scope

An isolated private PipeWireAO core and draft WirePlumber daemon ran on CPU 14.
A deliberately absent bootstrap owner kept the session CONFIGURING. No
scientific graph, simulator, physical device or existing session was operated.
The harness terminated only its retained child processes.

Runtime logs and configuration: `/tmp/rtc-wp-module-load-yqtfaucn`. The ad hoc
harness is `/tmp/rtc-wp-module-load.py`; these temporary files are supporting
artifacts, not an operational dependency.

## Fail-before/pass-after observations

1. The generated JSON-compatible SPA configuration quoted component dependency
   names. The component loader used `wp_spa_json_to_string`, retaining literal
   quotes and reporting `no component provides '"support.lua-scripting"'`.
   Changing the four dependency-reader calls to `wp_spa_json_parse_string`
   decoded quoted names while preserving bare SPA-JSON strings. The same
   configuration then loaded the dependency chain.
2. A WirePlumber context with only protocol-native could not export the native
   portless control node: `can't export type PipeWire:Interface:Node: Protocol
   error`. Adding the maintained client-node module to the generated context
   allowed the export.
3. The private harness needed an ordinary client configuration and the correct
   Julia codec module name. These were harness corrections, not production
   defects.

After these corrections the Julia client exited zero and received a retained
`AdministrativeCompletion` for operation 15, result zero, lifecycle CONFIGURING
and `warmed=false`. Public endpoint instance `100000000000001` and controller
instance `100000000000003` demonstrate values exceeding 32-bit range.

## Limits

This observes C plugin export, Lua loading, live controller identity proof and
typed native Warmup request/reply. It does not establish successful Admit16,
resource placement, Start/Stop/Reset/Quit, scientific outputs, parameter
publication/adoption, loss cleanup, latency or zero-allocation behavior.
During deliberate process termination the control publication logged a fault;
normal shutdown behavior remains to be qualified. Existing accepted runtime
evidence belongs to the earlier architecture.
