#!/bin/bash
set -eu
rtc_test_root=/home/dgamroth/workspaces/codex/worktrees/classic-shutdown-20261021
rtc_test_prefix="$rtc_test_root/prefix-fixed"
rtc_test_build="$rtc_test_root/rtc-fixed-build"
rtc_test_source="${RTC_TEST_SOURCE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)/native}"
env WIREPLUMBER_DEBUG=2 LD_LIBRARY_PATH="$rtc_test_prefix/lib" \
  XDG_RUNTIME_DIR=/invalid PIPEWIREAO_RUNTIME_DIR=/tmp \
  XDG_CONFIG_HOME="$rtc_test_build/tests/.config" XDG_STATE_HOME="$rtc_test_build/tests/.state" \
  G_TEST_SRCDIR="$rtc_test_root/wp-asan-source/tests/wplua" G_TEST_BUILDDIR="$rtc_test_build/tests" \
  WIREPLUMBER_MODULE_DIR="$rtc_test_build/modules:$rtc_test_prefix/lib/wireplumber-0.5" \
  WIREPLUMBER_DATA_DIR="${RTC_TEST_OVERRIDE:+$RTC_TEST_OVERRIDE:}$rtc_test_source/tests:$rtc_test_source:$rtc_test_prefix/share/wireplumber" \
  PIPEWIREAO_SPA_PLUGIN_DIR="$rtc_test_prefix/lib/spa-ao-0.2" \
  PIPEWIREAO_MODULE_DIR="$rtc_test_prefix/lib/pipewire-ao-0.3" \
  PIPEWIREAO_CONFIG_DIR="$rtc_test_prefix/share/pipewire-ao" \
  "$rtc_test_build/tests/script-tester" lua-api-tests "${1:?test script required}"
