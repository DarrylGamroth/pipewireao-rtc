# WirePlumber compatibility pilot

This development fixture proves generic WirePlumber discovery, native SPA
format/metadata parsing and explicit client-owned links on an isolated AO core.
It does not launch an RTC, authorize acquisition or replace the headless runtime.
Its endpoints are a finite FITS source and non-actuating discard sink.

WirePlumber upstream source is unchanged. The build helper creates private
pkg-config aliases forwarding `libpipewire-0.3` and `libspa-0.2` requests to the
installed AO dependencies. These aliases exist only in the supplied build root;
they are an experiment, not installed compatibility packages or a release recipe.
The live harness rejects a WirePlumber binary linked to stock PipeWire.
Use a fresh build root; repeat compilation directly with `meson compile -C BUILD_ROOT/build`.

```sh
bash scripts/build_wireplumber_pilot.sh \
  /path/to/wireplumber /tmp/wp-ao-pilot /opt/pipewireao

python3 scripts/qualify_wireplumber.py \
  --wireplumber-source /path/to/wireplumber \
  --wireplumber-build /tmp/wp-ao-pilot/build \
  --output /tmp/wp-ao-delivery
```

Repeat with a new output directory for `--termination kill`,
`--termination endpoint-loss` and `--stale-serial`. Each command owns a separate
temporary core/socket and only stops its own processes. Default CPU6 is used for
the entire fixture; `--cpu` must select an available CPU other than CPU0/1.
This placement is for a functional check, without an RT or timing claim.

The harness captures current node/port IDs and serials, then supplies them as
saved standard SPA-JSON component arguments. The Lua script never reconnects by
name. No desktop hardware monitors, audio adapters, fallback sinks, automatic
rerouting, `sm-objects` JSON command bus or systemd units are loaded.

The declared sample contract is U16_LE, shape `[4, 3]`, COLUMN_MAJOR, 100/1,
schema `org.pipewireao.test.wireplumber/1` and Header metadata. The fixture checks
the actual negotiated link format, 32 discarded buffers, 768 bytes, zero protocol
errors and the ordered payload digest. Its diagnostic source/sink set
`node.cache-params = false`, so reads of dynamic `Props` counters are fresh.
Native parameter caching can otherwise return an earlier counter snapshot.

Python is limited to this development qualification harness: process supervision,
fixture generation and receipt checks. PipeWire also uses Python/pytest for
integration tests (`test/bluezenv`); WirePlumber policy and its script tests use
Lua. This harness adds no operational Python dependency. Saved snapshots and
receipts use JSON; discovery, metadata enumeration and link creation use native
PipeWire/WirePlumber APIs. Operational calibration remains Julia.

See the [evidence](../../docs/validation/wireplumber-compatibility-20261006/README.md)
and [integration direction](../../docs/ECOSYSTEM_INTEGRATION.md) for current scope
and the remaining ownership-transfer gates.

## Copper HIL coexistence

The Julia development qualifier reuses an installed Copper CUDA AOS / CPU FGN
or CPU JFG package. It runs the existing SDK supervisor, keeps every link under
runtime ownership and attaches only a port/link observer. Fresh runtime/evidence
directories are required; the selected simulation has 256 retained frames, 512 total
exchanges and 100 Hz wall pacing. It checks held discovery, native stop/reset,
two completed runs, midrun pause/resume and optional WirePlumber SIGKILL.

```sh
taskset -c 2-15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 \
  JULIA_NUM_THREADS=1,0 julia --startup-file=no --compiled-modules=existing \
  --project=/path/to/installed-package/julia \
  deployment/qualify_wireplumber_hil.jl \
  /path/to/installed-package /tmp/fresh-hil-runtime /tmp/fresh-hil-evidence \
  /path/to/wireplumber /tmp/wp-ao-pilot/build
```

This simulation uses `/opt/pipewireao`, CPU6 for its coordinator/observer, and the
package's admitted placement for scientific owners. Select a host whose allowed
CPUs include that envelope. No systemd ownership or production policy transfer
is performed. `hil-observer.lua` checks negotiated Formats through existing
native SPA filtering, including deliberate incompatible contracts. The runtime
remains the scientific admission authority.

See the [coexistence evidence](../../docs/validation/wireplumber-hil-coexistence-20261006/README.md)
for exact allocation, numerical and ownership limits. Focused cold manifest checks
are in `deployment/test_qualify_wireplumber_hil.jl`.

## Optional user service

The companion installer supports installed Copper HIL packages with an AOS
`simulator` owner and optional `julia` graph owner. Other profiles/layouts are
rejected for this increment. It copies the qualified upstream WirePlumber
executable, libraries, modules and scripts, plus its Julia preparer and Lua
observer, into a fresh destination. Execution uses those copied resources and
the selected package's installed SDK, without repository/worktree paths.
This private AO build selection is not a WirePlumber release package.

```sh
julia --startup-file=no --project=/path/to/installed-package/julia \
  deployment/wireplumber/service.jl install \
  /path/to/installed-package /path/to/wireplumber /tmp/wp-ao-pilot/build \
  /path/to/new-companion-install /opt/pipewireao 6
```

Install the RTC's existing user unit first. Use the same instance name for its
optional observer, with a companion installed for that exact package:

```sh
ln -s /path/to/new-companion-install/pipewireao-wireplumber@.service \
  "$HOME/.config/systemd/user/pipewireao-wireplumber@copper-fgn.service"
systemctl --user daemon-reload
systemctl --user start pipewireao-wireplumber@copper-fgn.service
systemctl --user status pipewireao-wireplumber@copper-fgn.service
journalctl --user -u pipewireao-wireplumber@copper-fgn.service -b
systemctl --user stop pipewireao-wireplumber@copper-fgn.service
```

`BindsTo` also starts `pipewireao-rtc@copper-fgn.service` if needed. The RTC's
existing admission/release sequence owns that start. Its READY notification
follows source release, so observer discovery happens after admission. Stopping
or restarting the RTC propagates to WirePlumber; stopping, failing or restarting
WirePlumber has no reverse lifecycle effect. `Restart=no` prevents automatic
observer retry. Nothing is enabled at login by these commands.

Every observer start queries the active RTC unit's MainPID and exact native
supervisor incarnation, checks its selected package and admitted cohort, and
atomically writes fresh standard WirePlumber configuration in a private
RuntimeDirectory. No saved status file grants admission. The runtime retains
all links, scientific format admission and source controls. The preparer runs
only during ExecStartPre; systemd runs WirePlumber directly afterward.
`Type=simple` active state is not cohort readiness: the current incarnation's
`HIL_COHORT_READY` journal marker indicates completed discovery. A lost cohort
is reported with `HIL_COHORT_LOST`; it is not automatically reconnected by name.

See [service design and coverage](SERVICE_DESIGN.md) and the
[user-service qualification](../../docs/validation/wireplumber-user-service-20261007/README.md).
Cold service checks are in
`test_service.jl`; `deployment/qualify_wireplumber_service.jl` uses fresh private
user units and requires an independently qualified baseline receipt. It verifies
observer lifecycle, native reset, an actual RTC restart transaction and unexpected
RTC cohort exit. It does not stop unrelated services or promote timing claims.

## Required connection loss

The policy now compares negotiated Formats with the configured schema, shape,
element type, layout and data rate, rather than treating the observed Format as
its declaration. It watches exact port/link and owner-client IDs/serials,
passive policy and owner PIDs. Loss is latched without name-based repair.
The RTC independently monitors required links and external endpoint removal;
its existing failure handling retains admission and cleanup authority.

The development loss qualifier selects installed Copper CPU FGN/JFG packages
with CUDA AOS. It checks healthy observation and acquisition before removing a
required input link or terminating its owned simulator. Use fresh output paths
for each case, then a separate coexistence run to establish fresh readmission:

```sh
taskset -c 2-15 env JULIA_PKG_OFFLINE=true OPENBLAS_NUM_THREADS=1 \
  JULIA_NUM_THREADS=1,0 julia --startup-file=no --compiled-modules=existing \
  --project=/path/to/installed-package/julia \
  deployment/qualify_wireplumber_loss.jl \
  /path/to/installed-package /tmp/fresh-loss-runtime /tmp/fresh-loss-evidence \
  /path/to/wireplumber /tmp/wp-ao-pilot/build required-link
```

Select `simulator-owner` as the last argument for owned simulator termination.
That development test uses Python's Linux pidfd interface to bind the signal
to the independently checked process; production launch/control remains Julia
and Rust. Required-link injection uses the public native CLI after checking
the exact link snapshot; that numeric destroy call is not an atomic serial-aware
operation. The isolated topology and retained receipt define its scope.

Success requires a new policy loss marker, failed deployment with revoked
postmortem admission, and observed absence of every owned process group and
private runtime. This proves eventual ingress revocation and bounded cleanup,
not graceful shutdown or a measured revocation latency. Actual faults may
terminate an in-flight exchange. See [the policy design](../../docs/WIREPLUMBER_CONNECTION_POLICY.md)
and [review/evidence](../../docs/validation/wireplumber-connection-policy-20261007/README.md).
