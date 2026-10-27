#!/bin/sh
set -eu
export PIPEWIREAO_PREFIX=/home/dgamroth/.local/opt/pipewireao-loop-controls-20261026
export LD_LIBRARY_PATH="$PIPEWIREAO_PREFIX/lib"
export PIPEWIREAO_SPA_PLUGIN_DIR="$PIPEWIREAO_PREFIX/lib/spa-ao-0.2"
export PIPEWIREAO_MODULE_DIR="$PIPEWIREAO_PREFIX/lib/pipewire-ao-0.3"
export PIPEWIREAO_CONFIG_DIR="$PIPEWIREAO_PREFIX/share/pipewire-ao"
export JULIA_DEPOT_PATH=/home/dgamroth/.cache/pipewireao/operational-loops-20261026/registered-depot:/home/dgamroth/.julia
export JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_PKG_GC_AUTO=false JULIA_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1
exec "$@"
