#!/bin/bash
set -euo pipefail
export PIPEWIREAO_PREFIX=/home/dgamroth/.local/opt/pipewireao-loop-controls-20261026
export LD_LIBRARY_PATH="$PIPEWIREAO_PREFIX/lib"
export PIPEWIREAO_SPA_PLUGIN_DIR="$PIPEWIREAO_PREFIX/lib/spa-ao-0.2"
export PIPEWIREAO_MODULE_DIR="$PIPEWIREAO_PREFIX/lib/pipewire-ao-0.3"
export JULIA_PKG_PRECOMPILE_AUTO=0 JULIA_PKG_GC_AUTO=false OPENBLAS_NUM_THREADS=1
exec "$@"
