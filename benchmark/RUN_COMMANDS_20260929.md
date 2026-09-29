# Latest/hold host run commands, 2026-09-29

Run from the `pipewireao-rtc-latest-hold-characterization` worktree. These
commands describe the three baseline runs summarized in
[`LATEST_HOLD_RESULTS_20260929.md`](LATEST_HOLD_RESULTS_20260929.md). Each
fixture compiles `tests/fixtures/latest_hold_slow_source.c` with
`LATEST_HOLD_BENCH_SAMPLES=2500` before starting its private core. The output
directory must not exist before each invocation.

```bash
for run in latest-hold-char-final-config3 latest-hold-char-final-config4 latest-hold-char-final-config5; do
  output="$HOME/.cache/pipewireao-rtc/$run"
  mkdir -p "$output"
  chrt -f 70 env \
    PKG_CONFIG_PATH="$HOME/workspaces/codex/pipewire/pipewire/build/meson-uninstalled" \
    LD_LIBRARY_PATH="$HOME/workspaces/codex/pipewire/pipewire/build/src/pipewire" \
    PIPEWIREAO_RTC_LIVE_SCOPE=latest-hold \
    PIPEWIREAO_RTC_LATEST_HOLD_TIMING_DIR="$output/data" \
    PIPEWIREAO_RTC_FGN_BUNDLE="$HOME/workspaces/codex/pipewire/calculon-algorithms-copper-fullframe/target/release/libcalculon_fgn_bundle.so" \
    cargo test --features live --test live_private_core -- --ignored --nocapture \
    > "$output/test.log" 2>&1
done
```

The stopped-state endpoint-pool replacement used the same command with
`run=latest-hold-char-pool2` and
`PIPEWIREAO_RTC_LATEST_HOLD_POOL_REPLACEMENT=1` added to `env`. The
ordinary-scheduling failure used `run=latest-hold-char-cfs-final` without
`chrt -f 70`. Its partial CSV has no valid latency distribution. The earlier
pool replacement failure is retained as `latest-hold-char-pool1/test.log`.

The JSON summary was generated with:

```bash
python3 benchmark/report_latest_hold.py \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config3/data/native-timing.csv" \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config3/data/julia-timing.csv" \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config4/data/native-timing.csv" \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config4/data/julia-timing.csv" \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config5/data/native-timing.csv" \
  "$HOME/.cache/pipewireao-rtc/latest-hold-char-final-config5/data/julia-timing.csv" \
  --output benchmark/data/latest_hold_20260929.json
```

The allocation pass wrapped the private core with `heaptrack --raw`; the CPU
pass attached `perf record` to the private core during the Julia phase.
Their exact shell invocations were not retained, so the profile artifacts
support the observations stated in the result report but are not a fully
reproducible command record.
