#!/usr/bin/env bash
# Apply the one fix Ubuntu's live-build 3.0~a57 needs to rebuild a chroot twice.
#
# lb_chroot_dpkg runs `ln -s /bin/true chroot/usr/sbin/flash-kernel`; on a second run
# the link already exists and the build dies with "ln: Already exists". Using -sf makes
# the stage idempotent. Idempotent itself; needs sudo; touches only that line.
set -euo pipefail

F=/usr/lib/live/build/lb_chroot_dpkg
OLD='ln -s /bin/true chroot/usr/sbin/flash-kernel'
NEW='ln -sf /bin/true chroot/usr/sbin/flash-kernel'

if grep -qF "$NEW" "$F"; then
    echo "live-build already patched ($F)"
elif grep -qF "$OLD" "$F"; then
    sudo sed -i "s|$OLD|$NEW|" "$F"
    echo "patched $F"
else
    echo "unexpected content in $F; not patching" >&2
    exit 1
fi
