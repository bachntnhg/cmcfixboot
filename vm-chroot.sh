#!/bin/bash
# ==========================================================================
# vm-chroot.sh  (v1)
# Chạy lệnh bên trong hệ điều hành của VM từ Ubuntu Live (không cần mật khẩu root của VM):
# tự tìm root, mount /boot và /boot/efi theo fstab của VM, bind /dev /proc /sys /run,
# chroot vào chạy lệnh, xong tự umount.
#
#     sudo bash vm-chroot.sh --dracut               # tạo lại initramfs MỌI kernel, kèm virtio
#     sudo bash vm-chroot.sh                        # mở shell root trong VM (gõ exit để thoát)
#     sudo bash vm-chroot.sh -- <lệnh> [tham số]    # chạy một lệnh bất kỳ trong VM
#
# Tùy chọn:
#     --root /dev/mapper/centos-root   chỉ định root, bỏ qua bước tự dò
#
# --dracut dùng cho VM họ RHEL (CentOS, Rocky, Alma...) boot được bằng kernel rescue nhưng
# kernel thường treo "dracut-initqueue timeout" vì initramfs tạo trên Hyper-V/VMware thiếu virtio.
# ==========================================================================
# Script dùng cú pháp bash; nếu bị gọi bằng "sh vm-chroot.sh" (dash) thì tự chạy lại bằng bash
if [ -z "${BASH_VERSION:-}" ]; then
    [ -f "$0" ] && exec bash "$0" "$@"
    echo "Script cần bash, hãy chạy: sudo bash vm-chroot.sh" >&2; exit 1
fi
set -u

MNT=/mnt/vmroot
PROBE=/tmp/probe-vmroot
VIRTIO_MODS="virtio_blk virtio_scsi virtio_pci virtio_net"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[x] $*${N}" >&2; exit 1; }
step() { echo; echo "${B}=== $* ===${N}"; }

DNS_SWAPPED=0
cleanup() {
    cd / 2>/dev/null
    if [ "$DNS_SWAPPED" = "1" ]; then
        rm -f "$MNT/etc/resolv.conf"
        if [ -e "$MNT/etc/resolv.conf.vmchroot" ] || [ -L "$MNT/etc/resolv.conf.vmchroot" ]; then
            mv -f "$MNT/etc/resolv.conf.vmchroot" "$MNT/etc/resolv.conf"
        fi
    fi
    mountpoint -q "$PROBE" 2>/dev/null && umount "$PROBE" 2>/dev/null
    if mountpoint -q "$MNT" 2>/dev/null; then
        sync
        umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
    fi
}
trap cleanup EXIT

ROOT_DEV=""; MODE=shell; CMD=()
while [ $# -gt 0 ]; do
    case "$1" in
        --dracut) MODE=dracut ;;
        --root)   shift; ROOT_DEV="${1:-}" ;;
        --)       shift; MODE=cmd; CMD=("$@"); break ;;
        *)        die "Tham số không hợp lệ: $1 (xem đầu file vm-chroot.sh)" ;;
    esac
    shift
done
[ "$MODE" = "cmd" ] && [ "${#CMD[@]}" -eq 0 ] && die "Thiếu lệnh sau --"

mount_ro() { mount -o ro "$1" "$2" 2>/dev/null || mount -o ro,norecovery "$1" "$2" 2>/dev/null; }
spec_dev() {
    case "$1" in
        UUID=*)     blkid -U "${1#UUID=}" 2>/dev/null ;;
        LABEL=*)    blkid -L "${1#LABEL=}" 2>/dev/null ;;
        PARTUUID=*) blkid -t "PARTUUID=${1#PARTUUID=}" -o device 2>/dev/null | head -n1 ;;
        /dev/*)     [ -b "$1" ] && echo "$1" ;;
    esac
}
os_name() { grep -E '^PRETTY_NAME=' "$1/etc/os-release" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

# --------------------------------------------------------------------------
step "Bước 1: Tìm hệ điều hành của VM"
[ "$(id -u)" -eq 0 ] || die "Cần quyền root. Chạy: sudo bash $0"
vgchange -ay >/dev/null 2>&1
udevadm settle 2>/dev/null
mkdir -p "$PROBE" "$MNT"
if [ -z "$ROOT_DEV" ]; then
    # Chỉ xét phân vùng/LV chưa mount (bỏ qua đĩa của live CD / rescue)
    cands=(); names=()
    while read -r dev typ mp; do
        [ "$typ" = "part" ] || [ "$typ" = "lvm" ] || continue
        [ -z "${mp:-}" ] || continue
        case "$(blkid -p -s TYPE -o value "$dev" 2>/dev/null)" in swap|LVM2_member|vfat|crypto_LUKS) continue ;; esac
        mount_ro "$dev" "$PROBE" || continue
        if [ -f "$PROBE/etc/fstab" ] && { [ -e "$PROBE/etc/os-release" ] || [ -e "$PROBE/etc/redhat-release" ]; }; then
            cands+=("$dev"); names+=("$(os_name "$PROBE")")
        fi
        umount "$PROBE"
    done < <(lsblk -nrpo PATH,TYPE,MOUNTPOINT)
    if   [ "${#cands[@]}" -eq 0 ]; then
        die "Không tìm thấy root của VM. Chỉ định: sudo bash $0 --root /dev/xxx ..."
    elif [ "${#cands[@]}" -eq 1 ]; then
        ROOT_DEV="${cands[0]}"
    else
        echo "Tìm thấy nhiều hệ điều hành, chọn root:"
        opts=()
        for i in "${!cands[@]}"; do opts+=("${cands[$i]}  ${names[$i]}"); done
        PS3="Chọn số: "
        select o in "${opts[@]}"; do
            [ -n "${o:-}" ] && ROOT_DEV="${cands[$((REPLY - 1))]}" && break
        done
    fi
fi
[ -b "$ROOT_DEV" ] || die "$ROOT_DEV không phải block device."

# --------------------------------------------------------------------------
step "Bước 2: Mount hệ thống của VM vào $MNT"
mount "$ROOT_DEV" "$MNT" || die "Không mount được $ROOT_DEV"
info "Root: $ROOT_DEV ($(os_name "$MNT"))"
for mp in /boot /boot/efi; do
    spec=$(awk -v m="$mp" '!/^[[:space:]]*#/ && $2==m {print $1; exit}' "$MNT/etc/fstab")
    [ -n "$spec" ] || continue
    dev=$(spec_dev "$spec")
    [ -n "$dev" ] || die "fstab có $mp ($spec) nhưng không tìm thấy thiết bị."
    mount "$dev" "$MNT$mp" || die "Không mount được $mp ($dev)"
    info "$mp: $dev"
done
for d in /dev /dev/pts /proc /sys /run; do
    mount --bind "$d" "$MNT$d" || die "Không bind-mount $d"
done
# DNS tạm để lệnh trong chroot (yum/dnf/apt) dùng được mạng của live CD
if [ -e "$MNT/etc/resolv.conf" ] || [ -L "$MNT/etc/resolv.conf" ]; then
    mv -f "$MNT/etc/resolv.conf" "$MNT/etc/resolv.conf.vmchroot"
fi
DNS_SWAPPED=1
echo "nameserver 8.8.8.8" > "$MNT/etc/resolv.conf"

# --------------------------------------------------------------------------
case "$MODE" in
dracut)
    step "Bước 3: Tạo lại initramfs mọi kernel, kèm virtio"
    [ -x "$MNT/usr/bin/dracut" ] || [ -x "$MNT/sbin/dracut" ] || [ -x "$MNT/usr/sbin/dracut" ] \
        || die "VM không dùng dracut (Ubuntu/Debian: dùng  -- update-initramfs -u -k all)."
    chroot "$MNT" /bin/bash -s "$VIRTIO_MODS" <<'DRACUT_EOF'
export LC_ALL=C LANG=C
MODS="$1"
mkdir -p /etc/dracut.conf.d
# Kernel cài sau này cũng tự có virtio
echo "add_drivers+=\" $MODS \"" > /etc/dracut.conf.d/90-virtio.conf
rc=0
for k in /lib/modules/*; do
    v=${k##*/}
    [ -f "/boot/vmlinuz-$v" ] || continue
    case "$v" in *rescue*) continue ;; esac
    echo "== dracut $v"
    if dracut -f --add-drivers "$MODS" "/boot/initramfs-$v.img" "$v" \
       && lsinitrd "/boot/initramfs-$v.img" 2>/dev/null | grep -q virtio_blk; then
        echo "   OK: initramfs-$v.img có virtio_blk"
    else
        echo "   LỖI: initramfs-$v.img chưa có virtio_blk"; rc=1
    fi
done
exit $rc
DRACUT_EOF
    rc=$?
    ;;
cmd)
    step "Bước 3: Chạy trong VM: ${CMD[*]}"
    chroot "$MNT" /usr/bin/env LC_ALL=C LANG=C "${CMD[@]}"
    rc=$?
    ;;
shell)
    step "Bước 3: Shell root trong VM (gõ exit để thoát, mọi thay đổi là THẬT)"
    chroot "$MNT" /usr/bin/env LC_ALL=C LANG=C PS1='[VM-chroot \w]# ' /bin/bash --norc -i
    rc=0
    ;;
esac

# --------------------------------------------------------------------------
step "Bước 4: Dọn dẹp"
cleanup
trap - EXIT
if [ "$rc" -eq 0 ]; then
    info "Xong, đã umount. Có thể reboot VM."
    [ "$MODE" = "dracut" ] && info "Kernel mặc định giờ có virtio, chọn kernel thường (không phải rescue) khi boot."
else
    warn "Lệnh trong VM trả về mã $rc, xem thông báo phía trên. Đã umount."
fi
exit "$rc"
