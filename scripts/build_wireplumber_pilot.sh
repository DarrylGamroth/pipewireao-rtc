#!/usr/bin/env bash
# Development compatibility build; does not install or change system libraries.
set -euo pipefail

if [[ $# != 2 && $# != 3 ]]; then
    echo "Usage: $0 WIREPLUMBER_SOURCE BUILD_ROOT [PIPEWIREAO_PREFIX]" >&2
    exit 2
fi
wp_source=$(realpath "$1")
build_root=$(realpath -m "$2")
ao_prefix=$(realpath "${3:-/opt/pipewireao}")
if [[ -e $build_root/build ]]; then
    echo "Use a fresh BUILD_ROOT; Meson caches source and dependency selection." >&2
    exit 2
fi
mkdir -p "$build_root/pkgconfig"
export PKG_CONFIG_PATH="$ao_prefix/lib/x86_64-linux-gnu/pkgconfig:$ao_prefix/lib/pkgconfig:$ao_prefix/lib64/pkgconfig:$ao_prefix/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

# Upstream asks for stock dependency names. These private aliases resolve those
# requests to AO headers/libraries, without replacing any installed .pc files.
for dependency in libpipewire libspa; do
    if [[ $dependency == libpipewire ]]; then
        api=0.3
    else
        api=0.2
    fi
    actual="$dependency-ao-$api"
    version=$(pkg-config --modversion "$actual")
    cat > "$build_root/pkgconfig/$dependency-$api.pc" <<EOF
Name: $dependency compatibility alias for WirePlumber pilot
Description: Private build dependency forwarding to $actual
Version: $version
Requires: $actual
EOF
done
export PKG_CONFIG_PATH="$build_root/pkgconfig:$PKG_CONFIG_PATH"
meson setup "$build_root/build" "$wp_source" \
    --prefix="$build_root/install" \
    -Dtests=false -Ddoc=disabled -Dintrospection=disabled \
    -Dsystemd=disabled -Delogind=disabled
meson compile -C "$build_root/build" -j 2
