# Native headless RTC

`pipewireao-rtc -c /absolute/path/to/rtc.conf` runs the RTC application using
public libwireplumber `WpConf`, `WpCore`, component activation and a GLib main
loop. The executable always selects the `ao-rtc` profile. Its configuration uses
the library's `wireplumber.profiles` and `wireplumber.components` sections;
those names identify the library format, not a daemon-owned application.
Configuration fragments are disabled. Application identity, profile and
ordinary-client mode are imposed after configuration properties are merged.
The host does not select the manager socket.

The RTC owns `scripts/ao/session.lua`, `scripts/lib/ao-*.lua`, its control
endpoint and journal plugins. Reusable SessionItems, factories and event hooks
remain in libwireplumber and its generic modules. The application modules keep
`libwireplumber-module-*.so` filenames because that is the library's plugin
loading boundary. The control endpoint hosts no frame-processing callback.

A successful, fenced Quit marks a private core property before disconnecting.
An unexpected disconnection or an unfenced/failing Quit exits with status 69;
SIGINT and SIGTERM exit with status 0. Configuration errors return 78, usage
errors 64, and other initialization errors return nonzero. systemd remains the
process-lifetime owner. Signal and activation callbacks retain or remove their
owners during shutdown; queued completions receive a bounded drain.

## Build and install

Requirements: C compiler, Meson, Ninja, pkg-config, GLib/GIO (including Unix
support), the reviewed WirePlumberAO 0.5.18 cohort with generic ndarray
SessionItem exact-port support, acknowledged link withdrawal (`withdraw()`),
and native event-hook support, PipeWireAO development libraries and SQLite
3.24 or newer. The package version check alone does not distinguish those
SessionItem extensions from unmodified upstream libwireplumber; build against
the reviewed source cohort. Export `PKG_CONFIG_PATH` for that cohort before
configuring.

```sh
meson setup native/build native --prefix=/absolute/isolated/prefix --libdir=lib \
  -Dwp_source_dir=/absolute/path/to/wireplumber
meson compile -C native/build
meson test -C native/build --print-errorlogs
meson install -C native/build
```

For a build without tests, use `-Dtests=false`; the upstream source checkout is
then unnecessary. Tests compile the upstream Lua runner in place and include
its private test-server headers through the explicit `wp_source_dir` option.
No upstream test tree is copied. Test servers are isolated from the user's
running PipeWire service. Runtime library discovery must include the selected
cohort's library directory (the deployment launcher sets `LD_LIBRARY_PATH`).

| Owner | Build/source path | Installed path below prefix |
| --- | --- | --- |
| Native application | `native/build/pipewireao-rtc` | `bin/pipewireao-rtc` |
| RTC plugins | `native/build/modules/*.so` | `lib/pipewireao-rtc/modules/*.so` |
| RTC Lua policy | `native/scripts/` | `share/pipewireao-rtc/scripts/` |

Deployment seals those assets under package `rtc/bin`, `rtc/modules` and
`rtc/scripts`. `WIREPLUMBER_MODULE_DIR` lists the RTC modules followed by generic
library modules. `WIREPLUMBER_DATA_DIR` lists the RTC data root followed by
generic library data. Both variables use colon-separated directories. If unset,
the host supplies the corresponding build-selected installed directories.
The generated policy component uses an absolute installed script path to avoid
the Lua loader's ordinary-client working-directory lookup.

## Provenance and validation scope

The relocated policy, plugins and tests originated in the WirePlumberAO
checkout at `0f64f9ef9d7f080a2668470f3904aa3d0ebf92af`, including the existing
2026-10-21 working changes to ndarray connections and event-hook policy.
Their MIT SPDX and attribution notices are retained; the upstream license is
included here. `main.c` is an RTC application host rather than a copy or wrapper
of the WirePlumber daemon entrypoint.

The focused tests cover native journal ordering/bounds/worker behavior, Lua
owner/acquisition/connections/journal policy, native event-hook lifecycle races,
and actual native-host configuration failure, clean termination and server
loss. An additional isolated two-process test loads production `ao/session.lua`
and both real control endpoints in the RTC host, holds scientific admission by
leaving its declared owners absent, then uses a separate native controller to
read public Props and complete native Status while Configuring. It verifies the
public profile, endpoint incarnation and actual host PID through production
`ao-owner`/`ao-control` helpers. It does not claim native public Start/Stop/Reset/
Quit coverage with scientific owners; lifecycle operations remain covered by
the separate production-policy event-hook tests. Host tests also exercise fixed profile/identity, ordinary-client mode,
initial Quit-marker clearing, ignored configuration fragments and an absolute
entrypoint with a hostile current-directory script. Policy tests distinguish a
successful Quit publication fence from failure. These are CPU functional checks;
they do not qualify GPUs, physical hardware, deadlines or production release.
