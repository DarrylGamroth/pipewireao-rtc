#!/usr/bin/env bash
# Used by the main-branch science job. Each dependency has its own read-only key.
set -euo pipefail
umask 077
keydir=$(mktemp -d "${RUNNER_TEMP}/rtc-keys.XXXXXXXX")
trap 'rm -r -- "$keydir"' EXIT
export GIT_CONFIG_GLOBAL="$keydir/gitconfig"
export GIT_SSH_COMMAND="ssh -F $keydir/config"
export JULIA_PKG_USE_CLI_GIT=true
curl --fail --silent --show-error https://api.github.com/meta |
  jq -er '.ssh_keys[] | "github.com " + .' > "$keydir/known_hosts"

add_identity() {
  local repository=$1 variable=$2 alias=${1%.jl}
  printf '%s\n' "${!variable}" > "$keydir/$alias"
  unset "$variable"
  cat >> "$keydir/config" <<CONFIG
Host $alias
  HostName github.com
  User git
  IdentityFile $keydir/$alias
  IdentitiesOnly yes
  BatchMode yes
  HostKeyAlias github.com
  UserKnownHostsFile $keydir/known_hosts
  StrictHostKeyChecking yes
CONFIG
  local path="DarrylGamroth/$repository.git" prefix="url.ssh://git@$alias/DarrylGamroth/$repository.git.insteadOf"
  git config --global --add "$prefix" "git@github.com:$path"
  git config --global --add "$prefix" "https://github.com/$path"
}

add_identity AdaptiveOpticsCalibration.jl RTC_CALIBRATION_DEPLOY_KEY
add_identity AdaptiveOpticsSimPipeWireHIL.jl RTC_HIL_DEPLOY_KEY
add_identity JuliaFilterGraph.jl RTC_GRAPH_DEPLOY_KEY
julia --startup-file=no --project=test/science -e '
    using Pkg
    Pkg.Registry.add("General")
    Pkg.Registry.add(RegistrySpec(url="https://github.com/DarrylGamroth/PackageRegistry.git"))
    Pkg.instantiate()'
