#!/bin/bash
# ==========================================================================
# convert-to-uefi.sh  (v2)
# Chuyển hệ thống Ubuntu/Debian từ MBR (legacy) sang GPT + ESP để boot UEFI.
# Hỗ trợ: root là ext2/3/4 trên phân vùng thường, hoặc trên LVM.
# Chạy trong Ubuntu Desktop Live (có mạng), bằng quyền root:
#
#     sudo bash convert-to-uefi.sh            # mặc định ổ /dev/vda
#     sudo bash convert-to-uefi.sh /dev/sda   # chỉ định ổ khác
#
# Biến môi trường tùy chọn:
#     ROOT_DEV=/dev/vda1   bỏ qua bước tự dò phân vùng root
#                          (chạy: sudo ROOT_DEV=... bash convert-to-uefi.sh)
#
# Khi đĩa không còn chỗ trống cho ESP, script đề nghị tự thu nhỏ phân vùng
# cuối (chỉ khi đó là ext2/3/4 hoặc PV của LVM), có hỏi xác nhận.
# ==========================================================================
set -u

DISK="${1:-/dev/vda}"
ESP_MAX_MIB=512
ESP_MIN_MIB=100
SHRINK_MIB=540          # dung lượng giải phóng khi cần thu nhỏ (ESP + dự phòng GPT)
MNT=/mnt
PROBE=/tmp/probe-root
ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
BIOSBOOT_GUID="21686148-6449-6e6f-744e-656564454649"

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

# ---------------------------- hàm tiện ích --------------------------------
list_esp() {
    lsblk -nrpo PATH,PARTTYPE "$DISK" 2>/dev/null \
        | awk -v g="$ESP_GUID" 'tolower($2)==g {print $1}' | sort
}
part_start() { cat "/sys/class/block/$(basename "$1")/start" 2>/dev/null; }
part_num()   { cat "/sys/class/block/$(basename "$1")/partition" 2>/dev/null; }
part_size()  { blockdev --getsz "$1"; }

# Sector cuối (không tính) lớn nhất của các phân vùng trên đĩa
disk_last_end() {
    local m=0 p s z e
    while read -r p; do
        s=$(part_start "$p"); z=$(part_size "$p")
        [ -n "$s" ] && [ -n "$z" ] || continue
        e=$((s + z))
        [ "$e" -gt "$m" ] && m=$e
    done < <(lsblk -nrpo PATH,TYPE "$DISK" | awk '$2=="part"{print $1}')
    echo "$m"
}

# Vùng trống liền kề lớn nhất (đơn vị sector)
largest_free_sectors() {
    parted -ms "$DISK" unit s print free 2>/dev/null \
        | awk -F: '$NF=="free;" {v=$4; sub("s","",v); if (v+0>m) m=v+0} END{print m+0}'
}

# Đổi kích thước phân vùng (giữ nguyên start, type, uuid): $1=phân vùng, $2=số sector mới
shrink_partition() {
    local part=$1 newsz=$2 n s t u script
    n=$(part_num "$part"); s=$(part_start "$part")
    t=$(sfdisk --part-type "$DISK" "$n" 2>/dev/null)
    [ -n "$n" ] && [ -n "$s" ] && [ -n "$t" ] || return 1
    script="start=$s, size=$newsz, type=$t"
    if [ "$PT" = "gpt" ]; then
        u=$(sfdisk --part-uuid "$DISK" "$n" 2>/dev/null)
        [ -n "$u" ] && script="$script, uuid=$u"
    fi
    echo "$script" | sfdisk --wipe-partitions never --no-reread -N "$n" "$DISK" >/dev/null || return 1
    partprobe "$DISK" 2>/dev/null; udevadm settle; sleep 1
    [ "$(part_size "$part")" -eq "$newsz" ]
}

# Tự thu nhỏ phân vùng cuối chứa root (ext2/3/4 thường hoặc PV của LVM)
do_shrink() {
    local mode target vg parent n s z e last fstype new_sect
    local bs minblk min_mib fs_mib vg_free need red pv_mib new_pv_mib a

    if lvs "$ROOT_DEV" >/dev/null 2>&1; then
        mode=lvm
        vg=$(lvs --noheadings -o vg_name "$ROOT_DEV" | xargs)
        target=$(pvs --noheadings -o pv_name --select "vg_name=$vg" 2>/dev/null | xargs)
        if [ "$(wc -w <<<"$target")" -ne 1 ]; then
            warn "VG $vg có nhiều PV, script không tự thu nhỏ trường hợp này."; return 1
        fi
    else
        mode=std; target="$ROOT_DEV"
    fi

    parent=$(lsblk -nrpo PKNAME "$target" 2>/dev/null | head -n1)
    if [ "$(readlink -f "$parent")" != "$(readlink -f "$DISK")" ]; then
        warn "$target không nằm trên $DISK."; return 1
    fi

    n=$(part_num "$target"); s=$(part_start "$target"); z=$(part_size "$target"); e=$((s + z))
    last=$(disk_last_end)
    if [ "$e" -ne "$last" ]; then
        warn "$target không phải phân vùng cuối đĩa (có phân vùng khác nằm sau, ví dụ swap)."
        warn "Script không tự thu nhỏ trường hợp này."; return 1
    fi
    if [ "$PT" = "dos" ] && [ "${n:-0}" -gt 4 ]; then
        warn "$target là phân vùng logical (extended), script không xử lý."; return 1
    fi

    fstype=$(blkid -s TYPE -o value "$ROOT_DEV")
    case "$fstype" in
        ext2|ext3|ext4) ;;
        *) warn "Root là '$fstype', chỉ tự thu nhỏ được ext2/3/4."; return 1 ;;
    esac

    new_sect=$(( (z - SHRINK_MIB * 2048) / 2048 * 2048 ))
    if [ "$new_sect" -le $((2048 * 1024)) ]; then
        warn "Phân vùng quá nhỏ để thu nhỏ thêm."; return 1
    fi

    echo
    echo "${Y}${B}KẾ HOẠCH THU NHỎ${N}"
    echo "  Kiểu      : $mode ($fstype)"
    echo "  Phân vùng : $target  ($((z / 2048)) MiB -> $((new_sect / 2048)) MiB)"
    echo "  Mục đích  : giải phóng ~${SHRINK_MIB} MiB cuối đĩa cho ESP"
    echo "${Y}Thao tác này thay đổi filesystem/phân vùng thật. Phải có snapshot trước.${N}"
    read -rp "Gõ SHRINK để xác nhận: " a
    [ "$a" = "SHRINK" ] || return 1

    if [ "$mode" = "std" ]; then
        info "Kiểm tra filesystem (e2fsck)"
        e2fsck -f -p "$ROOT_DEV"; local rc=$?
        [ "$rc" -le 1 ] || { warn "e2fsck báo lỗi (mã $rc). Dừng."; return 1; }

        bs=$(tune2fs -l "$ROOT_DEV" | awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}')
        minblk=$(resize2fs -P "$ROOT_DEV" 2>/dev/null | awk -F: '/minimum size/{gsub(/ /,"",$2);print $2}')
        case "$bs$minblk" in (*[!0-9]*|"") warn "Không đọc được kích thước tối thiểu của filesystem."; return 1 ;; esac
        min_mib=$(( minblk * bs / 1048576 + 1 ))
        fs_mib=$(( new_sect / 2048 - 8 ))
        if [ "$fs_mib" -le $((min_mib + 512)) ]; then
            warn "Dữ liệu trong filesystem quá nhiều (tối thiểu ${min_mib} MiB), không thu nhỏ an toàn được."
            return 1
        fi
        info "Thu nhỏ filesystem xuống ${fs_mib} MiB"
        resize2fs "$ROOT_DEV" "${fs_mib}M" || { warn "resize2fs lỗi. Partition chưa bị đổi."; return 1; }

        info "Thu nhỏ phân vùng $target"
        shrink_partition "$target" "$new_sect" || { warn "Đổi kích thước phân vùng lỗi!"; return 1; }
        resize2fs "$ROOT_DEV" >/dev/null 2>&1      # nở filesystem lấp đầy phân vùng mới
    else
        vgchange -ay "$vg" >/dev/null 2>&1
        vg_free=$(vgs --noheadings --units m --nosuffix -o vg_free "$vg" | awk '{printf "%d",$1}')
        need=$((SHRINK_MIB + 16))
        if [ "$vg_free" -lt "$need" ]; then
            red=$((need - vg_free + 64))
            info "VG chỉ trống ${vg_free} MiB, thu nhỏ LV root thêm ${red} MiB"
            lvreduce -r -y -L "-${red}M" "$ROOT_DEV" \
                || { warn "lvreduce lỗi (thường do dữ liệu quá đầy). Chưa đổi phân vùng."; return 1; }
        fi
        new_pv_mib=$(( new_sect / 2048 - 2 ))
        info "Thu nhỏ PV $target xuống ${new_pv_mib} MiB"
        pvresize -y --setphysicalvolumesize "${new_pv_mib}m" "$target" \
            || { warn "pvresize lỗi (có extent nằm ở cuối PV, cần pvmove thủ công). Chưa đổi phân vùng."; return 1; }
        vgchange -an "$vg" >/dev/null 2>&1 || { warn "Không tắt được VG $vg. Dừng."; return 1; }
        info "Thu nhỏ phân vùng $target"
        shrink_partition "$target" "$new_sect" || { warn "Đổi kích thước phân vùng lỗi!"; return 1; }
        vgchange -ay "$vg" >/dev/null 2>&1
        pvresize -y "$target" >/dev/null 2>&1
    fi
    info "Đã giải phóng vùng trống ở cuối đĩa."
    return 0
}

# --------------------------------------------------------------------------
step "Bước 0: Kiểm tra ban đầu"
[ "$(id -u)" -eq 0 ] || die "Cần quyền root. Chạy: sudo bash $0"
[ -b "$DISK" ] || die "Không tìm thấy ổ đĩa $DISK (dùng: sudo bash $0 /dev/xxx)"

if [ -d /sys/firmware/efi ]; then
    info "Live CD đang boot ở chế độ UEFI."
else
    warn "Live CD đang boot ở chế độ BIOS (SeaBIOS). VM này dùng Legacy BIOS."
    warn "Script sẽ cài bootloader cho CẢ BIOS và UEFI, nên VM boot được ở cả hai chế độ."
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
need_pkgs=()
command -v sgdisk    >/dev/null || need_pkgs+=(gdisk)
command -v mkfs.vfat >/dev/null || need_pkgs+=(dosfstools)
command -v vgchange  >/dev/null || need_pkgs+=(lvm2)
command -v partprobe >/dev/null || need_pkgs+=(parted)
command -v sfdisk    >/dev/null || need_pkgs+=(fdisk)
command -v resize2fs >/dev/null || need_pkgs+=(e2fsprogs)
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
step "Bước 3: Dò phân vùng root của hệ thống"
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
        die "Không tìm thấy phân vùng root. Chạy lại: sudo ROOT_DEV=/dev/xxx bash $0"
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
step "Bước 4: Kiểm tra chỗ trống, thu nhỏ nếu cần"
if [ "$PT" = "gpt" ]; then
    sgdisk -e "$DISK" >/dev/null 2>&1       # đưa backup GPT về cuối đĩa
    partprobe "$DISK" 2>/dev/null; udevadm settle
fi

NEED_SHRINK=0
if [ "$PT" = "dos" ]; then
    DISK_SECT=$(blockdev --getsz "$DISK")
    TAIL_FREE=$((DISK_SECT - $(disk_last_end)))
    if [ "$TAIL_FREE" -lt 40 ]; then
        warn "Cuối đĩa MBR không còn chỗ cho bảng GPT dự phòng (còn ${TAIL_FREE} sector)."
        NEED_SHRINK=1
    fi
fi
if [ -z "$(list_esp)" ]; then
    GAP_MIB=$(( $(largest_free_sectors) / 2048 ))
    info "Vùng trống liền kề lớn nhất: ${GAP_MIB} MiB (cần >= $((ESP_MIN_MIB + 2)) MiB cho ESP)"
    [ "$GAP_MIB" -lt $((ESP_MIN_MIB + 2)) ] && NEED_SHRINK=1
fi

if [ "$NEED_SHRINK" -eq 1 ]; then
    warn "Đĩa không đủ chỗ trống. Có thể tự thu nhỏ phân vùng cuối, hoặc bạn extend volume trên OpenStack."
    do_shrink || die "Không thu nhỏ tự động được. Hãy extend volume thêm ~1 GiB trên OpenStack (hoặc tự thu nhỏ thủ công), rồi chạy lại. Chưa có thay đổi nào chưa hoàn tất ngoài những bước đã báo ở trên."
else
    info "Đủ chỗ trống, không cần thu nhỏ."
fi

# --------------------------------------------------------------------------
step "Bước 5: Chuyển MBR sang GPT, đưa backup GPT về cuối đĩa"
if [ "$PT" = "dos" ]; then
    sgdisk -g "$DISK" || die "sgdisk -g lỗi."
fi
sgdisk -e "$DISK" || die "sgdisk -e lỗi."
partprobe "$DISK"; udevadm settle; sleep 1
sgdisk -p "$DISK"

# --------------------------------------------------------------------------
step "Bước 6: Tạo và format phân vùng ESP"
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
        die "Không đủ vùng trống cho ESP (cần >= ${ESP_MIN_MIB} MiB). Extend volume thêm ~1 GiB rồi chạy lại."
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
step "Bước 6b: Phân vùng bios_grub (để boot được cả Legacy BIOS)"
BIOS_DISK=""
BIOSBOOT_DEV=$(lsblk -nrpo PATH,PARTTYPE "$DISK" 2>/dev/null \
    | awk -v g="$BIOSBOOT_GUID" 'tolower($2)==g {print $1}' | head -n1)
if [ -n "$BIOSBOOT_DEV" ]; then
    info "Đã có bios_grub: $BIOSBOOT_DEV"
    BIOS_DISK="$DISK"
else
    MIN_START=$(lsblk -nrpo PATH,TYPE "$DISK" | awk '$2=="part"{print $1}' \
        | while read -r p; do part_start "$p"; done | sort -n | head -n1)
    if [ -n "$MIN_START" ] && [ "$MIN_START" -ge 2048 ]; then
        if sgdisk -a 1 -n 0:34:2047 -t 0:ef02 -c 0:"BIOS boot" "$DISK"; then
            partprobe "$DISK" 2>/dev/null; udevadm settle; sleep 1
            info "Đã tạo bios_grub ở sector 34-2047"
            BIOS_DISK="$DISK"
        else
            warn "Không tạo được bios_grub. VM sẽ CHỈ boot được bằng UEFI."
        fi
    else
        warn "Phân vùng đầu bắt đầu ở sector ${MIN_START:-?} (< 2048), không có chỗ cho bios_grub."
        warn "VM sẽ CHỈ boot được bằng UEFI."
    fi
fi

# --------------------------------------------------------------------------
step "Bước 7: Mount hệ thống"
vgchange -ay >/dev/null 2>&1
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
step "Bước 8: Cấu hình mạng (netplan)"
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
REMOVE_AZURE=0
if ls "$MNT"/boot/vmlinuz-*azure* >/dev/null 2>&1; then
    step "Bước 8b: Kernel Azure"
    ls "$MNT"/boot/vmlinuz-*
    echo "Phát hiện kernel azure (tối ưu cho Hyper-V). Trên KVM/OpenStack nên dùng kernel generic."
    echo "Nếu chưa có kernel generic, script sẽ cài linux-image-generic trước rồi mới gỡ kernel azure."
    read -rp "Gỡ kernel azure và dùng kernel generic? (Y/n): " kans
    case "$kans" in n|N) ;; *) REMOVE_AZURE=1 ;; esac
fi

# --------------------------------------------------------------------------
step "Bước 9: Chạy cấu hình trong chroot (cài GRUB UEFI, virtio, fstab)"
cat > "$MNT/root/fix-uefi-chroot.sh" <<'CHROOT_EOF'
#!/bin/bash
set -e
ESP_UUID="$1"
FIX_NET="$2"
ESP_DEV="${3:-}"
REMOVE_AZURE="${4:-0}"
BIOS_DISK="${5:-}"
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

# Ubuntu 24.04 có thể có dòng /var/lib/grub/esp trỏ tới /dev/disk/by-id/...-part1 của đĩa cũ.
# Gói grub-efi-amd64-signed mount dòng này khi cài, nên phải trỏ về ESP mới.
if grep -q '[[:space:]]/var/lib/grub/esp[[:space:]]' /etc/fstab; then
    echo "[chroot] Sửa dòng /var/lib/grub/esp trong fstab"
    sed -i -E "s|^[^#[:space:]]+([[:space:]]+/var/lib/grub/esp[[:space:]])|UUID=$ESP_UUID\1|" /etc/fstab
fi

# Gói grub-efi-amd64-signed lấy ESP từ debconf (grub-efi/install_devices), giá trị cũ
# trỏ tới /dev/disk/by-id/...-part1 của đĩa gốc nên mount lỗi. Trỏ lại về ESP mới.
ESP_LINK="/dev/disk/by-uuid/$ESP_UUID"
[ -e "$ESP_LINK" ] || ESP_LINK="$ESP_DEV"
echo "[chroot] Đặt debconf grub-efi/install_devices = $ESP_LINK"
echo "grub-efi-amd64 grub-efi/install_devices multiselect $ESP_LINK" | debconf-set-selections
echo "grub-efi-amd64 grub-efi/install_devices_empty boolean false" | debconf-set-selections

echo "[chroot] Cài GRUB UEFI"
dpkg --configure -a || true
apt-get update
apt-get install -y -o Dpkg::Options::=--force-confold \
    grub-efi-amd64 grub-efi-amd64-signed shim-signed efibootmgr

if [ "$REMOVE_AZURE" = "1" ]; then
    echo "[chroot] Chuyển từ kernel azure sang kernel generic"
    if ! ls /boot/vmlinuz-*-generic >/dev/null 2>&1; then
        echo "[chroot] Chưa có kernel generic, cài linux-image-generic"
        apt-get install -y linux-image-generic
    fi
    if ! ls /boot/vmlinuz-*-generic >/dev/null 2>&1; then
        echo "[chroot] LỖI: không có kernel generic, không gỡ kernel azure."; exit 1
    fi
    AZ_PKGS=$(dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 2>/dev/null \
        | awk '$2 ~ /^ii/ && $1 ~ /^linux-/ && $1 ~ /azure/ {print $1}')
    if [ -n "$AZ_PKGS" ]; then
        echo "[chroot] Gỡ: $AZ_PKGS"
        # shellcheck disable=SC2086
        apt-get purge -y $AZ_PKGS
    fi
fi

echo "[chroot] Sửa cấu hình GRUB của image cloud"
mkdir -p /root/grub-backup
cp -a /etc/default/grub /root/grub-backup/grub.default 2>/dev/null || true
cp -a /etc/default/grub.d/. /root/grub-backup/grub.d/ 2>/dev/null || true
mkdir -p /etc/default/grub.d
# PARTUUID đã đổi khi chuyển MBR -> GPT: bỏ ép root theo PARTUUID cũ
rm -f /etc/default/grub.d/40-force-partuuid.cfg
sed -i -E 's/^(GRUB_FORCE_PARTUUID=)/#\1/' /etc/default/grub /etc/default/grub.d/*.cfg 2>/dev/null || true
# Hiện menu, đưa output ra cả màn hình VNC (tty1) và cổng serial
cat > /etc/default/grub.d/99-cmc-cloud.cfg <<'GRUBEOF'
GRUB_TIMEOUT=5
GRUB_TIMEOUT_STYLE=menu
GRUB_RECORDFAIL_TIMEOUT=5
GRUB_TERMINAL="console serial"
GRUB_CMDLINE_LINUX_DEFAULT="console=ttyS0,115200 console=tty1"
GRUBEOF

echo "[chroot] Thêm driver virtio vào initramfs"
for m in virtio_blk virtio_scsi virtio_net virtio_pci; do
    grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
done
update-initramfs -u -k all

echo "[chroot] grub-install"
# --no-nvram: luôn chép đủ file vào ESP, không phụ thuộc việc ghi biến EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu --no-nvram --recheck
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram --recheck
# Thử thêm entry NVRAM nếu live CD boot UEFI (không bắt buộc)
if [ -d /sys/firmware/efi/efivars ]; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu >/dev/null 2>&1 || true
fi
if [ -n "$BIOS_DISK" ]; then
    echo "[chroot] Cài thêm GRUB legacy (BIOS) lên $BIOS_DISK"
    # grub-pc-bin không xung đột với grub-efi-amd64 (khác với gói grub-pc)
    apt-get install -y grub-pc-bin
    grub-install --target=i386-pc --recheck "$BIOS_DISK"
fi
update-grub

echo "[chroot] Kiểm tra cấu hình boot"
if grep -q 'root=PARTUUID=' /boot/grub/grub.cfg; then
    echo "[chroot] LỖI: grub.cfg vẫn còn root=PARTUUID (sẽ không boot được):"
    grep -n 'root=PARTUUID=' /boot/grub/grub.cfg | head -3
    exit 1
fi
echo "[chroot] Tham số root trong grub.cfg:"
grep -o 'root=[^ ]*' /boot/grub/grub.cfg | sort -u | head -3
echo "[chroot] Kernel còn lại:"
ls /boot/vmlinuz-*

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
ls -R /boot/efi/EFI
for f in /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/ubuntu/grub.cfg; do
    if [ ! -f "$f" ]; then
        echo "[chroot] LỖI: thiếu $f"; exit 1
    fi
done
CHROOT_EOF
chmod +x "$MNT/root/fix-uefi-chroot.sh"

chroot "$MNT" /bin/bash /root/fix-uefi-chroot.sh "$ESP_UUID" "$FIX_NET" "$ESP_DEV" "$REMOVE_AZURE" "$BIOS_DISK"
rc=$?
rm -f "$MNT/root/fix-uefi-chroot.sh"
[ "$rc" -eq 0 ] || die "Bước trong chroot bị lỗi (mã $rc). Xem thông báo phía trên. Bảng phân vùng đã được đổi sang GPT, ĐỪNG reboot khi chưa sửa xong."

# --------------------------------------------------------------------------
step "Bước 10: Dọn dẹp"
cleanup
trap - EXIT
sync

echo
echo "${G}${B}HOÀN TẤT.${N}"
echo "Việc còn lại:"
echo "  1. Tháo ISO Ubuntu live khỏi instance."
if [ -n "$BIOS_DISK" ]; then
    echo "  2. Reboot. Đĩa boot được cả Legacy BIOS (SeaBIOS) lẫn UEFI."
    echo "     Sau mỗi lần nâng cấp gói GRUB, nên chạy: sudo grub-install --target=i386-pc $BIOS_DISK"
else
    echo "  2. Đĩa CHỈ boot được UEFI: VM phải chạy firmware UEFI (hw_firmware_type=uefi), rồi reboot."
fi
echo "  3. Sau khi boot, kiểm tra:"
echo "       [ -d /sys/firmware/efi ] && echo UEFI || echo BIOS"
echo "       lsblk -f"