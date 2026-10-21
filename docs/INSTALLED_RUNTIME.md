# Installed AO runtime

Scope: install the current PipeWireAO and WirePlumberAO under `/opt/pipewireao`
and export sealed session packages from installed assets. RTC-ARCH-026 selects
the headless RTC as application authority and systemd as process owner. Scientific
algorithms, graph configurations, native controls and placement are unchanged.

## Delivery sequence

1. Build PipeWireAO with the existing multiarch library directory and AO-only
   runtime options. Stage the install. Preserve external SPA plugins and the
   running GUI/HIL cohort; replace installed files atomically.
2. Build WirePlumberAO against the installed AO pkg-config identities. Install
   its binary, library, modules and Lua scripts in the same prefix. Do not enable
   a desktop session-manager unit. RTC owns private session service generation.
3. Build and install [the native RTC](../native/README.md) against libwireplumber.
   The executable, AO control/journal modules and application Lua scripts belong
   to RTC, not the WirePlumber daemon. Export generic library assets separately
   from RTC assets, with explicit native build/source or installed-prefix inputs.
   Validate both before replacing staged resources.
4. Check dependency selection, native host loading, exact application-owned
   links, native controls and cleanup on an isolated CPU core; independently
   review ownership and preserve installation provenance. Earlier CUDA/Copper
   checks retain their recorded provider and do not qualify this host.

The prefix is user-owned on this host; no root privileges or host scheduling
policy changes are needed. Tests and builds live in temporary directories. No
running service is restarted. Timing, other profiles and physical devices retain
their existing qualification limits.

Build commands and observed installation checks are recorded in the
[dated validation receipt](validation/installed-runtime-20261008/README.md).
Installed runtime assets are the default export prerequisites. Explicit
development build/source selection remains available.
