# Installed AO runtime checks, 2026-10-08

## Delivered scope

PipeWireAO 1.7.0 and WirePlumberAO 0.5.18 are installed in the user-owned
`/opt/pipewireao` prefix. WirePlumberAO selects the actual AO pkg-config packages;
no desktop package-name aliases are needed. Executables have an installed-prefix
RUNPATH. The RTC exporter copies installed manager assets into its existing
sealed layout, and the manager loads its packaged libwp before installed AO
libraries. Calibration continues inheriting the base package's sealed manager.

WirePlumber source: `6557dcea` (six dependency/test-environment substitutions).
PipeWire source: `9cf200645`; the three new commits change tests only. Production
PipeWire source is unchanged from `691928291`. RTC baseline: `b24c52d`, with the
installed-prefix exporter and manager-library selection changes recorded here.
[Installation hashes](installation.json) identify the installed runtime files.

## Observed checks

| Check | Result |
| --- | --- |
| Julia deployment SDK | 2,663 assertions, 93 test sets; exit 0 |
| WirePlumber native/Lua suite | 57/57 pass |
| PipeWire suite after test corrections | 76/76 pass |
| Repeated FIFO tests | 20/20 pass |
| Repeated row-return replacement | 200/200 pass |
| Repeated row-return removal | 20/20 pass |
| Installed WirePlumber staging | 34 assertions: valid prefix, missing assets, ambiguous libraries, partial development inputs, symlink destination |
| Copper CPU FGN + CUDA AOS | Ready, stopped/running gain updates, stopped reconstructor request, reset/resume, correlated Quit and empty unit cleanup |
| Copper CPU JFG + CUDA AOS | Same lifecycle/control checks |
| Runtime loading | Packaged manager executable/libwp/both required modules; installed AO libpipewire in every selected owner; no developer build or desktop libpipewire |
| Existing GUI/HIL service | Remained active with MainPID 1632744 |

The selected packages retain 540 FGN and 539 JFG non-runtime artifact hashes.
Scientific graphs, calibrations and simulator inputs were reused rather than
regenerated. The model period is 2 ms and wall pacing is 10 Hz. These short
functional checks add no latency, cadence, numerical, allocation or physical-loop
qualification. HEART was not changed or newly qualified.

## Fail-before evidence and disposition

- `test-spa` expected `_SPA_META_LAST == 12`, contrary to the existing header's
  reserved retired metadata slot and value 13. Correcting the test passes the
  original assertion. No metadata transport was added.
- The initial Rust graph and polling failures did not recur in sequential
  reruns; their initial causes remain unknown. The final full suite passes.
- The FIFO client destroyed its source pool immediately after reporting the
  last output, racing the test's intended helper-first shutdown. The failure
  trace contained all eight callbacks and seven outputs before Broken pipe.
  A test-only completion/quit handshake retains those buffers until helper exit;
  the negotiated 16-buffer pool is recorded before teardown changes live counts.
- The row-return test could invoke its gated callback inline before the consumer
  thread entered its loop. The [captured backtrace](row-return-deadlock.txt)
  shows main waiting in the callback, the consumer waiting on the loop mutex,
  and no control thread yet. The test now probes actual loop-thread execution
  before invoking its gated publisher. An inline noop is insufficient.
- WirePlumber tests initially used desktop environment names, directing private
  server sockets to `/invalid`. AO environment names fix that setup. Remaining
  audio tests needed PipeWire's optional audiotestsrc plugin; enabling it yields
  all 57 passes without changing WirePlumber algorithms.
- The first runtime-map assertion used Julia's bulk `/proc/maps` read, which
  returned only 4,060 bytes versus 10,925 bytes read line by line for the existing
  service. The corrected probe reads lines. This was a validation harness error.

Original [PipeWire failures](pipewire-initial-tests.log) and
[WirePlumber setup failures](wireplumber-initial-tests.log) are retained.
[Independent review](REVIEW.md) confirmed the exporter/dependency changes and both test
handshake fixes. It did not qualify performance. The package replacement
validates inputs before removal; the directory replacement itself is not
interruption-atomic.

## Installation and reproducibility

[PW install manifest](pw-install.json) records 387 staged files and 116 preserved
external files. audiotestsrc was subsequently added. [WP install manifest](wp-install.json)
records 227 staged files and 504 preserved external files. Existing external
camera, FITS, HEART, ndarray, discard and scientific plugins were retained.
Files were replaced through temporary siblings and rename, preserving mapped
inodes; no existing service was restarted or desktop service enabled.

The [ad hoc atomic install script](atomic-install.py) is validation evidence,
not an operational dependency. The install is additive; it is not a transaction
across the whole prefix. Small rollback copies were retained during validation.
The [smoke driver](installed-smoke.jl) refreshes the SDK and seals installed
WirePlumber assets while asserting scientific hash preservation before launch.

```sh
meson setup builddir/pipewire /path/to/PipeWireAO \
  --prefix=/opt/pipewireao --libdir=lib/x86_64-linux-gnu --buildtype=release \
  -Dauto_features=disabled -Dspa-plugins=enabled -Dsupport=enabled \
  -Dtests=enabled -Daudiotestsrc=enabled -Dlibsystemd=enabled \
  -Dsystemd-user-service=disabled -Drlimits-install=false \
  -Dc_link_args=-Wl,-rpath,/opt/pipewireao/lib/x86_64-linux-gnu
meson compile -C builddir/pipewire -j 2
meson test -C builddir/pipewire --no-rebuild --num-processes 1
meson install -C builddir/pipewire --no-rebuild --destdir /tmp/pwao-stage

# After installing the staged AO core and headers:
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig \
  meson setup build /path/to/WirePlumberAO \
  --prefix=/opt/pipewireao --libdir=lib/x86_64-linux-gnu --buildtype=release \
  -Ddoc=disabled -Dintrospection=disabled -Delogind=disabled \
  -Dsystemd=disabled -Dtests=true \
  -Dc_link_args=-Wl,-rpath,/opt/pipewireao/lib/x86_64-linux-gnu
meson compile -C build -j 2
meson test -C build --no-rebuild --num-processes 1
meson install -C build --no-rebuild --destdir /tmp/wp-stage
```

Builds used CPUs 10/14; the final PipeWire suite and repeated tests used CPUs
2–15 with one Meson test process. No host scheduler, power or cgroup policy was
changed. Stock systemd units were disabled: the RTC renders private user units.

Logs: [SDK](sdk-tests.log), [WirePlumber](wireplumber-tests.log),
[FGN](fgn-smoke.log), [JFG](jfg-smoke.log). Loading and cleanup receipts are
`fgn-*` and `jfg-*` files in this directory.
