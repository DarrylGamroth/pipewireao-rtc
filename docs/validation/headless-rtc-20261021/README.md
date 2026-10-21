# Headless RTC ownership validation — 2026-10-21

## Implemented boundary

[RTC-ARCH-026](../../HEADLESS_RTC_DESIGN.md) moves application lifecycle,
readiness, explicit RTC connections and the native control/journal modules into
the real `pipewireao-rtc` application. It uses public libwireplumber discovery,
hooks and SessionItems as an ordinary client. WirePlumberAO retains device,
access and shared routing policy. systemd retains process supervision.

Work was performed on the existing isolated `codex/wireplumber-reuse`
worktrees, preserving the prior relevant hook and SessionItem changes:

| Repository | Baseline | Worktree |
| --- | --- | --- |
| RTC | `c1b7895b4032624a1024aafb1e858f029fce391b` | `/home/dgamroth/workspaces/codex/worktrees/rtc-wireplumber-reuse-20261021` |
| WirePlumberAO | `0f64f9ef9d7f080a2668470f3904aa3d0ebf92af` | `/home/dgamroth/workspaces/codex/worktrees/wireplumber-reuse-20261021` |

The original checkouts, sealed/pinned applications, live prefix and stopped
workstation RTC were left unchanged. The candidate native install is
`/home/dgamroth/.local/opt/pipewireao-headless-rtc-20261021`. Newly exported
applications require this executable and the matching libwireplumber cohort;
there is no WirePlumber daemon or retired-coordinator fallback.

## Main integration and worktree cleanup

On 2026-10-21 the reviewed changes were committed and fast-forwarded into the
normal checkouts: RTC `main` at `3a15aa0ebed6913aa74e280e57967b392b633667`
and WirePlumberAO `master` at `2c55a872aeaff248c0aa2cbd5c134f8472639e2a`.
The reviewed source hashes match both canonical checkouts. Fresh canonical CPU
builds pass all seven native RTC suites and all five generic WirePlumber suites;
the Julia package imports with the new session interfaces.

Four clean worktrees were removed: the two reuse worktrees, the already-merged
simulator-settings worktree and the old session-rejection checkout. The latter's
unique commit remains on `codex/session-rejection-20261014`. Three fully merged
feature branches were removed. Five historical RTC worktrees with uncommitted
work were left intact. The [integration receipt](integration.json) identifies
all removed and retained paths and records the focused test results.

The simulation remains inactive with MainPID 0. No live prefix was replaced,
service started, GPU initialized, release tagged or remote branch pushed.
The worktree paths elsewhere in this evidence remain historical provenance.

## Verification

| Check | Result | Scope |
| --- | --- | --- |
| Full Julia 1.13.2 package suite | 2,330 assertions across 75 testsets pass | Includes configuration/staging, process identity, native codecs/discovery/clients, simulator replacement and artifact/journal behavior |
| Native RTC suites | 7 pass | Moved connection/owner/acquisition/journal/hook policy, native journal and real application host, including production endpoint Status |
| Generic WirePlumber suites | 5 pass | Existing SessionItems, audio-adapter behavior and event hooks; exact-link executable contains 13 cases |
| Controlled production-policy faults | 7 pass | Source-first fault ordering and failure/uncertainty fencing in the actual relocated Lua policy, with controlled I/O boundaries |
| Actual CPU NDArray/coexistence integration | 19 checks pass | Real application-owned Link, three arrays, withdrawal, unrelated node and minimal WirePlumber peer |
| Fresh generic WirePlumber install | 17 generic modules; zero RTC application assets | No AO control/journal modules or AO Lua policy in the new daemon install |
| Independent review | Three findings corrected; no source-review blocker | Fixed host identity overrides, absolute Lua entrypoint and retained-ledger module qualification |

The full Julia log contains an expected missing-Git-object diagnostic from a
negative artifact test. It has no failed test or error markers; the process
exits successfully. Compilation warnings in the relocated C modules concern
existing unused callback parameters. These do not establish timing or hardware
behavior.

Commands from the RTC worktree:

```sh
julia +1.13 --startup-file=no --project=. test/runtests.jl
meson test -C native/build --no-rebuild --print-errorlogs
julia +1.13 --startup-file=no --project=. \
  test/integration/session_policy_faults.jl native/scripts/ao/session.lua
julia +1.13 --startup-file=no --project=. test/integration/session_items.jl \
  /home/dgamroth/.local/opt/pipewireao-wp-reuse-20261021 \
  /home/dgamroth/.local/opt/pipewireao-headless-rtc-20261021 \
  /absolute/fresh/evidence-directory
```

The independent generic-library selector, from the WirePlumber worktree:

```sh
PIPEWIREAO_CONFIG_DIR=/usr/share/pipewire meson test -C build --no-rebuild \
  test-si-node test-si-standard-link test-si-audio-adapter \
  test-session-item test-lua-event-hooks --print-errorlogs
```

## Actual connection observations

The receipt binds the Link creator to RTC PID `3721692`, application name
`PipeWireAO RTC`, with `wireplumber.daemon=false`. Its native Link joins the
exact published source/output and sink/input port IDs, carrying the declared
F32_LE, row-major, shape `[2]`, 100/1 Hz schema. Three CPU arrays arrive intact.
The production `ao-connections` withdrawal callback succeeds, then the client
registry confirms the correlated Link absent while an unrelated source remains.

An independent WirePlumber daemon, PID `3721691`, remains connected on the
same private core; its observed Client identity has `wireplumber.daemon=true`.
That peer uses a minimal profile with no device monitors or desktop auto-connect
policy. It proves separate-process coexistence, not device-policy or full
desktop compatibility. The helper closes only its own application, peer and
private daemon; their process IDs were subsequently confirmed absent.

This connection profile loads the validation entrypoint and the production
`ao-connections` module. It does not run a complete scientific instrument or
prove native Start/Stop/Reset against FGN/JFG/AOS owners. The relocated lifecycle
retains the reviewed hook/fault tests and unchanged owner interfaces; broader
installed-profile qualification remains separate.

## Actual native session endpoint

The fourth native host case loads the relocated production `ao/session.lua`
and the real session/control endpoint modules, with scientific owners absent.
A second ordinary native application uses production `ao-owner`/`ao-control`
helpers to read capability Props and complete a native Status request.
It verifies the endpoint's actual host PID/profile/incarnation and zero data
ports, plus an Observed completion with lifecycle Configuring and no admitted
groups. Each child has a five-second watchdog. This verifies real native Status
and endpoint relocation, not scientific Start/Stop/Reset/Quit execution.
The native result summary combines the passing suite run with the subsequent
independent focused rerun of all four host cases.

## Evidence and limits

- [Independent review](../../reviews/20261021-headless-rtc/REVIEW.md)
- [Source, binary and verification identities](evidence.json)
- [Full Julia suite](julia-tests.log)
- [RTC native results](native-tests.json)
- [Generic library results](generic-wireplumber-tests.json)
- [CPU integration receipt](cpu-coexistence-receipt.json)
- [Fresh generic install manifest](generic-install-manifest.json)
- [Host identity regression, fail-before excerpt](host-invariants-fail-before.txt)

Meson's inherited environment is deliberately excluded from retained summaries.
The build and installed executable have different file hashes because Meson
removes the development RUNPATH during install; their `.text` dumps agree.
The exact installed binary exercised by integration is hashed in the evidence.

The live RTC remains inactive with MainPID 0. No GPU, simulator, physical device
or workstation session was started. This is CPU software verification and
independent source review. GPU/scientific replay, sustained cadence, allocation,
latency, hardware, all-instrument and live systemd qualification are not claimed.
No public release or live deployment was performed.
