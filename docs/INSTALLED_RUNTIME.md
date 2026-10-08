# Installed AO runtime

Scope: install the current PipeWireAO and WirePlumberAO under `/opt/pipewireao`
and export sealed session packages from installed assets. RTC-ARCH-025 keeps
WirePlumber Lua as session authority and systemd as process owner. Scientific
algorithms, graph configurations, native controls and placement are unchanged.

## Delivery sequence

1. Build PipeWireAO with the existing multiarch library directory and AO-only
   runtime options. Stage the install. Preserve external SPA plugins and the
   running GUI/HIL cohort; replace installed files atomically.
2. Build WirePlumberAO against the installed AO pkg-config identities. Install
   its binary, library, modules and Lua scripts in the same prefix. Do not enable
   a desktop session-manager unit. RTC owns private session service generation.
3. Make the exporter copy installed WirePlumber assets into the existing sealed
   package layout by default. Retain explicit build/source inputs for development
   builds. Validate inputs before replacing the package's staged manager.
4. Check dependency selection, installed-only loading, selected Copper CPU
   FGN/JFG with CUDA AOS admission, native controls and cleanup; independently
   review the exporter and preserve installation provenance.

The prefix is user-owned on this host; no root privileges or host scheduling
policy changes are needed. Tests and builds live in temporary directories. No
running service is restarted. Timing, other profiles and physical devices retain
their existing qualification limits.

Build commands and observed installation checks are recorded in the
[dated validation receipt](validation/installed-runtime-20261008/README.md).
Installed runtime assets are the default export prerequisites. Explicit
development build/source selection remains available.
