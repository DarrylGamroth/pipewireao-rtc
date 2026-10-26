#!/bin/sh
set -eu
Q=/home/dgamroth/.cache/pipewireao/quit-investigation-20261025
exec timeout --signal=TERM --kill-after=10s 600s /home/dgamroth/.cache/pipewireao/gpi2-registered-20261025/with-env.sh env TMPDIR="$Q" JULIA_LOAD_PATH="$Q/load-environment-patched:@:@v#.#:@stdlib" taskset -c 2,4 julia --startup-file=no --threads=2,0 --project="$Q/application-registered" "$Q/optical-cleanup-private/smoke-v2.jl"
