#!/bin/bash
# ==========================================================================
# convert-to-uefi.sh
# Chuyển hệ thống Ubuntu/Debian từ MBR (legacy) sang GPT + ESP để boot UEFI.
# Chạy trong Ubuntu Desktop Live (có mạng), bằng quyền root:
#
#     sudo bash convert-to-uefi.sh            # mặc định ổ /dev/vda
#     sudo bash convert-to-uefi.sh /dev/sda   # chỉ định ổ khác
#
# Biến môi trường tùy chọn:
#     ROOT_DEV=/dev/vda1   bỏ qua bước tự dò phân vùng root
# ==========================================================================
set -u

DISK="${1:-/dev/vda}"
ESP_MAX_MIB=512
ESP_MIN_MIB=100
MNT=/mnt
PROBE=/tmp/probe-root
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[x] $*${N}" >&2; exit 1; }
step() { echo; echo "${B}=== $* ===${N}"; }

cleanup() {
    cd / 2>/dev/null
    mountpoint -q "$PROBE" 2>/dev/null && umount "$PROBE" 2>/dev/null
    if mountpoint -q "$MNT" 2>/dev/null; then
        umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
    fi
}
trap cleanup EXIT

list_esp() {
    lsblk -nrpo PATH,PARTTYPE "$DISK" 2>/dev/null \
        | awk -v g="$ESP_GUID" 'tolower($2)==g {print $1}' | sort
}

# --------------------------------------------------------------------------
step "Bước 0: Kiểm tra ban đầu"
[ "$(id -u)" -eq 0 ] || die "Cần quyền root. Chạy: sudo bash $0"
[ -b "$DISK" ] || die "Không tìm thấy ổ đĩa $DISK (dùng: sudo bash $0 /dev/xxx)"

if [ -d /sys/firmware/efi ]; then
    info "Live CD đang boot ở chế độ UEFI."
else
    warn "Live CD đang boot ở chế độ BIOS. Vẫn làm được, nhưng VM chỉ boot UEFI khi"
    warn "hạ tầng cấp firmware UEFI cho VM."
fi

if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q .; then
    lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "$DISK"
    die "Có phân vùng của $DISK đang được mount. Hãy umount hết rồi chạy lại."
fi

if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    info "Có kết nối mạng."
else
    die "Không có mạng (ping 8.8.8.8 lỗi). Cần mạng để cài gói GRUB UEFI."
fi

# --------------------------------------------------------------------------
step "Bước 1: Cài công cụ cần thiết trong live CD"
need=()
command -v sgdisk    >/dev/null || need+=(gdisk)
command -v mkfs.vfat >/dev/null || need+=(dosfstools)
command -v vgchange  >/dev/null || need+=(lvm2)
command -v partprobe >/dev/null || need+=(parted)
if [ "${#need[@]}" -gt 0 ]; then
    info "Cài: ${need[*]}"
    apt-get update -qq
    apt-get install -y "${need[@]}" || die "Không cài được ${need[*]}"
else
    info "Đã đủ công cụ."
fi

# --------------------------------------------------------------------------
step "Bước 2: Hiện trạng đĩa $DISK"
PT=$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null)
lsblk -o NAME,FSTYPE,SIZE,PARTTYPE,LABEL "$DISK"
echo "Kiểu bảng phân vùng hiện tại: ${PT:-không xác định}"
case "$PT" in
    dos) info "Đĩa là MBR, sẽ được chuyển sang GPT." ;;
    gpt) info "Đĩa đã là GPT, bỏ qua bước chuyển." ;;
    *)   die "Không nhận diện được bảng phân vùng. Dừng để an toàn." ;;
esac

echo
echo "${Y}Script sẽ GHI vào bảng phân vùng của $DISK.${N}"
echo "${Y}Hãy chắc chắn đã snapshot/backup volume trước khi tiếp tục.${N}"
read -rp "Gõ YES (viết hoa) để tiếp tục: " ans
[ "$ans" = "YES" ] || die "Đã hủy."

# --------------------------------------------------------------------------
step "Bước 3: Chuyển MBR sang GPT, đưa backup GPT về cuối đĩa"
if [ "$PT" = "dos" ]; then
    sgdisk -g "$DISK" || die "sgdisk -g lỗi (thường do cuối đĩa không còn ~34 sector trống)."
fi
sgdisk -e "$DISK" || die "sgdisk -e lỗi."
partprobe "$DISK"; udevadm settle; sleep 1
sgdisk -p "$DISK"

# --------------------------------------------------------------------------
step "Bước 4: Tạo và format phân vùng ESP"
ESP_DEV=$(list_esp | head -n1)
if [ -n "$ESP_DEV" ]; then
    fs=$(blkid -s TYPE -o value "$ESP_DEV" 2>/dev/null)
    [ "$fs" = "vfat" ] || die "Đã có ESP $ESP_DEV nhưng không phải vfat ($fs). Kiểm tra thủ công."
    info "Đã có sẵn ESP: $ESP_DEV, dùng lại, không format."
else
    F=$(sgdisk -F "$DISK" 2>/dev/null | tail -n1)
    E=$(sgdisk -E "$DISK" 2>/dev/null | tail -n1)
    case "$F$E" in (*[!0-9]*|"") die "Không đọc được vùng trống của đĩa." ;; esac
    free_mib=$(( (E - F + 1) / 2048 ))
    info "Vùng trống lớn nhất: ${free_mib} MiB"
    if [ "$free_mib" -lt $((ESP_MIN_MIB + 1)) ]; then
        die "Không đủ vùng trống cho ESP (cần >= ${ESP_MIN_MIB} MiB). Hãy extend volume thêm ~1 GiB trên OpenStack, boot lại live CD rồi chạy lại script."
    fi
    size=$ESP_MAX_MIB
    [ "$free_mib" -le "$size" ] && size=$((free_mib - 1))
    info "Tạo ESP ${size} MiB"

    before=$(list_esp)
    sgdisk -n "0:0:+${size}M" -t 0:ef00 -c 0:"EFI System" "$DISK" || die "Không tạo được phân vùng ESP."
    partprobe "$DISK"; udevadm settle; sleep 2
    after=$(list_esp)
    ESP_DEV=$(comm -13 <(echo "$before") <(echo "$after") | grep -v '^$' | head -n1)
    [ -n "$ESP_DEV" ] || die "Không xác định được phân vùng ESP vừa tạo."
    mkfs.vfat -F32 -n EFI "$ESP_DEV" || die "mkfs.vfat lỗi."
    info "Đã tạo và format ESP: $ESP_DEV"
fi
ESP_UUID=$(blkid -s UUID -o value "$ESP_DEV")
[ -n "$ESP_UUID" ] || die "Không đọc được UUID của $ESP_DEV"
info "ESP: $ESP_DEV  UUID=$ESP_UUID"

# --------------------------------------------------------------------------
step "Bước 5: Dò phân vùng root của hệ thống"
vgchange -ay >/dev/null 2>&1
ROOT_DEV="${ROOT_DEV:-}"
if [ -z "$ROOT_DEV" ]; then
    mkdir -p "$PROBE"
    cands=()
    while read -r dev fs; do
        case "$fs" in ext2|ext3|ext4|xfs|btrfs) ;; *) continue ;; esac
        if mount -o ro "$dev" "$PROBE" 2>/dev/null; then
            if [ -f "$PROBE/etc/fstab" ] && [ -f "$PROBE/etc/os-release" ]; then
                cands+=("$dev")
            fi
            umount "$PROBE"
        fi
    done < <(lsblk -nrpo PATH,FSTYPE "$DISK")

    if   [ "${#cands[@]}" -eq 0 ]; then
        die "Không tìm thấy phân vùng root. Chạy lại với: ROOT_DEV=/dev/xxx sudo -E bash $0"
    elif [ "${#cands[@]}" -eq 1 ]; then
        ROOT_DEV="${cands[0]}"
    else
        echo "Tìm thấy nhiều ứng viên, chọn phân vùng root:"
        PS3="Chọn số: "
        select d in "${cands[@]}"; do
            [ -n "${d:-}" ] && ROOT_DEV="$d" && break
        done
    fi
fi
info "Phân vùng root: $ROOT_DEV"

# --------------------------------------------------------------------------
step "Bước 6: Mount hệ thống"
mkdir -p "$MNT"
mount "$ROOT_DEV" "$MNT" || die "Không mount được $ROOT_DEV"

BOOT_SPEC=$(awk '!/^[[:space:]]*#/ && $2=="/boot" {print $1; exit}' "$MNT/etc/fstab")
if [ -n "$BOOT_SPEC" ]; then
    case "$BOOT_SPEC" in
        /dev/*) BOOT_DEV="$BOOT_SPEC" ;;
        *)      BOOT_DEV=$(findfs "$BOOT_SPEC" 2>/dev/null) ;;
    esac
    [ -n "${BOOT_DEV:-}" ] || die "fstab có /boot riêng ($BOOT_SPEC) nhưng không tìm thấy thiết bị."
    mount "$BOOT_DEV" "$MNT/boot" || die "Không mount được /boot ($BOOT_DEV)"
    info "Đã mount /boot riêng: $BOOT_DEV"
fi

mkdir -p "$MNT/boot/efi"
mount "$ESP_DEV" "$MNT/boot/efi" || die "Không mount được ESP"
for i in /dev /dev/pts /proc /sys /run; do
    mount --bind "$i" "$MNT$i" || die "Không bind-mount $i"
done
[ -d /sys/firmware/efi/efivars ] && mount --bind /sys/firmware/efi/efivars "$MNT/sys/firmware/efi/efivars" 2>/dev/null || true

if grep -Eq '^/dev/(sd|vd|hd|xvd)' "$MNT/etc/fstab"; then
    warn "fstab đang dùng tên thiết bị (/dev/vdX...) thay vì UUID. Nên kiểm tra sau khi boot."
fi

# --------------------------------------------------------------------------
step "Bước 7: Cấu hình mạng (netplan)"
echo "Cấu hình netplan hiện tại:"
cat "$MNT"/etc/netplan/*.yaml 2>/dev/null || echo "(không có file netplan)"
echo
echo "Nếu máy gốc dùng tên card mạng cố định (ens160, eth0...), VM mới có thể mất mạng/SSH."
echo "Ghi đè bằng cấu hình DHCP chung sẽ khắc phục (file cũ được backup vào /root/netplan-backup)."
echo "${Y}Đừng chọn y nếu máy dùng IP tĩnh.${N}"
read -rp "Ghi đè netplan bằng DHCP chung? (y/N): " nans
FIX_NET=0
case "$nans" in y|Y) FIX_NET=1 ;; esac

# --------------------------------------------------------------------------
step "Bước 8: Chạy cấu hình trong chroot (cài GRUB UEFI, virtio, fstab)"
cat > "$MNT/root/fix-uefi-chroot.sh" <<'CHROOT_EOF'
#!/bin/bash
set -e
ESP_UUID="$1"
FIX_NET="$2"
export DEBIAN_FRONTEND=noninteractive

# DNS tạm thời
if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
    mv -f /etc/resolv.conf /etc/resolv.conf.livebak
fi
echo "nameserver 8.8.8.8" > /etc/resolv.conf
restore_dns() {
    rm -f /etc/resolv.conf
    if [ -e /etc/resolv.conf.livebak ] || [ -L /etc/resolv.conf.livebak ]; then
        mv -f /etc/resolv.conf.livebak /etc/resolv.conf
    fi
}
trap restore_dns EXIT

echo "[chroot] Cập nhật fstab"
cp -a /etc/fstab "/etc/fstab.bak.$(date +%s)"
sed -i '\#[[:space:]]/boot/efi[[:space:]]#d' /etc/fstab
[ -n "$(tail -c1 /etc/fstab)" ] && echo >> /etc/fstab
echo "UUID=$ESP_UUID  /boot/efi  vfat  umask=0077  0  1" >> /etc/fstab

echo "[chroot] Cài GRUB UEFI"
apt-get update
apt-get install -y -o Dpkg::Options::=--force-confold \
    grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr

echo "[chroot] Thêm driver virtio vào initramfs"
for m in virtio_blk virtio_scsi virtio_net virtio_pci; do
    grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
done
update-initramfs -u -k all

echo "[chroot] grub-install"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --recheck \
    || echo "[chroot] Cảnh báo: không ghi được entry NVRAM (bình thường trên cloud), dùng bản --removable."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck
update-grub

if [ "$FIX_NET" = "1" ]; then
    echo "[chroot] Ghi đè netplan bằng DHCP chung"
    mkdir -p /root/netplan-backup
    cp -a /etc/netplan/. /root/netplan-backup/ 2>/dev/null || true
    rm -f /etc/netplan/*.yaml
    cat > /etc/netplan/01-generic-dhcp.yaml <<'NETEOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "e*"
      dhcp4: true
NETEOF
    chmod 600 /etc/netplan/01-generic-dhcp.yaml
fi

echo "[chroot] Kiểm tra file boot UEFI"
test -f /boot/efi/EFI/BOOT/BOOTX64.EFI
ls -R /boot/efi/EFI
CHROOT_EOF
chmod +x "$MNT/root/fix-uefi-chroot.sh"

chroot "$MNT" /bin/bash /root/fix-uefi-chroot.sh "$ESP_UUID" "$FIX_NET"
rc=$?
rm -f "$MNT/root/fix-uefi-chroot.sh"
[ "$rc" -eq 0 ] || die "Bước trong chroot bị lỗi (mã $rc). Xem thông báo phía trên. Bảng phân vùng đã được đổi sang GPT, ĐỪNG reboot khi chưa sửa xong."

# --------------------------------------------------------------------------
step "Bước 9: Dọn dẹp"
cleanup
trap - EXIT
sync

echo
echo "${G}${B}HOÀN TẤT.${N}"
echo "Việc còn lại:"
echo "  1. Tháo ISO Ubuntu live khỏi instance."
echo "  2. Đảm bảo VM chạy firmware UEFI (hw_firmware_type=uefi), rồi: reboot"
echo "  3. Sau khi boot, kiểm tra:"
echo "       [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS"
echo "       lsblk -f"