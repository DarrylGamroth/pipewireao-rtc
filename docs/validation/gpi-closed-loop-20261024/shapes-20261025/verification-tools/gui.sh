#!/bin/sh
set -eu
set -a
. '/run/user/1000/pipewireao-session-4774985dfca6/current.env'
set +a
export XDG_DATA_HOME='/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/gui-state'
export WAYLAND_DISPLAY=wayland-sRK0etWWY9 XDG_RUNTIME_DIR=/run/user/1000
unset LIBGL_ALWAYS_SOFTWARE GALLIUM_DRIVER __EGL_VENDOR_LIBRARY_FILENAMES
export PIPEWIREAO_PREFIX='/home/dgamroth/.local/opt/pipewireao-classic-headless-20261021'
export LD_LIBRARY_PATH="$PIPEWIREAO_PREFIX/lib"
export PIPEWIREAO_CONFIG_DIR="$PIPEWIRE_RUNTIME_DIR/session"
export PIPEWIREAO_SIMULATOR_ROOT='/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/rebuilds'
export PIPEWIREAO_SIMULATOR_COMMAND='["/home/dgamroth/.julia/juliaup/julia-1.13.2+0.x64.linux.gnu/bin/julia","--startup-file=no","--project=/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/session/installed","-e","using PipeWireAORTC; PipeWireAORTC.SimulatorConfiguration.serve()"]'
exec taskset --cpu-list 12,13 '/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/bin/pipewireao-gui' --view-config '/home/dgamroth/.local/state/pipewireao/gpi2-shape-live-20261025/session/installed/gui/operator-views.yaml'
