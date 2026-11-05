# Installed AO runtime

## Current selection — 2026-11-04

The user selected replacing both Lua and libwireplumber with the Julia
`MediaSession` owner using PipeWireAO.jl's public APIs. Production packages stage
a generated Julia launcher and the selected Julia project; they do not stage
Lua or libwireplumber assets. An independent WirePlumber process may provide
separately declared site/device policy, but is not an RTC dependency or a second
session authority. RTC-ARCH-026's allocation of lifecycle ownership to the
headless RTC and process ownership to systemd remains in force. This migration
is underway and is not ready or qualified;
follow the [current roadmap](roadmap.md#current-work) and
[migration record](SESSION_POLICY_MIGRATION.md).

The installation steps and receipt below describe the earlier libwireplumber
selection. They remain historical evidence only and are not current deployment
instructions.

## Historical delivery sequence — 2026-10-08

1. Build PipeWireAO with the existing multiarch library directory and AO-only
   runtime options. Stage the install. Preserve external SPA plugins and the
   running GUI/HIL cohort; replace installed files atomically.
2. Follow the sibling [PipeWireAO build and package guide](../../wireplumber/packaging/pipewireao/README.md)
   to build/package upstream WirePlumber against the installed AO pkg-config
   identities. Its packaging overlay and optional fixes do not define or enable
   site/device policy. Configure any required site/device policy separately
   with stock WirePlumber configuration. Do not enable an unconfigured desktop
   session-manager unit. RTC owns its session service generation.
3. Build and install [the native RTC](../runtime/README.md) against libwireplumber.
   The executable, AO control/journal modules and application Lua scripts belong
   to RTC, not the WirePlumber daemon. Export generic library assets separately
   from RTC assets, with explicit native build/source or installed-prefix inputs.
   Validate both before replacing staged resources.
4. Check dependency selection, native host loading, exact application-owned
   links, native controls and cleanup on an isolated CPU core; independently
   review ownership and preserve installation provenance. Earlier CUDA/Copper
   checks retain their recorded provider and do not qualify this host.

The ordinary Git fork is retained for contributing patches upstream; runtime
names remain upstream WirePlumber. RTC library assets continue to be staged
separately. Sealed RTC packages contain no device-policy configuration or daemon;
the generic library scripts are staged as dependency assets.

The prefix is user-owned on this host; no root privileges or host scheduling
policy changes are needed. Tests and builds live in temporary directories. No
running service is restarted. Timing, other profiles and physical devices retain
their existing qualification limits.

The former selection's build commands and installation checks are recorded in
the [dated validation receipt](validation/installed-runtime-20261008/README.md).
They do not qualify the selected Julia runtime or establish current export
prerequisites.
