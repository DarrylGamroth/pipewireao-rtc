# Upstream WirePlumber package integration — 2026-10-21

The ordinary WirePlumber fork now tracks upstream runtime source, with a small
[PipeWireAO build recipe](../../../../wireplumber/packaging/pipewireao/README.md).
The pinned upstream commit is `bdc17eb2c419cbe41dbb248cf20cbe93370ee2f7`:
0.5.18 plus two upstream role-policy fixes. Those policy changes are upstream
work, not AO extensions. The default build changes only the two Meson dependency
names to select `libspa-ao-0.2` and `libpipewire-ao-0.3`.

The large POD-filter and Lua event-property fixes are independent optional patch
files with their regression tests. Their bytes match the previously preserved
patches. Neither is applied by default; no component-loader fix remains in the
recipe. Both patches apply independently and together to the pin. Their earlier
[regression evidence](../upstream-bindings-20261021/README.md#genuine-upstream-fixes-remain-separate)
retains its original scope; optional patched cohorts were not rebuilt here.

Site/device policy stays separate, using normal WirePlumber configuration.
The recipe installs stock upstream assets, disables service installation and
enables no policy or process. No custom AO device-policy profile currently
exists. The headless RTC continues to own application links and lifecycle.
Sealed RTC packages stage library assets and RTC assets separately; they contain
no device-policy configuration or WirePlumber daemon.

## Verification

| Check | Observed result | Evidence |
| --- | --- | --- |
| Default build/test/install | 57 upstream suites pass | [build manifest](build.json), [test records](generic.json) |
| Fresh RTC rebuild against new library | 10 native suites pass, zero skips | [test records](native.json) |
| CPU arrays / independent WirePlumber peer | 19 checks pass: delivery, exact RTC-owned links, withdrawal, unrelated-node preservation and child cleanup | [receipt](array/receipt.json) |
| Generated production SPA-JSON | Native Status Configuring; owned RTC exits 0 | [receipt](generated/receipt.json), [configuration](generated/rtc.conf) |
| Dependency and staging checks | Six package assertions pass; loader selects the new library and PipeWireAO, with no ordinary PipeWire or CUDA dependency | [receipt](receipt.json), [loader paths](dependencies.log) |
| Source and package review | Independent review and optional-patch checks | [review](../../reviews/20261021-upstream-package/REVIEW.md) |
| Updated ownership diagram | Mermaid CLI render succeeds | [render](owners.svg) |

The library install is
`~/.local/opt/wireplumber-pipewireao-upstream-20261021`; the fresh RTC install is
`~/.local/opt/pipewireao-rtc-upstream-package-20261021`. Build inputs, options,
patch hashes and tool versions are in the manifest. Tests use Julia 1.13.2 and
private CPU-only PipeWire instances. The native rebuild retains existing unused callback-parameter
warnings; no C or Julia implementation changed in this RTC increment. The
previous 2,409-assertion Julia suite is not rerun for these documentation and
dependency-packaging changes. Structured Meson records exclude environments.

Reproduce the build with the recipe's documented commands, then use the
[native build guide](../../../native/README.md) with the selected library first
in `PKG_CONFIG_PATH`. The integration commands are:

```sh
julia +1.13 --startup-file=no --project=. test/integration/session_items.jl \
  /absolute/new-wireplumber-prefix /absolute/new-rtc-prefix /absolute/fresh-array-evidence
julia +1.13 --startup-file=no --project=. \
  docs/validation/upstream-bindings-20261021/generated-configuration-probe.jl \
  "$PWD" /absolute/new-wireplumber-prefix /absolute/new-rtc-prefix \
  /absolute/fresh-config-evidence configuring
```

The generated probe leaves scientific owners absent. Its log retains the
previously documented publication-failure Fault during controller teardown.
One Configuring Status exchange is not full scientific Start/Stop/Reset/Quit
qualification. The independent daemon uses an empty device-policy profile;
coexistence does not qualify hardware device policy. No simulator, GPU, physical
device, sustained cadence, deadline or latency gate was run. Artifact management
remains paused. The live simulation stays inactive, MainPID zero; no live
workstation prefix or service was replaced.
