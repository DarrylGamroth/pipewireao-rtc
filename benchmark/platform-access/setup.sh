#!/bin/sh
# Install group permissions; no CPU power, IRQ, scheduler or perf policy changes.
set -eu
if [ "$(id -u)" -ne 0 ]; then
    echo 'Run with sudo; the setup requires root.' >&2
    exit 1
fi
rtc_user=${1:-${SUDO_USER:-}}
[ -n "$rtc_user" ] && [ "$rtc_user" != root ] || {
    echo 'Specify the non-root benchmark user.' >&2
    exit 1
}
getent passwd "$rtc_user" >/dev/null
source_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Refuse to replace an independently maintained file.
for pair in '90-rtc-latency.rules /etc/udev/rules.d/90-rtc-latency.rules' 'rtc-trace-access /usr/local/libexec/rtc-trace-access' 'rtc-trace-access.service /etc/systemd/system/rtc-trace-access.service'; do
    set -- $pair
    if [ -e "$2" ] && ! cmp -s "$source_directory/$1" "$2"; then
        echo "Existing different file preserved: $2" >&2
        exit 1
    fi
done
getent group rtc >/dev/null || groupadd --system rtc
usermod --append --groups rtc "$rtc_user"
mkdir -p /usr/local/libexec
install -o root -g root -m 0644 "$source_directory/90-rtc-latency.rules" /etc/udev/rules.d/90-rtc-latency.rules
install -o root -g root -m 0755 "$source_directory/rtc-trace-access" /usr/local/libexec/rtc-trace-access
install -o root -g root -m 0644 "$source_directory/rtc-trace-access.service" /etc/systemd/system/rtc-trace-access.service
udevadm control --reload-rules
udevadm trigger --action=change --subsystem-match=misc --sysname-match=cpu_dma_latency
udevadm settle
systemctl daemon-reload
systemctl enable --now rtc-trace-access.service
printf 'Added %s to rtc. Use sg rtc for this session, or log in again.\n' "$rtc_user"
