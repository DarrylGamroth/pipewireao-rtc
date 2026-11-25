#!/usr/bin/env bash
# Provision the disposable Linux runner for the RTC owner-unit contract.
set -euo pipefail
uid=$(id -u)
# The managed owner unit requests these hard limits from its user manager.
dropin="/run/systemd/system/user@$uid.service.d"
sudo mkdir -p "$dropin"
printf '[Service]\nLimitRTPRIO=95\nLimitMEMLOCK=4G\n' |
  sudo tee "$dropin/rtc-test.conf" > /dev/null
sudo systemctl daemon-reload
sudo systemctl restart "user@$uid.service"
export XDG_RUNTIME_DIR="/run/user/$uid"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" >> "$GITHUB_ENV"
echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >> "$GITHUB_ENV"
