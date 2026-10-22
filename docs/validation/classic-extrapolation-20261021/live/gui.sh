#!/bin/sh
set -eu
set -a
. /run/user/1000/pipewireao-session-b16ca74284a4/current.env
set +a
export WAYLAND_DISPLAY=wayland-mIp9wbaNKd
export XDG_RUNTIME_DIR=/run/user/1000
export LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe
export CUDA_VISIBLE_DEVICES= ROCR_VISIBLE_DEVICES=
export JULIA_DEPOT_PATH=/home/dgamroth/.local/share/classic-review-20261020/depot
export JULIA_PKG_GC_AUTO=false JULIA_PKG_PRECOMPILE_AUTO=0
export PIPEWIREAO_CONFIG_DIR="$PIPEWIRE_RUNTIME_DIR/session"
export PIPEWIREAO_PREFIX=/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021
export PIPEWIREAO_SIMULATOR_ROOT=/home/dgamroth/.local/state/pipewireao/classic-cpu-extrapolation-live-20261022/rebuilds
export PIPEWIREAO_SIMULATOR_COMMAND='["julia","+1.13","--startup-file=no","--project=/home/dgamroth/workspaces/codex/pipewire/revolt-classic-rtc","-e","using PipeWireAORTC; PipeWireAORTC.SimulatorConfiguration.serve()"]'
exec /home/dgamroth/.local/opt/pipewireao-classic-journal-20261020/bin/pipewireao-gui-4a3d94e --view-config /home/dgamroth/.local/state/pipewireao/classic-cpu-extrapolation-live-20261022/operator-views.toml
