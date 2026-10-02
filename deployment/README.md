# Recorded-input RTC deployment

This package supervises a private PipeWireAO core, the Rust lifecycle owner,
and optional external scientific owners. It delegates scientific processing,
row scheduling and buffer ownership to FGN or JuliaFilterGraph. Current REVOLT
profiles use a non-actuating command discard sink. Physical device authority and
the AOS/HIL graph are subsequent work.

## Build and export

Use an installed PipeWireAO prefix with compatible FITS, ndarray and discard
plugins. Rank-two recorded frames require the FITS plugin's `api.fits.layout`
option; the profile selects row-major `[height, width]`. This changes the axis
declaration without copying or transposing pixels. The plugin's previous
column-major default is preserved.

```sh
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
  cargo build --release --features live

python3 deployment/export.py \
  --output /absolute/new-package \
  --profile classic --engine jfg --mode frame \
  --rate-hz 10 --readout-us 2000 \
  --algorithms-root /absolute/calculon-algorithms \
  --classic-calibration /absolute/prepared-classic-fixture \
  --jfg-root /absolute/JuliaFilterGraph.jl \
  --rtc-binary target/release/pipewireao-rtc
```

Supported selections are `classic|copper`, `fgn|jfg`, and `frame|row`.
FGN exports additionally require `--fgn-bundle /absolute/libcalculon_fgn_bundle.so`.
Copper requires `--copper-calibration /absolute/revolt-rtc/config` instead of
Classic's prepared fixture. The readout must be positive and shorter than the
frame period. These are source settings, not qualified physical-camera rates.

The exporter invokes maintained scientific generators at build time. Installed
packages contain their standard graphs, calibration files, native bundle or
Julia owner sources, resolved Julia environment, source provenance and SHA-256
artifact manifest. Runtime does not import benchmark generators or worktrees.
The Julia executable and its instantiated dependency depot remain prerequisites;
Julia 1.12 or later is required. The launcher selects the specified native
PipeWireAO prefix through a temporary JLL override.

Classic retains the 188-subaperture, 376-slope, 221-controller and 277-physical-
actuator path. Copper retains four 30×30 pupil arrays and the 253×3600
reconstructor, followed by the 277-actuator projection, flat, clipping and
feedback path. Origins and active flags are constructor data in native Classic;
its current startup file interface admits F32 parameters. Julia uses the same
prepared arrays through public parameter ports. No reconstructor padding or
simplified scientific substitute is introduced.

## Install and run

```sh
python3 deployment/deploy.py install \
  --package /absolute/new-package \
  --destination "$HOME/.config/pipewireao-rtc/revolt-classic-jfg-frame" \
  --pipewire-prefix /opt/pipewireao

# Supply the recorded source separately.
cp /absolute/classic-input.fits \
  "$HOME/.config/pipewireao-rtc/revolt-classic-jfg-frame/input.fits"
```

Installation refuses an existing destination. The installed launcher and its
service template are relocatable. The descriptor is standard SPA-JSON; JSON
emitted by the exporter is its strict subset. Artifact tampering fails preflight.

```sh
package="$HOME/.config/pipewireao-rtc/revolt-classic-jfg-frame"
"$package/bin/pipewireao-rtc-deploy" preflight \
  --deployment "$package/deployment.conf" --fits "$package/input.fits"
"$package/bin/pipewireao-rtc-deploy" run \
  --deployment "$package/deployment.conf" --fits "$package/input.fits" \
  --runtime "$XDG_RUNTIME_DIR/rtc-classic-jfg-frame"
```

The supplied host placement excludes CPUs 0 and 1. It assigns source 12, sink 8,
native processing 2, Julia processing 4, Julia monitors 10, and housekeeping 14.
Each process starts on its housekeeping CPU; libraries place their persistent
workers. Before ingress, the launcher checks every realized thread's effective
mask and scheduler, required worker counts and requested locked memory. The
inherited affinity must contain the complete deployment envelope; do not launch
it under `taskset -c 14` alone. These masks do not establish exclusive cores or
IRQ isolation.

The owner prepares synthetic data, requires terminal command and feedback
publication, resets state, connects inactive, and awaits session admission.
The source remains stopped through preparation and placement checks. Losing a
required process fails the deployment. Restart uses a fresh private core and
runtime directory; it does not reuse readiness markers from a previous launch.
SIGINT/SIGTERM stops the session, tears down the RTC, then releases external
owners and the core. If completed ingress revocation cannot be confirmed, the
source-owning private core is terminated before consumer quit markers.

## Systemd user service

Each exported profile contains a generated user unit with its own CPU envelope.
Install that unit under the instance-specific name to preserve differing layouts:

```sh
name=revolt-classic-jfg-frame
package="$HOME/.config/pipewireao-rtc/$name"
mkdir -p "$HOME/.config/systemd/user"
cp "$package/systemd/pipewireao-rtc@.service" \
  "$HOME/.config/systemd/user/pipewireao-rtc@$name.service"
systemctl --user daemon-reload
systemctl --user start "pipewireao-rtc@$name.service"
systemctl --user status "pipewireao-rtc@$name.service"
systemctl --user stop "pipewireao-rtc@$name.service"
```

The user service reports ready only after source admission. It uses the same
launcher and configuration as foreground execution. It does not start the
ordinary desktop PipeWire service, enable itself automatically, or modify host
policy. Automatic restart is disabled; operator restart prepares a fresh session.

The user manager must already inherit sufficient RT and memory-lock hard
limits. Per-unit limits cannot manufacture rights absent from the manager.
Default profiles request FIFO 83 and permit four GiB of locked memory, but do
not enable memory locking or CPU power QoS. To request those policies, author
compatible core/client settings and explicit `locked-bytes`/`cpu-latency-us`
contracts, then verify effective results. Access to `/dev/cpu_dma_latency` uses
the existing `rtc` group. Account membership does not update an already-running
shell or user manager's effective groups; preflight reports that distinction.
No launcher command changes C-states, IRQ affinity or host RT runtime allowance.

## Local control

```sh
"$package/bin/pipewireao-rtc-deploy" control \
  --runtime "$XDG_RUNTIME_DIR/rtc-classic-jfg-frame" -- status
```

For a user unit the runtime is `$XDG_RUNTIME_DIR/pipewireao-rtc-$name`.
Supported commands:

```text
status
groups
properties GRAPH
property-generation GRAPH NODE
parameter-generation GRAPH NODE
stop GROUP
start GROUP
session-stop
session-start
reset
properties-set GRAPH NODE:PROPERTY TYPE VALUE [NODE:PROPERTY TYPE VALUE ...]
parameter GRAPH PORT F32_LE ROWSxCOLUMNS SCHEMA /absolute/new-matrix.f32le
```

`reset` requires a stopped session. Group stop/start preserves graph state;
it does not reset it. A finite owned FITS source automatically returns the
session to Ready. A fresh deployment replays from the beginning; session resume
is not a promise to seek a file. Use `systemctl --user stop` or SIGTERM for
supervisor shutdown. The Rust `quit` command alone closes its owner and is
reported as a required-process exit by the supervisor.

Parameter files are little-endian row-major and must exactly match a declared
parameter port, schema and byte length. Replacement while an initial value is
still pending rejects without faulting the healthy session. Submission and
active adoption are separate: inspect requested and active generations. Scalar
transactions similarly validate declarations and types before lifecycle entry;
unknown observations remain unknown.

Runtime parameter routes are declared by passive links. The session's
`parameters` map optionally submits initial files on those routes. Maintained
profiles preload their calibrations through the scientific owner and leave this
map empty, avoiding another matrix adoption during the first detector sample.
The route remains available for subsequent live replacement. A progressive
parameter transaction can abandon the current in-flight publication unit;
processing resumes on the next complete detector sample. Submission of identical
matrix bytes does not promise a no-op. Count exact replay separately from update
adoption and inspect the generation transition before using the updated state.

The endpoint uses one request per connection, one prepared request until owner
acknowledgement, 16 KiB requests, 128 command fields, 512 MiB parameter payloads,
and 64 KiB replies. Replies carry request/session identity and lifecycle state.
Socket clients have total deadlines. A timeout or disconnect can leave a
mutation's outcome unknown; query fresh status/generations instead of retrying
it automatically. Existing effects may occupy the lifecycle owner for five
seconds. The seven-second server acknowledgement wait and client timeout do not
cancel accepted work. Bounded regular-file sizes do not bound kernel/FUSE I/O
stalls; the supervisor provides process termination fallback.

`state.json` records startup admission and placement evidence, then the final
stop/error state. It is not a continuously refreshed scientific health snapshot.
The Unix `status` command observes current state and discard counters. No
per-frame logging is added for deployment health.

## Extend to another RTC

Author a standard session and native graph or external-owner graph, calibrated
parameter files and a version-1 deployment descriptor. Keep scientific
algorithms in their owning packages. The descriptor specifies process argv,
private readiness/connect/quit markers, configuration templates, artifact
hashes and effective placement contracts. The lifecycle owner supports its
existing source/graph/sink factory allowlist and ordinary declared links;
it does not execute another graph scheduler.

The current launcher admits owned recorded FITS ingress. External live
simulator ingress needs its own readiness/release contract in the subsequent
AOS/HIL increment. Do not claim the older HIL integrator fixture implements the
matched Classic extrapolation, limiter and feedback graph.

## Focused qualification

```sh
python3 -m unittest discover -s deployment -p 'test_*.py'
python3 deployment/check_profile.py \
  --deployment "$package/deployment.conf" --fits "$package/input.fits" \
  --frames 7 --output /absolute/functional-result.json
python3 deployment/check_properties.py \
  --deployment "$package/deployment.conf" --fits "$package/input.fits" \
  --node closed-loop-correction --gain -0.3 --pole 0.99 \
  --output /absolute/control-result.json
```

The profile check holds the source stopped before admission, checks exact
command count, invalid-command rejection, reset, realized placement and clean
shutdown. Full-frame checks also exercise submission/adoption; row replay keeps
the prepared calibration fixed. The property checker uses a separate looping
fixture to exercise invalid requests, valid transactions, pending replacement,
group control and restart adoption. Select the control node appropriate to the
graph; the command above names Classic's node. These are functional checks,
not throughput or latency benchmarks. Julia's separate calibration oracle compares prepared/reset
execution with fresh execution for command and feedback. Deployment and
software checks do not qualify a physical closed loop or a worst-case deadline.
