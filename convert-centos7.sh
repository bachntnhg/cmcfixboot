#!/bin/bash
# ==========================================================================
# convert-centos7.sh  (v1)
# Sửa VM CentOS 7 tạo trên Hyper-V Gen 1 (Legacy BIOS + MBR) để boot được trên
# OpenStack khi instance bắt buộc chạy firmware UEFI (rơi vào "UEFI Interactive
# Shell") và không đổi được hw_firmware_type.
#
# Cách làm (KHÔNG thu nhỏ phân vùng nào, không chuyển GPT):
#   - Chép nội dung phân vùng /boot riêng (thường vda1, XFS 1 GiB) vào /boot
#     trên filesystem root (LVM centos-root), kiểm tra bản chép
#   - Format phân vùng /boot cũ thành ESP FAT32, đổi type MBR sang 0xEF
#     (UEFI đọc được ESP trên đĩa MBR)
#   - Cài grub2-efi + shim từ vault.centos.org, tạo grub.cfg cho UEFI,
#     đặt bản --removable EFI/BOOT/BOOTX64.EFI (không phụ thuộc NVRAM)
#   - Thêm driver virtio vào initramfs, sửa mạng (ifcfg), bật SELinux relabel
# Sau khi chạy, VM CHỈ boot được UEFI.
#
# Nếu fstab đã có /boot/efi (VM cài kiểu UEFI: Hyper-V Gen 2, VMware EFI...), script
# chạy chế độ "chỉ sửa cấu hình": giữ nguyên phân vùng, đặt EFI/BOOT/BOOTX64.EFI,
# tạo lại grub.cfg, virtio, mạng, SELinux relabel (chỉ tải gói nếu ESP thiếu file).
#
# Chạy trong Ubuntu Live (có mạng), bằng quyền root:
#
#     sudo bash convert-centos7.sh            # mặc định ổ /dev/vda
#     sudo bash convert-centos7.sh /dev/vdb   # ví dụ khi dùng rescue mode
#
# Biến môi trường tùy chọn:
#     ROOT_DEV=/dev/mapper/centos-root   bỏ qua bước tự dò phân vùng root
# ==========================================================================
# Script dùng cú pháp bash; nếu bị gọi bằng "sh convert-centos7.sh" (dash) thì tự chạy lại bằng bash
if [ -z "${BASH_VERSION:-}" ]; then
    [ -f "$0" ] && exec bash "$0" "$@"
    echo "Script cần bash, hãy chạy: sudo bash convert-centos7.sh" >&2; exit 1
fi
set -u

DISK="${1:-/dev/vda}"
MNT=/mnt
PROBE=/tmp/probe-root
VAULT=http://vault.centos.org
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

part_num() { cat "/sys/class/block/$(basename "$1")/partition" 2>/dev/null; }
# Thiết bị theo cột 1 của fstab (UUID=, LABEL= hoặc /dev/...)
spec_dev() { case "$1" in /dev/*) echo "$1" ;; *) findfs "$1" 2>/dev/null ;; esac; }

# --------------------------------------------------------------------------
step "Bước 0: Kiểm tra ban đầu"
[ "$(id -u)" -eq 0 ] || die "Cần quyền root. Chạy: sudo bash $0"
[ -b "$DISK" ] || die "Không tìm thấy ổ đĩa $DISK (dùng: sudo bash $0 /dev/xxx)"

if [ -d /sys/firmware/efi ]; then
    info "Live CD đang boot ở chế độ UEFI."
else
    warn "Live CD đang boot ở chế độ BIOS. Vẫn chạy được, nhưng sau khi sửa VM CHỈ boot được UEFI."
fi

if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q .; then
    lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT "$DISK"
    die "Có phân vùng của $DISK đang được mount. Hãy umount hết rồi chạy lại."
fi

if ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    info "Có kết nối mạng."
else
    die "Không có mạng (ping 8.8.8.8 lỗi). Cần mạng để tải gói GRUB UEFI từ $VAULT."
fi

# --------------------------------------------------------------------------
step "Bước 1: Cài công cụ cần thiết trong live CD"
need_pkgs=()
command -v mkfs.vfat >/dev/null || need_pkgs+=(dosfstools)
command -v vgchange  >/dev/null || need_pkgs+=(lvm2)
command -v sfdisk    >/dev/null || need_pkgs+=(fdisk)
command -v diff      >/dev/null || need_pkgs+=(diffutils)
if [ "${#need_pkgs[@]}" -gt 0 ]; then
    info "Cài: ${need_pkgs[*]}"
    apt-get update -qq
    apt-get install -y "${need_pkgs[@]}" || die "Không cài được ${need_pkgs[*]}"
else
    info "Đã đủ công cụ."
fi

# --------------------------------------------------------------------------
step "Bước 2: Hiện trạng đĩa $DISK"
PT=$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null)
lsblk -o NAME,FSTYPE,SIZE,PARTTYPE,LABEL "$DISK"
echo "Kiểu bảng phân vùng: ${PT:-không xác định}"
case "$PT" in
    dos|gpt) ;;
    *) die "Không nhận diện được bảng phân vùng. Dừng để an toàn." ;;
esac

# --------------------------------------------------------------------------
step "Bước 3: Dò phân vùng root CentOS 7"
vgchange -ay >/dev/null 2>&1
udevadm settle
ROOT_DEV="${ROOT_DEV:-}"
mkdir -p "$PROBE"
if [ -z "$ROOT_DEV" ]; then
    cands=()
    while read -r dev fs; do
        # FSTYPE của lsblk lấy từ udev, có thể trống trên live CD
        [ -n "$fs" ] || fs=$(blkid -p -s TYPE -o value "$dev" 2>/dev/null)
        case "$fs" in ext2|ext3|ext4|xfs) ;; *) continue ;; esac
        if mount -o ro "$dev" "$PROBE" 2>/dev/null; then
            if [ -f "$PROBE/etc/fstab" ] && [ -f "$PROBE/etc/centos-release" ]; then
                cands+=("$dev")
            fi
            umount "$PROBE"
        fi
    done < <(lsblk -nrpo PATH,FSTYPE "$DISK")

    if   [ "${#cands[@]}" -eq 0 ]; then
        die "Không tìm thấy root CentOS. Chạy lại: sudo ROOT_DEV=/dev/xxx bash $0"
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
[ -b "$ROOT_DEV" ] || die "$ROOT_DEV không phải block device."
info "Phân vùng root: $ROOT_DEV"

# --------------------------------------------------------------------------
step "Bước 4: Kiểm tra hệ thống và lập kế hoạch"
mkdir -p "$MNT"
mount "$ROOT_DEV" "$MNT" || die "Không mount được $ROOT_DEV"

[ -f "$MNT/etc/centos-release" ] || die "$ROOT_DEV không phải CentOS (thiếu /etc/centos-release)."
REL=$(cat "$MNT/etc/centos-release")
VER=$(grep -oE '7\.[0-9]+\.[0-9]+' "$MNT/etc/centos-release" | head -n1)
[ -n "$VER" ] || die "Script chỉ hỗ trợ CentOS 7, hệ thống là: $REL"
info "Hệ điều hành: $REL (vault: $VAULT/$VER)"

ROOT_FS=$(blkid -p -s TYPE -o value "$ROOT_DEV")
case "$ROOT_FS" in
    xfs|ext2|ext3|ext4) ;;
    *) die "Root là '$ROOT_FS', GRUB có thể không đọc được /boot trên đó. Dừng." ;;
esac

BOOT_SPEC=$(awk '!/^[[:space:]]*#/ && $2=="/boot" {print $1; exit}' "$MNT/etc/fstab")
ESP_SPEC=$(awk '!/^[[:space:]]*#/ && $2=="/boot/efi" {print $1; exit}' "$MNT/etc/fstab")
BOOT_DEV=""
if [ -n "$BOOT_SPEC" ]; then
    BOOT_DEV=$(spec_dev "$BOOT_SPEC")
    [ -n "$BOOT_DEV" ] && [ -b "$BOOT_DEV" ] || die "fstab có /boot ($BOOT_SPEC) nhưng không tìm thấy thiết bị."
fi

if [ -n "$ESP_SPEC" ]; then
    # Đã cài kiểu UEFI (Hyper-V Gen 2, VMware EFI...): giữ nguyên phân vùng, chỉ sửa cấu hình
    MODE=uefi
    ESP_DEV=$(spec_dev "$ESP_SPEC")
    [ -n "$ESP_DEV" ] && [ -b "$ESP_DEV" ] || die "fstab có /boot/efi ($ESP_SPEC) nhưng không tìm thấy thiết bị."
    ESP_FS=$(blkid -p -s TYPE -o value "$ESP_DEV")
    [ "$ESP_FS" = "vfat" ] || die "ESP $ESP_DEV không phải vfat (${ESP_FS:-không rõ}). Kiểm tra thủ công."
    info "Hệ thống đã cài kiểu UEFI. ESP: $ESP_DEV${BOOT_DEV:+, /boot: $BOOT_DEV}"
    info "Chế độ chỉ sửa cấu hình: không đổi phân vùng, không format."
else
    MODE=bios
    [ -n "$BOOT_DEV" ] || die "Không có phân vùng /boot riêng. Trường hợp này cần chỗ trống cho ESP, script chưa hỗ trợ."
    BOOT_PARENT=$(lsblk -nrpo PKNAME "$BOOT_DEV" 2>/dev/null | head -n1)
    [ "$(readlink -f "$BOOT_PARENT")" = "$(readlink -f "$DISK")" ] || die "/boot ($BOOT_DEV) không nằm trực tiếp trên $DISK."
    BOOT_N=$(part_num "$BOOT_DEV")
    [ -n "$BOOT_N" ] || die "Không xác định được số thứ tự phân vùng của $BOOT_DEV."
    BOOT_MIB=$(( $(blockdev --getsz "$BOOT_DEV") / 2048 ))
    [ "$BOOT_MIB" -ge 100 ] || die "Phân vùng /boot chỉ ${BOOT_MIB} MiB, quá nhỏ để làm ESP."

    mount -o ro "$BOOT_DEV" "$PROBE" || die "Không mount được /boot ($BOOT_DEV)"
    BOOT_USED=$(du -sm "$PROBE" | cut -f1)
    ROOT_FREE=$(df -Pm "$MNT" | awk 'NR==2 {print $4}')
    info "/boot: $BOOT_DEV (${BOOT_MIB} MiB, đang dùng ${BOOT_USED} MiB); root còn trống ${ROOT_FREE} MiB"
    [ "$ROOT_FREE" -ge $((BOOT_USED + 512)) ] || die "Root không đủ chỗ để chứa /boot (cần ~$((BOOT_USED + 512)) MiB)."
fi

# Mạng: ifcfg của Hyper-V thường gắn HWADDR cũ; IP tĩnh cũ không khớp port Neutron
NS="$MNT/etc/sysconfig/network-scripts"
echo
echo "Cấu hình mạng hiện tại:"
IFCFGS=()
for f in "$NS"/ifcfg-*; do
    [ -f "$f" ] && [ "$f" != "$NS/ifcfg-lo" ] && IFCFGS+=("$f")
done
if [ "${#IFCFGS[@]}" -eq 0 ]; then
    echo "(không có file ifcfg)"
else
    for f in "${IFCFGS[@]}"; do echo "--- ${f#$MNT}"; cat "$f"; done
fi
echo
NET_DEFAULT=N
if [ "${#IFCFGS[@]}" -eq 0 ] || ! grep -Eiq '^[[:space:]]*BOOTPROTO=["'\'']?dhcp' "${IFCFGS[@]}"; then
    warn "Không thấy card nào dùng DHCP. Trên OpenStack IP do Neutron cấp qua DHCP, IP tĩnh cũ thường không dùng được."
    NET_DEFAULT=Y
fi
echo "Y: thay toàn bộ ifcfg bằng ifcfg-eth0 DHCP (file cũ backup vào /root/network-backup)."
echo "N: giữ cấu hình, chỉ bỏ HWADDR/MACADDR/UUID gắn với card Hyper-V cũ."
read -rp "Chuyển mạng sang DHCP? (Y/N, mặc định $NET_DEFAULT): " nans
[ -z "$nans" ] && nans="$NET_DEFAULT"
FIX_NET=0
case "$nans" in y|Y) FIX_NET=1 ;; esac

echo
echo "${Y}${B}KẾ HOẠCH${N}"
NET_PLAN=$([ "$FIX_NET" = 1 ] && echo "DHCP eth0" || echo "giữ nguyên, bỏ HWADDR/UUID")
if [ "$MODE" = "uefi" ]; then
    echo "  1. Giữ nguyên phân vùng; chỉ cài lại grub2-efi + shim từ $VAULT/$VER nếu ESP thiếu file"
    echo "  2. Đặt EFI/BOOT/BOOTX64.EFI (boot không cần NVRAM), tạo lại grub.cfg UEFI"
    echo "  3. initramfs có virtio, mạng: $NET_PLAN, SELinux relabel"
else
    echo "  1. Chép /boot ($BOOT_DEV) vào /boot trên root ($ROOT_DEV), so sánh bản chép"
    echo "  2. FORMAT $BOOT_DEV thành ESP FAT32, đổi type phân vùng sang EFI System"
    echo "  3. fstab: tắt dòng /boot, thêm /boot/efi"
    echo "  4. Cài grub2-efi + shim từ $VAULT/$VER, tạo grub.cfg UEFI"
    echo "  5. initramfs có virtio, mạng: $NET_PLAN, SELinux relabel"
fi
echo "${Y}Thao tác này GHI lên đĩa. Hãy chắc chắn đã snapshot/backup volume trước.${N}"
read -rp "Gõ YES (viết hoa) để tiếp tục: " ans
[ "$ans" = "YES" ] || die "Đã hủy. Chưa có thay đổi nào trên đĩa."

# --------------------------------------------------------------------------
step "Bước 5: Tải trước gói GRUB UEFI (chưa đổi gì trên đĩa)"
if [ "$MODE" = "uefi" ]; then
    if [ -n "$BOOT_DEV" ]; then
        mount "$BOOT_DEV" "$MNT/boot" || die "Không mount được /boot ($BOOT_DEV)"
    fi
    mkdir -p "$MNT/boot/efi"
    mount "$ESP_DEV" "$MNT/boot/efi" || die "Không mount được ESP ($ESP_DEV)"
fi
for i in /dev /dev/pts /proc /sys /run; do
    mount --bind "$i" "$MNT$i" || die "Không bind-mount $i"
done

cat > "$MNT/root/c7-efi-chroot.sh" <<'CHROOT_EOF'
#!/bin/bash
set -e
PHASE="$1"
VER="$2"
FIX_NET="${3:-0}"
VAULT=http://vault.centos.org
RPMS=/root/efi-rpms
EFIDIR=/boot/efi/EFI/centos
# Live CD truyền LANG=C.UTF-8, CentOS 7 không có locale này (dracut/yum báo setlocale)
export LC_ALL=C LANG=C

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

if [ "$PHASE" = "download" ]; then
    # Mirror CentOS 7 đã ngừng, dùng vault đúng phiên bản. Repo để enabled=0 để không ảnh hưởng yum thường.
    cat > /etc/yum.repos.d/CentOS-Vault-EFI.repo <<EOF
[c7-efi-os]
name=CentOS-$VER - Base (vault)
baseurl=$VAULT/$VER/os/x86_64/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=0

[c7-efi-updates]
name=CentOS-$VER - Updates (vault)
baseurl=$VAULT/$VER/updates/x86_64/
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    YUM=(yum -y --disablerepo='*' --enablerepo=c7-efi-os,c7-efi-updates)
    echo "[chroot] Kiểm tra kết nối tới $VAULT/$VER"
    "${YUM[@]}" makecache || { echo "[chroot] LỖI: không đọc được repo vault."; exit 1; }

    # Từ 7.5 gói đổi tên thành grub2-efi-x64 / shim-x64
    if "${YUM[@]}" list grub2-efi-x64 >/dev/null 2>&1; then
        PKGS="grub2-efi-x64 shim-x64 efibootmgr"
    else
        PKGS="grub2-efi shim efibootmgr"
    fi
    echo "[chroot] Gói cần cài: $PKGS"
    rm -rf "$RPMS"; mkdir -p "$RPMS"
    INST=""; REINST=""
    for p in $PKGS; do
        if rpm -q "$p" >/dev/null 2>&1; then REINST="$REINST $p"; else INST="$INST $p"; fi
    done
    # yum --downloadonly có thể trả mã lỗi dù tải xong, nên kiểm tra file thay vì mã thoát
    # shellcheck disable=SC2086
    [ -n "$INST" ] && "${YUM[@]}" install --downloadonly --downloaddir="$RPMS" $INST || true
    # shellcheck disable=SC2086
    [ -n "$REINST" ] && "${YUM[@]}" reinstall --downloadonly --downloaddir="$RPMS" $REINST || true
    for p in $PKGS; do
        ls "$RPMS/$p"-[0-9]*.rpm >/dev/null 2>&1 || { echo "[chroot] LỖI: không tải được gói $p."; exit 1; }
    done
    echo "[chroot] Đã tải:"
    ls "$RPMS"
    exit 0
fi

# ---------------- PHASE=configure ----------------
# Hệ thống đã UEFI và ESP đủ file thì không có gói nào được tải
if ls "$RPMS"/*.rpm >/dev/null 2>&1; then
    echo "[chroot] Cài gói GRUB UEFI đã tải"
    rpm -Uvh --replacepkgs "$RPMS"/*.rpm
fi

SHIM=""
for f in shimx64.efi shim.efi; do
    [ -f "$EFIDIR/$f" ] && SHIM="$EFIDIR/$f" && break
done
if [ -z "$SHIM" ] || [ ! -f "$EFIDIR/grubx64.efi" ]; then
    echo "[chroot] LỖI: không thấy shim/grubx64.efi trong $EFIDIR"; ls -R /boot/efi; exit 1
fi
echo "[chroot] Đặt bootloader dự phòng EFI/BOOT/BOOTX64.EFI ($SHIM)"
mkdir -p /boot/efi/EFI/BOOT
cp -f "$SHIM" /boot/efi/EFI/BOOT/BOOTX64.EFI
cp -f "$EFIDIR/grubx64.efi" /boot/efi/EFI/BOOT/grubx64.efi
# Bỏ fallback: nó ghi NVRAM rồi reset máy; shim sẽ nạp thẳng grubx64.efi cùng thư mục,
# grubx64.efi đọc cấu hình ở /EFI/centos/grub.cfg
rm -f /boot/efi/EFI/BOOT/fallback.efi /boot/efi/EFI/BOOT/fbx64.efi

echo "[chroot] Cấu hình mạng"
NS=/etc/sysconfig/network-scripts
mkdir -p /root/network-backup
cp -a "$NS"/ifcfg-* /root/network-backup/ 2>/dev/null || true
[ -f /etc/udev/rules.d/70-persistent-net.rules ] && mv -f /etc/udev/rules.d/70-persistent-net.rules /root/network-backup/
if [ "$FIX_NET" = "1" ]; then
    for f in "$NS"/ifcfg-*; do
        [ "$f" = "$NS/ifcfg-lo" ] || rm -f "$f"
    done
    cat > "$NS/ifcfg-eth0" <<'NETEOF'
DEVICE=eth0
NAME=eth0
TYPE=Ethernet
BOOTPROTO=dhcp
ONBOOT=yes
DEFROUTE=yes
PEERDNS=yes
IPV6INIT=no
NETEOF
    echo "  ifcfg-eth0: DHCP"
else
    for f in "$NS"/ifcfg-*; do
        [ -f "$f" ] && [ "$f" != "$NS/ifcfg-lo" ] && sed -i -E '/^[[:space:]]*(HWADDR|MACADDR|UUID)=/d' "$f"
    done
    echo "  Đã bỏ HWADDR/MACADDR/UUID"
fi

echo "[chroot] Sửa tham số kernel (/etc/default/grub)"
cp -a /etc/default/grub "/root/grub.default.bak.$(date +%s)"
CUR=$(set +e; . /etc/default/grub >/dev/null 2>&1; printf '%s' "${GRUB_CMDLINE_LINUX:-}")
NEW=$(
    set -f
    out=""
    for t in $CUR; do
        case "$t" in console=*|net.ifnames=*|biosdevname=*|rhgb) ;; *) out="$out$t " ;; esac
    done
    printf '%s' "$out"
)
# Card Hyper-V tên eth0; virtio trên KVM sẽ thành ens3/enp... nếu không giữ tên cũ
[ -f "$NS/ifcfg-eth0" ] && NEW="${NEW}net.ifnames=0 biosdevname=0 "
NEW="${NEW}console=ttyS0,115200 console=tty0"
echo "  Cũ : $CUR"
echo "  Mới: $NEW"
if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
    awk -v v="$NEW" '/^GRUB_CMDLINE_LINUX=/ {print "GRUB_CMDLINE_LINUX=\"" v "\""; next} {print}' \
        /etc/default/grub > /etc/default/grub.new
    mv -f /etc/default/grub.new /etc/default/grub
else
    echo "GRUB_CMDLINE_LINUX=\"$NEW\"" >> /etc/default/grub
fi

echo "[chroot] Driver virtio trong initramfs"
VIRTIO_MODS="virtio_blk virtio_scsi virtio_pci virtio_net"
# Kernel cài sau này tự có virtio
mkdir -p /etc/dracut.conf.d
echo "add_drivers+=\" $VIRTIO_MODS \"" > /etc/dracut.conf.d/90-virtio.conf
# Chỉ xử lý kernel mới nhất (entry mặc định của grub.cfg mới); kernel cũ vẫn boot bằng initramfs cũ
KVER=$(for d in /lib/modules/*; do v=${d##*/}; [ -f "/boot/vmlinuz-$v" ] && echo "$v"; done \
    | grep -v rescue | sort -V | tail -n1)
if [ -z "$KVER" ]; then
    echo "[chroot] LỖI: không tìm thấy kernel nào trong /boot"; exit 1
fi
if lsinitrd "/boot/initramfs-$KVER.img" 2>/dev/null | grep -q 'virtio_blk'; then
    echo "  $KVER: initramfs đã có virtio_blk, bỏ qua"
else
    # initramfs tạo trên Hyper-V (hostonly) chỉ có hv_storvsc, thiếu virtio_blk thì không thấy đĩa trên KVM
    echo "  $KVER: thêm $VIRTIO_MODS"
    dracut -f --add-drivers "$VIRTIO_MODS" "/boot/initramfs-$KVER.img" "$KVER"
    lsinitrd "/boot/initramfs-$KVER.img" | grep -q 'virtio_blk' \
        || { echo "[chroot] LỖI: initramfs $KVER vẫn thiếu virtio_blk"; exit 1; }
fi

echo "[chroot] Tạo grub.cfg UEFI"
grub2-mkconfig -o "$EFIDIR/grub.cfg"
# grub2-mkconfig chỉ dùng linuxefi khi thấy /sys/firmware/efi; ép lại nếu live CD boot BIOS
sed -i -E 's/^([[:space:]]*)linux16[[:space:]]/\1linuxefi /; s/^([[:space:]]*)initrd16[[:space:]]/\1initrdefi /' "$EFIDIR/grub.cfg"
[ -f "$EFIDIR/grubenv" ] || grub2-editenv "$EFIDIR/grubenv" create
[ -e /etc/grub2-efi.cfg ] || ln -sf ../boot/efi/EFI/centos/grub.cfg /etc/grub2-efi.cfg
if ! grep -q 'linuxefi.*vmlinuz' "$EFIDIR/grub.cfg"; then
    echo "[chroot] LỖI: grub.cfg không có entry linuxefi nào."; exit 1
fi
echo "[chroot] Tham số root trong grub.cfg:"
grep -o 'root=[^ ]*' "$EFIDIR/grub.cfg" | sort -u | head -3

echo "[chroot] Tắt dịch vụ Hyper-V (nếu có)"
for svc in hypervkvpd.service hypervvssd.service hypervfcopyd.service; do
    systemctl disable "$svc" >/dev/null 2>&1 && echo "  disable $svc" || true
done

# File tạo/sửa từ live CD (không có SELinux) chưa có nhãn đúng
if grep -Eq '^[[:space:]]*SELINUX=(enforcing|permissive)' /etc/selinux/config 2>/dev/null; then
    echo "[chroot] Bật SELinux relabel ở lần boot đầu"
    touch /.autorelabel
fi

echo "[chroot] Kiểm tra file boot UEFI"
ls -R /boot/efi/EFI
for f in /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/grubx64.efi "$EFIDIR/grub.cfg"; do
    if [ ! -f "$f" ]; then
        echo "[chroot] LỖI: thiếu $f"; exit 1
    fi
done
rm -rf "$RPMS"
CHROOT_EOF
chmod +x "$MNT/root/c7-efi-chroot.sh"

NEED_DL=1
if [ "$MODE" = "uefi" ]; then
    # Chỉ tải gói khi ESP thiếu file bootloader của CentOS
    if [ -f "$MNT/boot/efi/EFI/centos/grubx64.efi" ] \
       && { [ -f "$MNT/boot/efi/EFI/centos/shimx64.efi" ] || [ -f "$MNT/boot/efi/EFI/centos/shim.efi" ]; }; then
        NEED_DL=0
    fi
fi
if [ "$NEED_DL" = "1" ]; then
    chroot "$MNT" /bin/bash /root/c7-efi-chroot.sh download "$VER" \
        || die "Không tải được gói GRUB UEFI từ vault. Đĩa chưa bị đổi (chỉ thêm file repo và /root/efi-rpms)."
else
    rm -rf "$MNT/root/efi-rpms"
    info "ESP đã có grubx64.efi và shim, không cần tải gói."
fi

if [ "$MODE" = "bios" ]; then
    # ----------------------------------------------------------------------
    step "Bước 6: Chép /boot vào filesystem root"
    if [ -n "$(ls -A "$MNT/boot" 2>/dev/null)" ]; then
        HIDDEN="/root/boot-hidden-$(date +%s)"
        warn "Thư mục /boot trên root (bị che bởi mount) có sẵn file, chuyển sang $HIDDEN"
        mv "$MNT/boot" "$MNT$HIDDEN" || die "Không chuyển được thư mục /boot cũ."
        mkdir "$MNT/boot"
    fi
    cp -a "$PROBE/." "$MNT/boot/" || die "Chép /boot lỗi. Phân vùng /boot cũ chưa bị đổi."
    sync
    diff -rq --no-dereference "$PROBE" "$MNT/boot" \
        || die "Bản chép /boot không khớp bản gốc. Phân vùng /boot cũ chưa bị đổi."
    info "Đã chép và kiểm tra ${BOOT_USED} MiB."
    umount "$PROBE"

    # ----------------------------------------------------------------------
    step "Bước 7: Biến $BOOT_DEV thành ESP"
    wipefs -a "$BOOT_DEV" >/dev/null || die "wipefs lỗi."
    mkfs.vfat -F32 -n EFI "$BOOT_DEV" || die "mkfs.vfat lỗi. /boot đã nằm trên root, nhưng fstab chưa sửa: ĐỪNG reboot."
    if [ "$PT" = "gpt" ]; then
        NEWTYPE="$ESP_GUID"
    else
        NEWTYPE="ef"
    fi
    # Đĩa đang bận (root LV đang mount) nên sfdisk có thể báo không re-read được; kiểm tra bằng cách đọc lại
    sfdisk --part-type "$DISK" "$BOOT_N" "$NEWTYPE" >/dev/null 2>&1
    CURTYPE=$(sfdisk --part-type "$DISK" "$BOOT_N" 2>/dev/null | tr 'A-F' 'a-f')
    [ "$CURTYPE" = "$NEWTYPE" ] || die "Không đổi được type phân vùng $BOOT_N sang $NEWTYPE (đang là $CURTYPE)."
    udevadm settle
    ESP_UUID=$(blkid -s UUID -o value "$BOOT_DEV")
    [ -n "$ESP_UUID" ] || die "Không đọc được UUID của ESP $BOOT_DEV"
    info "ESP: $BOOT_DEV  UUID=$ESP_UUID  type=$CURTYPE"

    info "Cập nhật fstab"
    cp -a "$MNT/etc/fstab" "$MNT/etc/fstab.bak.$(date +%s)"
    awk '!/^[[:space:]]*#/ && $2=="/boot" {print "#" $0; next} {print}' "$MNT/etc/fstab" > "$MNT/etc/fstab.new" \
        && mv -f "$MNT/etc/fstab.new" "$MNT/etc/fstab"
    [ -n "$(tail -c1 "$MNT/etc/fstab")" ] && echo >> "$MNT/etc/fstab"
    echo "UUID=$ESP_UUID  /boot/efi  vfat  umask=0077,shortname=winnt,nofail  0 0" >> "$MNT/etc/fstab"
    grep -E '[[:space:]]/boot(/efi)?[[:space:]]' "$MNT/etc/fstab"

    mkdir -p "$MNT/boot/efi"
    mount "$BOOT_DEV" "$MNT/boot/efi" || die "Không mount được ESP"
fi

# --------------------------------------------------------------------------
step "Bước 8: Cấu hình trong chroot (GRUB UEFI, virtio, mạng)"
chroot "$MNT" /bin/bash /root/c7-efi-chroot.sh configure "$VER" "$FIX_NET"
rc=$?
rm -f "$MNT/root/c7-efi-chroot.sh"
if [ "$rc" -ne 0 ]; then
    if [ "$MODE" = "bios" ]; then
        die "Bước trong chroot bị lỗi (mã $rc). /boot đã chuyển vào root và $BOOT_DEV đã là ESP, ĐỪNG reboot khi chưa sửa xong."
    fi
    die "Bước trong chroot bị lỗi (mã $rc). Phân vùng không bị đổi; xem thông báo phía trên."
fi

# --------------------------------------------------------------------------
step "Bước 9: Dọn dẹp"
cleanup
trap - EXIT
sync

echo
echo "${G}${B}HOÀN TẤT.${N}"
echo "Việc còn lại:"
echo "  1. Tháo ISO / thoát rescue mode, rồi reboot (VM boot UEFI)."
echo "  2. Lần boot đầu SELinux relabel toàn bộ, máy tự reboot thêm 1 lần, có thể mất vài phút."
echo "  3. Sau khi boot, kiểm tra:"
echo "       [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS"
echo "       lsblk -f; ip a"
if [ "$MODE" = "bios" ]; then
    echo "  Lưu ý: VM giờ CHỈ boot được UEFI. /boot nằm trên root, fstab cũ ở /etc/fstab.bak.*"
fi
