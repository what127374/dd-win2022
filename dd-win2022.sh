#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Linux -> Windows DD launcher. Reinstallation engine: bin456789/reinstall.
# Run from the installed Linux system, NOT from the Debian installer shell.
set -Eeuo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export LC_ALL=C

ENGINE_COMMIT=a2b7d7ddd73a3265b5321f3cbfd0e3c3ceb9cdc2
ENGINE_SHA256=ad01271d5b46fd73306172f569cd8f1ed88c8d2b4c43053673f2dc8925fc80c8
TRANS_SHA256=1d73eb11746c7656dfd70113bda67ff22b4637255ecaa3452773b88f8801fc69
IMAGE='https://yumwhat1.dpdns.org/Win_Server2022_64_Administrator_nat.ee.gz'
EXPECTED_IP=65.75.201.189
MTU=1400
RDP_PORT=3389
CHECK_ONLY=0
REBOOT=0
STATE_DIR=/root/dd-win2022
ROLLBACK=0

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: bash dd-win2022.sh [--check] [--reboot]
       bash dd-win2022.sh --cancel
Options:
  --check             Read-only checks; do not change routes, boot or disk.
  --reboot            Reboot after preparation and initrd verification succeed.
  --cancel            Cancel prepared reinstall BEFORE reboot.
  --image HTTPS_URL   Override the default gzip-compressed Windows raw image.
  --expected-ip IP    Guard against running on the wrong server.
  --mtu NUMBER        Network MTU (default: 1400).
  --rdp-port PORT     Windows RDP port (default: 3389).
  --help              Show help.
Default: prepare only. A separate reboot starts DD and erases the OS disk.
Windows credentials come from the image, NOT the temporary SSH password.
HELP
}
need_value() { [[ $# -ge 2 && -n $2 ]] || fail "Missing value for $1"; }
while (($#)); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) CHECK_ONLY=1; shift ;;
        --reboot) REBOOT=1; shift ;;
        --image) need_value "$@"; IMAGE=$2; shift 2 ;;
        --expected-ip) need_value "$@"; EXPECTED_IP=$2; shift 2 ;;
        --mtu) need_value "$@"; MTU=$2; shift 2 ;;
        --rdp-port) need_value "$@"; RDP_PORT=$2; shift 2 ;;
        --cancel)
            [[ $# == 1 ]] || fail 'Run --cancel by itself.'
            [[ $EUID == 0 ]] || fail 'Run as root.'
            [[ -f $STATE_DIR/reinstall.sh ]] || fail 'No prepared engine found.'
            bash "$STATE_DIR/reinstall.sh" reset
            printf 'Prepared reinstall cancelled.\n'
            exit 0 ;;
        *) fail "Unknown option: $1" ;;
    esac
done
[[ $EUID == 0 ]] || fail 'Run as root.'
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail 'Requires x86_64 Linux.'
[[ $IMAGE == https://* && $IMAGE != *[$'\r\n\t ']* ]] || fail 'Image must be an HTTPS URL without whitespace.'
[[ $MTU =~ ^[0-9]{3,4}$ ]] && ((10#$MTU >= 1280 && 10#$MTU <= 9000)) || fail 'MTU must be 1280..9000.'
[[ $RDP_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$RDP_PORT >= 1 && 10#$RDP_PORT <= 65535)) || fail 'RDP port must be 1..65535.'
MTU=$((10#$MTU)); RDP_PORT=$((10#$RDP_PORT))
for cmd in ip awk findmnt lsblk curl sha256sum od sed gzip cpio mktemp wc tr find sort; do
    command -v "$cmd" >/dev/null || fail "Missing $cmd. Ubuntu/Debian: apt-get update && apt-get install -y curl ca-certificates iproute2 util-linux cpio gzip gawk"
done
case "$(findmnt -n -o FSTYPE /)" in
    tmpfs|rootfs|overlay|squashfs) fail 'Boot the installed Linux OS first; installer/rescue RAM filesystems are not supported.' ;;
esac
[[ ! -d /var/lib/cdebconf && ! -e /etc/debian-installer_version ]] || fail 'This is the Debian installer. Boot/reinstall Linux first.'
[[ ! -e /reinstall-vmlinuz && ! -e /reinstall-initrd ]] || fail 'An earlier reinstall is already staged. Cancel it with its original script first.'

ROUTE=$(ip -4 route get 1.1.1.1) || fail 'No working IPv4 route.'
DEV=$(awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' <<<"$ROUTE")
CURRENT_IP=$(awk '{for(i=1;i<NF;i++)if($i=="src"){print $(i+1);exit}}' <<<"$ROUTE")
GATEWAY=$(awk '{for(i=1;i<NF;i++)if($i=="via"){print $(i+1);exit}}' <<<"$ROUTE")
[[ -n $DEV && -n $CURRENT_IP && -n $GATEWAY ]] || fail 'Cannot detect interface, IPv4 address or gateway.'
[[ $DEV =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'Unsupported interface name.'
[[ $CURRENT_IP == "$EXPECTED_IP" ]] || fail "Wrong server: detected $CURRENT_IP, expected $EXPECTED_IP. Use --expected-ip only for an intentional different target."
CIDR=$(ip -o -4 addr show dev "$DEV" | awk -v ip="$CURRENT_IP" '$3=="inet" {split($4,a,"/");if(a[1]==ip){print $4;exit}}')
[[ -n $CIDR ]] || fail 'Cannot determine the current IPv4 prefix.'
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_DISKS=$(lsblk -s -r -n -p -o NAME,TYPE "$ROOT_SOURCE" | awk '$2=="disk"{print $1}' | sort -u) || fail 'Cannot resolve OS disk.'
[[ $(wc -w <<<"$ROOT_DISKS") == 1 ]] || fail 'Expected exactly one underlying OS disk; RAID/LVM spanning multiple disks requires manual review.'
ROOT_DISK=$ROOT_DISKS
DISK_BYTES=$(lsblk -b -d -n -o SIZE "$ROOT_DISK")
((DISK_BYTES >= 32*1024*1024*1024)) || fail 'OS disk is smaller than 32 GiB; confirm the image requirements manually.'
printf '\nOS disk: %s (%s bytes)\nInterface: %s\nIPv4: %s\nGateway: %s (onlink supported)\nMTU: %s\nImage: %s\nRDP port: %s\n' \
    "$ROOT_DISK" "$DISK_BYTES" "$DEV" "$CIDR" "$GATEWAY" "$MTU" "$IMAGE" "$RDP_PORT"

SCRATCH=$(mktemp -d /tmp/dd-win2022.XXXXXXXX)
cleanup() {
    local code=$?
    trap - EXIT
    if ((code != 0 && ROLLBACK == 1)); then
        printf '\nPreparation failed; cancelling staged boot entry...\n' >&2
        if bash "$STATE_DIR/reinstall.sh" reset; then
            printf 'Cancellation succeeded. Do not reboot to install.\n' >&2
        else
            printf 'CANCELLATION FAILED. Do not reboot; repair boot configuration first.\n' >&2
        fi
    fi
    rm -f "$SCRATCH"/*
    rmdir "$SCRATCH" 2>/dev/null || true
    exit "$code"
}
trap cleanup EXIT
BASE="https://raw.githubusercontent.com/bin456789/reinstall/$ENGINE_COMMIT"
curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 120 --retry 2 "$BASE/reinstall.sh" -o "$SCRATCH/reinstall.sh"
printf '%s  %s\n' "$ENGINE_SHA256" "$SCRATCH/reinstall.sh" | sha256sum -c -
bash -n "$SCRATCH/reinstall.sh"
# Download only a bounded prefix. Reject error pages and non-gzip images.
curl --fail --show-error --silent --location --proto '=https' --proto-redir '=https' \
    --connect-timeout 15 --max-time 45 --retry 1 --range 0-1023 --max-filesize 2097152 \
    "$IMAGE" -o "$SCRATCH/image-prefix"
[[ $(od -An -N2 -tx1 "$SCRATCH/image-prefix" | tr -d ' \n') == 1f8b ]] || fail 'Image probe is not gzip. Check the image URL or download restrictions.'
printf '\nEngine hash and gzip image probe passed. Full image integrity/bootability is not proven by this check.\n'
if ((CHECK_ONLY)); then
    printf 'CHECK ONLY: network, boot configuration and disks were not modified.\n'
    exit 0
fi

[[ -r /dev/tty && -w /dev/tty ]] || fail 'Interactive terminal required. Download to a file, then run with bash.'
printf '\nWARNING: after reboot, DD will ERASE ALL PARTITIONS ON %s.\n' "$ROOT_DISK" >/dev/tty
printf 'Windows login/password are determined by the image. Temporary SSH password does not change them.\n' >/dev/tty
printf 'Type exactly ERASE %s to prepare: ' "$CURRENT_IP" >/dev/tty
IFS= read -r ANSWER </dev/tty
[[ $ANSWER == "ERASE $CURRENT_IP" ]] || fail 'Cancelled.'
printf 'Temporary installation SSH password (blank = random; NOT Windows password): ' >/dev/tty
IFS= read -rs TEMP_PASSWORD </dev/tty
printf '\n' >/dev/tty
if [[ -z $TEMP_PASSWORD ]]; then
    TEMP_PASSWORD=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
fi
[[ ${#TEMP_PASSWORD} -ge 12 ]] || fail 'Temporary password must contain at least 12 characters.'
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"
cp "$SCRATCH/reinstall.sh" "$STATE_DIR/reinstall.sh"
# Freeze supporting script downloads to the same reviewed commit.
sed -i \
    -e "s|^confhome=.*|confhome=$BASE|" \
    -e "s|^confhome_cn=.*|confhome_cn=$BASE|" "$STATE_DIR/reinstall.sh"
{
    ip -4 addr show dev "$DEV"
    ip -4 route show
    ip -6 addr show dev "$DEV"
    ip -6 route show
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
} >"$STATE_DIR/network-before.txt"
# A host route makes an out-of-subnet gateway reachable without widening /26.
ip -4 route replace "$GATEWAY/32" dev "$DEV" scope link
ip -4 route replace default via "$GATEWAY" dev "$DEV" onlink src "$CURRENT_IP"
ip link set dev "$DEV" mtu "$MTU"
ROLLBACK=1
bash "$STATE_DIR/reinstall.sh" dd --img "$IMAGE" --username root \
    --password "$TEMP_PASSWORD" --rdp-port "$RDP_PORT"
unset TEMP_PASSWORD

# Persist MTU in the generated Windows network setup script as well as Live OS.
INITRD_DIR=/reinstall-tmp/initrd
[[ -f $INITRD_DIR/trans.sh && -f /reinstall-initrd ]] || fail 'Unexpected engine layout; refusing to reboot.'
printf '%s  %s\n' "$TRANS_SHA256" "$INITRD_DIR/trans.sh" | sha256sum -c -
cp "$INITRD_DIR/trans.sh" "$STATE_DIR/trans.original.sh"
cat >"$SCRATCH/mtu-patch" <<PATCH
    # dd-win2022: preserve /26 without relying on an in-subnet default gateway.
    # Scoped to the public interface; do not change other NICs.
    if [ "\$ethx" = "$DEV" ]; then
        sed -i '/^:del/i if defined id netsh interface ipv4 set address name=%id% source=static address=$CIDR gateway=none store=persistent\\nif defined id netsh interface ipv4 add route prefix=$GATEWAY/32 interface=%id% nexthop=0.0.0.0 store=persistent\\nif defined id netsh interface ipv4 add route prefix=0.0.0.0/0 interface=%id% nexthop=$GATEWAY store=persistent\\nif defined id netsh interface ipv4 set subinterface %id% mtu=$MTU store=persistent\\nif defined id netsh interface ipv6 set subinterface %id% mtu=$MTU store=persistent' "\$target"
    fi
PATCH
awk -v patch="$SCRATCH/mtu-patch" '
    /^create_win_set_netconf_script\(\)/ { inside=1 }
    inside && /^    unix2dos \$target$/ {
        while ((getline p < patch)>0) print p
        close(patch); hits++
    }
    { print }
    inside && /^}$/ { inside=0 }
    END { if(hits!=1) exit 23 }
' "$INITRD_DIR/trans.sh" >"$SCRATCH/trans.patched.sh"
bash -n "$SCRATCH/trans.patched.sh"
cp "$SCRATCH/trans.patched.sh" "$INITRD_DIR/trans.sh"
# Apply MTU before the Live OS downloads images and drivers.
sed -i "/^mount \/ -o remount,size=100%$/a ip link set dev $DEV mtu $MTU" "$INITRD_DIR/trans.sh"
# Match the boot initrd's local.d copy if the engine supplied one.
if [[ -f $INITRD_DIR/etc/local.d/trans.start ]]; then
    cp "$INITRD_DIR/trans.sh" "$INITRD_DIR/etc/local.d/trans.start"
fi
(
    cd "$INITRD_DIR"
    find . -print0 | cpio --null --quiet -o -H newc -R 0:0 | gzip -1 >"$STATE_DIR/initrd.new"
)
gzip -t "$STATE_DIR/initrd.new"
mv "$STATE_DIR/initrd.new" /reinstall-initrd
chmod 600 /reinstall-initrd
sync
ROLLBACK=0
printf '\nPREPARED. Reboot starts DD and erases the OS disk.\n'
printf 'Cancel before reboot: bash %s/reinstall.sh reset\n' "$STATE_DIR"
printf 'Temporary SSH: root, port 22, password printed by the engine above.\n'
printf 'Windows RDP: %s:%s; credentials come from the image.\n' "$CURRENT_IP" "$RDP_PORT"
if ((REBOOT)); then
    printf 'Rebooting now...\n'
    reboot
else
    printf 'No reboot performed. When ready, run: reboot\n'
fi
