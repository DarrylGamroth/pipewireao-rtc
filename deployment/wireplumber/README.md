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
and the remaining Copper/AOS admission and ownership-transfer gates.
