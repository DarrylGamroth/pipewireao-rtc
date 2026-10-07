Required monitor evidence, 2026-10-07
Repository baseline: e605831d21e7ba362b600801d9e39a0d2d50ea03
Worktree: /tmp/rtc-wireplumber-policy-20261007
Branch: feat/wireplumber-connection-policy-20261007
Scope: RTC-DEV-003/004/021, AAR-01/02; monitor correction only.

Observed before: required-monitor private core deleted required link 28 in READY;
monitor returned READY with no diagnostic (live-before.log). The code paths
were inspected before changes: registry removal erased only the current global;
external node/port contracts used only reusable IDs and identity attributes.

Unit before: terminal-link update helper was extracted with baseline assignment
behavior; absent removal latching was represented by a no-op observation helper.
The two expected invariants failed before remediation (unit-before.log). These
are unit invariants, not a live reproduction of same-ID allocator reuse.

After: terminal Error/Unlinked remains latched; public registry/proxy removal
latches invalidate captured incarnations; every monitor checks bound link
registry presence plus Active/Paused state, and external node/port removal.
The existing dispatcher receives errors and drives FAULT; cleanup ownership
and non-lingering link proxy release are retained.

Observed after:
- unit invariants pass (unit-after.log).
- required-monitor: READY and RUNNING link loss enter FAULT; normal Stop
  produces READY with usable Paused links; restart works; unload removes owned
  objects and leaves unrelated fixture untouched (live-after.log).
- required-external-replacement: replacement before next monitor poll faults
  READY and RUNNING; cleanup leaves replacement and unrelated fixture alive
  (external-after.log). Global IDs differed: 20 -> 23 and 17 -> 22, so exact
  same-ID reuse is established by unit removal semantics, not this live test.
- cargo test --features live (rust-tests.log).
- cargo clippy --features live --all-targets -- -D warnings (clippy.log).
- cargo fmt --all -- --check; git diff --check.

All cargo invocations use:
PKG_CONFIG_PATH=/opt/pipewireao/lib/x86_64-linux-gnu/pkgconfig
CARGO_TARGET_DIR=/tmp/rtc-maintenance-target-20261006
Live tests additionally use:
PIPEWIREAO_RTC_LIVE_SCOPE=required-monitor (or required-external-replacement)
PIPEWIREAO_RTC_PIPEWIRE_BUILD=/home/dgamroth/workspaces/codex/pipewire/pipewire/build
PIPEWIREAO_SPA_PLUGINS_BUILD=/home/dgamroth/workspaces/codex/pipewire/pipewireao-spa-plugins-core/build
PIPEWIREAO_RTC_FGN_BUNDLE=/tmp/rtc-graph-updates-fgn-baseline-20261006/lib/libcalculon_fgn_bundle.so
cargo test --features live --test live_private_core -- --ignored --nocapture

Limitations: software/private-core functional evidence. No hardware, timing,
resource qualification or physical fail-safe claim. Start has its existing
link-active gate; no independent external-incarnation pre-start gate added.
Existing dependency future-compatibility warning: proc-macro-error2 v2.0.1.
No commits created; parent owns final integration and documentation.

Final src/live.rs SHA-256: f956a0e0c976409c45340a1bd5aa56755c0af6c89cbec299c44546aabba7caa3

Parent integration: the monitor correction was subsequently committed as 0bcdf24.
Retained log copies remove trailing whitespace/final blank lines; originals
remain in /tmp/rtc-wp-required-monitor-20261007.
