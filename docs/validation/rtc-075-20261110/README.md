# RTC 0.7.5 operator CLI verification

The checksum cleanup, Pkg app and public docstrings reached main by
fast-forward. The release tag points to
`c7a092ccdd11e33f84f93bacad753060bf5e2ea8`. The registry and the downloaded
package match tree `f4e240a210228d4a23c1c58ee4151ad3b9915281`.
[GitHub release](https://github.com/DarrylGamroth/pipewireao-rtc/releases/tag/v0.7.5)
· [Registry entry](https://github.com/DarrylGamroth/PackageRegistry/commit/2f281ec37435fc5374656e30d938a3f4ebcee2fd)

Julia 1.13.3 started with an empty depot and added General and
DarrylGamrothRegistry. General was at tree
`5ab0c99f7dcfb17deee3aee70fb9e7245209bb59`. Pkg installed the app by
registered name and version using
`Pkg.Apps.add(name="PipeWireAORTC", version="0.7.5")`.
The generated app Manifest had SHA-256
`cce5a9173df79d6581e1cd8a78f974ccb87bef6ea80e18893f7e5c94becc595d`.

All 23 environment checks passed. The app Manifest used registry sources and
the depot had no artifact override. The installed RTC, PipeWireAO 0.9.2,
PipeWireAO_jll 4.0.2+0 and PipeWireAOQueue_jll 0.1.0+0 source trees matched their
Manifest entries. The verifier read RTC's identity from the app Manifest
because the app's active project is RTC itself.

The generated `pipewireao-rtc-session` command returned `[]` for `sessions`
in an empty private runtime directory. An unknown command returned a nonzero
exit status. `-- control --session UUID -- status` preserved the inner
separator and reached session discovery, which reported the missing registry.

The published package's `test/runtime_install.jl` passed all 242 checks in
the same depot with the registered SDK artifact. It exported, installed and
relocated an application, rejected an altered session configuration and
loaded RTC through the application's registered Manifest after relocation.
These checks cover package and deployment software. Live owner admission and
timing have separate gates.

## Other entry points

- `CalibrationCLI.main` is a candidate for a Pkg app. It reads a plan and
  sends native commands to an existing acquisition owner. Scientific
  preparation runs in the instrument environment.
- `ConfigurationStoreCLI.main` has a one-shot mode that could be exposed for
  direct operator use. The management owner can continue to call the package
  interface for its existing service.
- `SessionInstall.main` is available through the session app's `install`
  subcommand. Session launch and configuration helpers run with the installed
  instrument environment.
