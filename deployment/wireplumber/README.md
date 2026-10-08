# WirePlumber development probes

Production sessions use the installed WirePlumberAO Lua policy and native
modules. See the [session design](../../docs/WIREPLUMBER_SESSION_DESIGN.md),
[installed runtime](../../docs/INSTALLED_RUNTIME.md) and
[session quickstart](../../README.md#launch-a-sealed-session-package).
The optional observer/coordinator architecture is retired.

## Retained development code

- `hil-observer.lua` and `test_observer.lua`: isolated observer callback checks.
- `realization.lua` and `test_realization.lua`: isolated connection realization
  and withdrawal checks.
- `test_realization_lifetime.jl` and `test_realization_links.jl`: opt-in native
  interface probes using a private core and explicit development build paths.
- `ndarray-pilot.lua`: policy source associated with the recorded compatibility
  experiment; its Python qualification launcher has been removed.

These probes have their own limited scopes. They do not launch a production
session or establish timing, scientific admission or every deployment profile.
The previous test for `session.jl` was removed with its retired implementation.

The [compatibility](../../docs/validation/wireplumber-compatibility-20261006/README.md),
[coexistence](../../docs/validation/wireplumber-hil-coexistence-20261006/README.md)
and [realization](../../docs/validation/wireplumber-realization-20261007/README.md)
receipts retain the original experiments and results. Their
[original tools](https://github.com/DarrylGamroth/pipewireao-rtc/tree/6b893b7e98e474580f53ff913751963b62f8db2a/deployment/wireplumber)
and [Python launchers](https://github.com/DarrylGamroth/pipewireao-rtc/tree/6b893b7e98e474580f53ff913751963b62f8db2a/scripts)
are available in Git history.
