#!/bin/bash
# ==========================================================================
# fix.sh  (v2)
# Script điều phối:
#   1. Khám sức khỏe VM (chỉ đọc): firmware, đĩa, phân vùng, OS, kernel, virtio,
#      GRUB, ESP, fstab, mạng, dấu vết Hyper-V/Azure/VMware, kèm danh sách vấn đề.
#      Báo cáo lưu ở /tmp/vm-health-*.txt để chụp/gửi.
#   2. Chạy đúng script sửa boot theo hệ điều hành:
#        - Ubuntu/Debian -> convert.sh
#        - CentOS 7      -> convert-centos7.sh
# Chỉ ĐỌC đĩa (mount ro), việc ghi đĩa do script con làm (có hỏi xác nhận).
# Chạy trong Ubuntu Live (có mạng), bằng quyền root:
#
#     sudo bash fix.sh                # khám rồi sửa, tự chọn đĩa
#     sudo bash fix.sh --check        # CHỈ khám, không sửa
#     sudo bash fix.sh /dev/vdb       # chỉ định đĩa (có thể kèm --check)
#
# Nếu convert.sh / convert-centos7.sh không nằm cùng thư mục, script tự tải từ GitHub.
# Biến môi trường tùy chọn:
#     BRANCH=test-centos7   nhánh GitHub để tải script con (mặc định main)
# ==========================================================================
# Script dùng cú pháp bash; nếu bị gọi bằng "sh fix.sh" (dash) thì tự chạy lại bằng bash
if [ -z "${BASH_VERSION:-}" ]; then
    [ -f "$0" ] && exec bash "$0" "$@"
    echo "Script cần bash, hãy chạy: sudo bash fix.sh" >&2; exit 1
fi
set -u

REPO_RAW=https://raw.githubusercontent.com/bachntnhg/cmcfixboot
BRANCH="${BRANCH:-main}"
PROBE=/tmp/probe-os
REPORT="/tmp/vm-health-$(date +%Y%m%d-%H%M%S).txt"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[x] $*${N}" >&2; exit 1; }
step() { echo; echo "${B}=== $* ===${N}"; }

cleanup() {
    mountpoint -q "$PROBE" 2>/dev/null && { umount -R "$PROBE" 2>/dev/null || umount -Rl "$PROBE" 2>/dev/null; }
}
trap cleanup EXIT

CHECK_ONLY=0
DISK=""
for a in "$@"; do
    case "$a" in
        --check|-c) CHECK_ONLY=1 ;;
        /dev/*)     DISK="$a" ;;
        *)          die "Tham số không hợp lệ: $a (dùng: sudo bash $0 [--check] [/dev/xxx])" ;;
    esac
done

# Đọc một khóa dạng KEY=value (os-release, ifcfg, selinux/config): $1=file, $2=khóa
osr_get() { grep -E "^$2=" "$1" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'\'; }

# Nhận diện OS trong thư mục đã mount: in ra "ID|ID_LIKE|VERSION_ID|tên đầy đủ"
detect_os() {
    local m=$1 f id like ver name
    f="$m/etc/os-release"
    # os-release là link tuyệt đối thì phải đọc trong đĩa VM, không phải live CD
    case "$(readlink "$f" 2>/dev/null)" in /*) f="$m/usr/lib/os-release" ;; esac
    if [ -f "$f" ]; then
        id=$(osr_get "$f" ID); like=$(osr_get "$f" ID_LIKE)
        ver=$(osr_get "$f" VERSION_ID); name=$(osr_get "$f" PRETTY_NAME)
    elif [ -f "$m/etc/centos-release" ]; then
        id=centos; like="rhel fedora"; name=$(head -n1 "$m/etc/centos-release")
        ver=$(grep -oE '[0-9]+' <<<"$name" | head -n1)
    elif [ -f "$m/etc/redhat-release" ]; then
        id=rhel; like=fedora; name=$(head -n1 "$m/etc/redhat-release")
        ver=$(grep -oE '[0-9]+' <<<"$name" | head -n1)
    elif [ -f "$m/etc/debian_version" ]; then
        id=debian; like=""; ver=$(cut -d. -f1 "$m/etc/debian_version"); name="Debian $ver"
    else
        return 1
    fi
    echo "${id:-?}|${like:-}|${ver:-?}|${name:-$id}"
}

mount_ro() { mount -o ro "$1" "$2" 2>/dev/null || mount -o ro,norecovery "$1" "$2" 2>/dev/null; }

# Thiết bị theo cột 1 của fstab; in rỗng nếu không tồn tại
spec_dev() {
    case "$1" in
        UUID=*)     blkid -U "${1#UUID=}" 2>/dev/null ;;
        LABEL=*)    blkid -L "${1#LABEL=}" 2>/dev/null ;;
        PARTUUID=*) blkid -t "PARTUUID=${1#PARTUUID=}" -o device 2>/dev/null | head -n1 ;;
        /dev/*)     [ -b "$1" ] && echo "$1" ;;
    esac
}

# Chọn script sửa theo OS: đặt TARGET (rỗng nếu chưa hỗ trợ) và TARGET_NOTE
pick_target() {
    TARGET=""; TARGET_NOTE=""
    case " $OS_ID $OS_LIKE " in
        *" ubuntu "*|*" debian "*)
            TARGET=convert.sh ;;
        *" centos "*|*" rhel "*)
            if [ "$OS_ID" = "centos" ] && [ "${OS_VER%%.*}" = "7" ]; then
                TARGET=convert-centos7.sh
            else
                TARGET_NOTE="$OS_NAME chưa có script (mới hỗ trợ CentOS 7)"
            fi ;;
        *)
            TARGET_NOTE="$OS_NAME chưa có script" ;;
    esac
}

# ---------------------------- khám sức khỏe -------------------------------
section() { echo; echo "${B}--- $* ---${N}"; }
# Căn cột theo số ký tự (printf %-Ns đếm byte, lệch với chữ có dấu)
kv() {
    local k="$1:" pad
    pad=$((23 - ${#k})); [ "$pad" -ge 1 ] || pad=1
    printf '  %s%*s%s\n' "$k" "$pad" "" "$2"
}
issue()   { ISSUES+=("$*"); }

part_role() {
    case "$(tr 'A-F' 'a-f' <<<"$1")" in
        c12a7328-f81f-11d2-ba4b-00a0c93ec93b|0xef) echo "ESP" ;;
        21686148-6449-6e6f-744e-656564454649)      echo "bios_grub" ;;
        e6d6d379-f507-44c2-a23c-238f2a3df928|0x8e) echo "LVM" ;;
        0657fd6d-a4ab-43c4-84e5-0933c84b4f4f|0x82) echo "swap" ;;
        0x5|0xf|0x85)                              echo "extended" ;;
    esac
}

# Mã boot trong 440 byte đầu đĩa
mbr_code() {
    if dd if="$1" bs=440 count=1 2>/dev/null | grep -aq GRUB; then
        echo "GRUB"
    elif [ "$(dd if="$1" bs=440 count=1 2>/dev/null | tr -d '\000' | wc -c)" -eq 0 ]; then
        echo "trống"
    else
        echo "khác (không phải GRUB)"
    fi
}

# Trạng thái virtio_blk của kernel $2 trong root đã mount $1; mã trả về 0=có, 1=thiếu, 2=không rõ
virtio_state() {
    local m=$1 v=$2 f img="" list
    if grep -q 'virtio_blk' "$m/lib/modules/$v/modules.builtin" 2>/dev/null; then
        echo "có sẵn trong kernel"; return 0
    fi
    for f in "initramfs-$v.img" "initrd.img-$v" "initrd-$v"; do
        [ -f "$m/boot/$f" ] && { img="$m/boot/$f"; break; }
    done
    [ -n "$img" ] || { echo "KHÔNG có file initramfs"; return 1; }
    command -v lsinitramfs >/dev/null || { echo "không kiểm tra được (thiếu lsinitramfs)"; return 2; }
    list=$(lsinitramfs "$img" 2>/dev/null)
    # Không đọc được (nén lạ...) thì không kết luận thiếu
    [ -n "$list" ] || { echo "không đọc được ${img#$m}"; return 2; }
    if grep -q 'virtio_blk' <<<"$list"; then
        echo "có trong initramfs"; return 0
    fi
    echo "THIẾU trong initramfs ${img#$m}"; return 1
}

has_unit() {
    local d
    for d in lib usr/lib etc; do
        [ -e "$PROBE/$d/systemd/system/$1" ] && return 0
    done
    return 1
}

report_disk() {
    local p t fs pty role ptlist
    section "Môi trường (instance đang chạy live CD)"
    if [ -d /sys/firmware/efi ]; then
        FW=uefi
        local sb
        sb=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | xargs)
        case "$sb" in 1) sb="BẬT" ;; 0) sb="tắt" ;; *) sb="không rõ" ;; esac
        kv "Firmware" "UEFI (Secure Boot: $sb)"
    else
        FW=bios
        kv "Firmware" "BIOS (SeaBIOS)"
    fi
    kv "Hypervisor" "$(systemd-detect-virt 2>/dev/null || echo "?")"
    kv "Live CD" "$(osr_get /etc/os-release PRETTY_NAME), kernel $(uname -r)"

    section "Đĩa $DISK"
    PT=$(blkid -p -o value -s PTTYPE "$DISK" 2>/dev/null)
    MBR=$(mbr_code "$DISK")
    kv "Dung lượng" "$(lsblk -dnro SIZE "$DISK")"
    kv "Bảng phân vùng" "${PT:-KHÔNG CÓ}"
    kv "Mã boot ở MBR" "$MBR"
    HAS_ESP=0; HAS_BIOSGRUB=0; ANY_FS=0
    echo "  THIẾT BỊ                   SIZE    FS           VAI TRÒ"
    while read -r p t; do
        fs=$(blkid -p -s TYPE -o value "$p" 2>/dev/null)
        role=""
        if [ "$t" = "part" ]; then
            pty=$(blkid -p -s PART_ENTRY_TYPE -o value "$p" 2>/dev/null)
            role=$(part_role "$pty")
            [ -n "$role" ] || role="type ${pty:-?}"
            [ "$role" = "ESP" ] && HAS_ESP=1
            [ "$role" = "bios_grub" ] && HAS_BIOSGRUB=1
        else
            role="LV"
        fi
        case "$fs" in ""|LVM2_member|swap) ;; *) ANY_FS=1 ;; esac
        printf '  %-26s %-7s %-12s %s\n' "$p" "$(lsblk -dnro SIZE "$p")" "${fs:--}" "$role"
    done < <(lsblk -nrpo PATH,TYPE "$DISK" | awk '$2=="part" || $2=="lvm"')
    [ "$ANY_FS" = "1" ] || issue "Không phân vùng/LV nào có filesystem nhận diện được: dữ liệu volume có thể chưa có (restore chưa xong) hoặc bị hỏng"
}

report_os() {
    local boot_spec esp_spec boot_dev esp_dev kernels kver vstate rc f cfgs roots r dev line
    section "Hệ điều hành"
    mount_ro "$ROOT_DEV" "$PROBE" || { kv "Root" "$ROOT_DEV: KHÔNG mount được"; issue "Không mount được root $ROOT_DEV"; return; }
    kv "Root" "$ROOT_DEV ($(findmnt -nro FSTYPE "$PROBE"))"
    kv "Hệ điều hành" "$OS_NAME"
    kv "ID / VERSION_ID" "$OS_ID${OS_LIKE:+ ($OS_LIKE)} / $OS_VER"

    boot_spec=$(awk '!/^[[:space:]]*#/ && $2=="/boot" {print $1; exit}' "$PROBE/etc/fstab")
    esp_spec=$(awk '!/^[[:space:]]*#/ && $2=="/boot/efi" {print $1; exit}' "$PROBE/etc/fstab")
    INSTALL=bios; [ -n "$esp_spec" ] && INSTALL=uefi
    kv "Kiểu cài đặt" "$([ "$INSTALL" = uefi ] && echo "UEFI (fstab có /boot/efi)" || echo "BIOS (fstab không có /boot/efi)")"
    if [ -n "$boot_spec" ]; then
        boot_dev=$(spec_dev "$boot_spec")
        if [ -n "$boot_dev" ] && mount_ro "$boot_dev" "$PROBE/boot"; then
            kv "/boot" "phân vùng riêng $boot_dev"
        else
            kv "/boot" "phân vùng riêng $boot_spec: KHÔNG mount được"
        fi
    else
        kv "/boot" "nằm trên root"
    fi
    ESP_OK=0
    if [ -n "$esp_spec" ]; then
        esp_dev=$(spec_dev "$esp_spec")
        if [ -n "$esp_dev" ] && mount_ro "$esp_dev" "$PROBE/boot/efi"; then
            ESP_OK=1
            kv "ESP" "$esp_dev, EFI/: $(ls "$PROBE/boot/efi/EFI" 2>/dev/null | xargs)"
            if [ -f "$PROBE/boot/efi/EFI/BOOT/BOOTX64.EFI" ]; then
                kv "EFI/BOOT/BOOTX64.EFI" "có"
            else
                kv "EFI/BOOT/BOOTX64.EFI" "KHÔNG có"
                [ "$FW" = "uefi" ] && issue "ESP thiếu EFI/BOOT/BOOTX64.EFI: entry NVRAM của nền tảng cũ không theo VM sang, firmware rơi vào UEFI Shell"
            fi
        else
            kv "ESP" "$esp_spec: KHÔNG mount được"
        fi
    fi

    # Kernel và virtio
    kernels=$(ls "$PROBE"/boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | grep -v rescue | sort -V)
    kver=$(tail -n1 <<<"$kernels")
    if [ -z "$kver" ]; then
        kv "Kernel" "KHÔNG tìm thấy /boot/vmlinuz-*"
        issue "Không thấy kernel trong /boot"
    else
        kv "Kernel" "$(wc -l <<<"$kernels") bản, mới nhất $kver"
        grep -q azure <<<"$kernels" && issue "Có kernel azure (tối ưu Hyper-V), trên KVM nên dùng kernel generic"
        vstate=$(virtio_state "$PROBE" "$kver"); rc=$?
        kv "virtio_blk ($kver)" "$vstate"
        [ "$rc" -eq 1 ] && issue "Kernel $kver thiếu virtio_blk trong initramfs: trên KVM sẽ không thấy đĩa (dracut timeout / initramfs prompt)"
    fi

    # GRUB
    cfgs=()
    for f in "$PROBE"/boot/grub/grub.cfg "$PROBE"/boot/grub2/grub.cfg "$PROBE"/boot/efi/EFI/*/grub.cfg; do
        [ -f "$f" ] && cfgs+=("$f")
    done
    if [ "${#cfgs[@]}" -eq 0 ]; then
        kv "grub.cfg" "KHÔNG có"
        issue "Không tìm thấy grub.cfg nào"
    fi
    for f in "${cfgs[@]}"; do
        roots=$(grep -E '^[[:space:]]*linux(efi|16)?[[:space:]]' "$f" | grep -o 'root=[^ ]*' | sort -u | head -3 | xargs)
        kv "${f#$PROBE}" "${roots:-(không có dòng linux, có thể là file chuyển tiếp)}"
        case "$f" in
            */EFI/*) grep -Eq '^[[:space:]]*linux16[[:space:]]' "$f" && issue "${f#$PROBE} là grub.cfg UEFI nhưng dùng linux16 (lệnh của BIOS)" ;;
        esac
        for r in $roots; do
            case "$r" in
                root=UUID=*) [ -n "$(spec_dev "UUID=${r#root=UUID=}")" ] || issue "${f#$PROBE}: $r không tồn tại trên đĩa" ;;
                root=PARTUUID=*) [ -n "$(spec_dev "PARTUUID=${r#root=PARTUUID=}")" ] || issue "${f#$PROBE}: $r không tồn tại (PARTUUID đổi khi restore/chuyển GPT)" ;;
                root=/dev/mapper/*) [ -b "${r#root=}" ] || issue "${f#$PROBE}: ${r#root=} không tồn tại" ;;
            esac
        done
    done
    [ -d "$PROBE/boot/loader/entries" ] && kv "BLS entries" "$(ls "$PROBE/boot/loader/entries" | wc -l) file"

    # fstab
    echo "  fstab:"
    local spec mp fst opts st
    while read -r spec mp fst opts _; do
        case "$fst" in proc|sysfs|tmpfs|devpts|nfs|nfs4|cifs|none) continue ;; esac
        case "$spec" in UUID=*|LABEL=*|PARTUUID=*|/dev/*) ;; *) continue ;; esac
        dev=$(spec_dev "$spec")
        if [ -n "$dev" ]; then
            st="OK"
        else
            st="KHÔNG TÌM THẤY"
            case ",$opts," in
                *,nofail,*) st="$st (nofail)" ;;
                *) issue "fstab: $mp trỏ tới $spec không tồn tại: boot sẽ vào emergency mode" ;;
            esac
        fi
        case "$spec" in
            /dev/sd*|/dev/vd*|/dev/hd*|/dev/xvd*|/dev/nvme*)
                issue "fstab dùng tên thiết bị $spec cho $mp (tên đĩa trên KVM có thể khác, nên dùng UUID)" ;;
        esac
        printf '    %-12s %-46s %s\n' "$mp" "$spec" "$st"
    done < <(grep -Ev '^[[:space:]]*(#|$)' "$PROBE/etc/fstab")

    # Mạng
    local nets=0 dev_ proto ip hw
    for f in "$PROBE"/etc/netplan/*.yaml; do
        [ -f "$f" ] || continue
        nets=1
        line=""
        grep -Eq 'dhcp4:[[:space:]]*(true|yes)' "$f" && line="$line DHCP"
        awk '/^[[:space:]]*(#|$)/ {next}
             { match($0, /^[[:space:]]*/); ind = RLENGTH }
             ns && ind <= nsind {ns = 0}
             /^[[:space:]]*nameservers:/ {ns = 1; nsind = ind; next}
             !ns && /^[[:space:]]*addresses:/ {found = 1}
             END {exit !found}' "$f" && { line="$line IP-tĩnh"; issue "Netplan ${f#$PROBE} có IP tĩnh: thường không khớp IP Neutron cấp"; }
        grep -Eq 'macaddress:|set-name:|hv_netvsc' "$f" && { line="$line gắn-MAC/driver-cũ"; issue "Netplan ${f#$PROBE} gắn MAC/tên card/driver cũ: card virtio mới sẽ không có mạng"; }
        kv "netplan" "${f#$PROBE}:${line:- (không rõ)}"
    done
    for f in "$PROBE"/etc/sysconfig/network-scripts/ifcfg-*; do
        [ -f "$f" ] || continue
        # network-scripts bỏ qua file sao lưu, không tính là cấu hình
        case "$f" in */ifcfg-lo|*.bak|*.orig|*.rpmnew|*.rpmorig|*.rpmsave|*~) continue ;; esac
        nets=1
        dev_=$(osr_get "$f" DEVICE); proto=$(osr_get "$f" BOOTPROTO)
        ip=$(osr_get "$f" IPADDR); hw=$(osr_get "$f" HWADDR)
        kv "${f##*/}" "DEVICE=${dev_:-?} BOOTPROTO=${proto:-?}${ip:+ IPADDR=$ip}${hw:+ HWADDR=$hw}"
        [ -n "$hw" ] && issue "${f##*/} gắn HWADDR cũ ($hw): card mới khác MAC sẽ không lên"
        case "$proto" in static|none) [ -n "$ip" ] && issue "${f##*/} dùng IP tĩnh $ip: thường không khớp IP Neutron cấp" ;; esac
    done
    if [ -f "$PROBE/etc/network/interfaces" ] && grep -q '^[[:space:]]*iface' "$PROBE/etc/network/interfaces"; then
        nets=1
        kv "interfaces" "$(grep -E '^[[:space:]]*iface' "$PROBE/etc/network/interfaces" | grep -v ' lo ' | awk '{print $2"="$4}' | xargs)"
    fi
    [ "$nets" = "1" ] || kv "Mạng" "không thấy netplan/ifcfg/interfaces"

    # Dấu vết nền tảng cũ
    local t=()
    { has_unit walinuxagent.service || has_unit waagent.service || [ -d "$PROBE/var/lib/waagent" ]; } && t+=("Azure-agent")
    { has_unit hv-kvp-daemon.service || has_unit hypervkvpd.service; } && t+=("Hyper-V-daemons")
    { has_unit vmtoolsd.service || has_unit open-vm-tools.service; } && t+=("VMware-tools")
    [ -e "$PROBE/etc/cloud/cloud.cfg" ] && t+=("cloud-init")
    has_unit qemu-guest-agent.service && t+=("qemu-guest-agent")
    kv "Phần mềm nền tảng" "${t[*]:-không có}"
    [ -f "$PROBE/etc/selinux/config" ] && kv "SELinux" "$(osr_get "$PROBE/etc/selinux/config" SELINUX)"

    umount -R "$PROBE" 2>/dev/null
}

report_verdict() {
    local i
    if [ "$FW" = "uefi" ]; then
        [ "$HAS_ESP" = "1" ] || issue "Instance boot UEFI nhưng đĩa KHÔNG có ESP: firmware rơi vào UEFI Shell"
    else
        if [ "$PT" = "gpt" ] && [ "$HAS_BIOSGRUB" = "0" ]; then
            issue "Instance boot BIOS nhưng đĩa GPT không có phân vùng bios_grub: GRUB BIOS không boot được"
        fi
        [ "$MBR" = "GRUB" ] || issue "Instance boot BIOS nhưng MBR không có mã GRUB"
    fi

    section "Nhận định"
    if [ "${#ISSUES[@]}" -eq 0 ]; then
        echo "  ${G}Không phát hiện vấn đề rõ ràng.${N}"
    else
        for i in "${!ISSUES[@]}"; do
            echo "  ${R}$((i + 1)).${N} ${ISSUES[$i]}"
        done
    fi
    if [ -n "$ROOT_DEV" ]; then
        kv "Script đề xuất" "${TARGET:-chưa có (${TARGET_NOTE})}"
    fi
    echo "  (Firmware lấy theo chế độ boot của live CD trên chính instance này)"
}

# --------------------------------------------------------------------------
step "Bước 0: Kiểm tra ban đầu"
[ "$(id -u)" -eq 0 ] || die "Cần quyền root. Chạy: sudo bash $0"
command -v vgchange >/dev/null || {
    info "Cài lvm2 để đọc được ổ LVM"
    apt-get update -qq && apt-get install -y lvm2 >/dev/null || warn "Không cài được lvm2, có thể không thấy root trên LVM."
}
vgchange -ay >/dev/null 2>&1
udevadm settle 2>/dev/null

# --------------------------------------------------------------------------
step "Bước 1: Chọn đĩa của VM"
if [ -z "$DISK" ]; then
    # Bỏ qua đĩa đang có phân vùng mount (đĩa của live CD / rescue), CD-ROM, loop
    disks=()
    while read -r d t; do
        [ "$t" = "disk" ] || continue
        lsblk -nrpo MOUNTPOINT "$d" | grep -q . && continue
        disks+=("$d")
    done < <(lsblk -dnrpo PATH,TYPE -e 7,11)
    lsblk -o NAME,FSTYPE,SIZE,TYPE,MOUNTPOINT -e 7,11
    if   [ "${#disks[@]}" -eq 0 ]; then
        die "Không tìm thấy đĩa nào chưa mount. Chỉ định: sudo bash $0 /dev/xxx"
    elif [ "${#disks[@]}" -eq 1 ]; then
        DISK="${disks[0]}"
    else
        echo "Có nhiều đĩa, chọn đĩa của VM cần sửa:"
        PS3="Chọn số: "
        select d in "${disks[@]}"; do
            [ -n "${d:-}" ] && DISK="$d" && break
        done
    fi
fi
[ -b "$DISK" ] || die "Không tìm thấy ổ đĩa $DISK"
if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q .; then
    die "Có phân vùng của $DISK đang được mount. Hãy umount hết rồi chạy lại."
fi
info "Đĩa: $DISK"

# --------------------------------------------------------------------------
step "Bước 2: Nhận diện hệ điều hành (chỉ đọc)"
mkdir -p "$PROBE"
found_dev=(); found_os=()
# Không dựa vào cột FSTYPE của lsblk (lấy từ udev, trên live CD có thể trống): đọc thẳng
# bằng blkid -p, không nhận ra thì vẫn thử mount ro
while read -r dev; do
    fs=$(blkid -p -s TYPE -o value "$dev" 2>/dev/null)
    case "$fs" in swap|LVM2_member|crypto_LUKS|linux_raid_member|vfat) continue ;; esac
    if ! mount_ro "$dev" "$PROBE"; then
        echo "  $dev (${fs:-không rõ fs}): không mount được, bỏ qua"
        continue
    fi
    fs=$(findmnt -nro FSTYPE "$PROBE")
    if [ -f "$PROBE/etc/fstab" ] && os=$(detect_os "$PROBE"); then
        found_dev+=("$dev"); found_os+=("$os")
        echo "  $dev ($fs): ${os##*|}"
    else
        echo "  $dev ($fs): không phải root"
    fi
    umount "$PROBE"
done < <(lsblk -nrpo PATH,TYPE "$DISK" | awk '$2=="part" || $2=="lvm" {print $1}')

ROOT_DEV=""; OS_ID=""; OS_LIKE=""; OS_VER=""; OS_NAME=""
if [ "${#found_dev[@]}" -ge 1 ]; then
    idx=0
    if [ "${#found_dev[@]}" -gt 1 ]; then
        echo "Tìm thấy nhiều hệ điều hành, chọn root cần sửa:"
        opts=()
        for i in "${!found_dev[@]}"; do opts+=("${found_dev[$i]}  ${found_os[$i]##*|}"); done
        PS3="Chọn số: "
        select o in "${opts[@]}"; do
            [ -n "${o:-}" ] && idx=$((REPLY - 1)) && break
        done
    fi
    ROOT_DEV="${found_dev[$idx]}"
    IFS='|' read -r OS_ID OS_LIKE OS_VER OS_NAME <<<"${found_os[$idx]}"
    pick_target
else
    warn "Không tìm thấy hệ điều hành Linux nào trên $DISK, vẫn khám phần đĩa."
fi

# --------------------------------------------------------------------------
step "Bước 3: Khám sức khỏe VM (chỉ đọc)"
echo "Đang thu thập thông tin..."
ISSUES=()
{
    echo "${B}===== KHÁM SỨC KHỎE VM  $(date '+%F %T') =====${N}"
    report_disk
    if [ -n "$ROOT_DEV" ]; then
        report_os
    else
        issue "Không tìm thấy hệ điều hành Linux nào trên $DISK"
    fi
    report_verdict
} > "$REPORT.raw" 2>&1
cat "$REPORT.raw"
sed 's/\x1b\[[0-9;]*m//g' "$REPORT.raw" > "$REPORT" && rm -f "$REPORT.raw"
echo
info "Đã lưu báo cáo: $REPORT"

[ -n "$ROOT_DEV" ] || die "Không có hệ điều hành để sửa. Gửi báo cáo trên để phân tích."
if [ "$CHECK_ONLY" = "1" ]; then
    info "Chế độ --check: chỉ khám, không chạy script sửa."
    exit 0
fi

# --------------------------------------------------------------------------
step "Bước 4: Chọn script"
[ -n "$TARGET" ] || die "${TARGET_NOTE}. Không có thay đổi nào trên đĩa. Gửi báo cáo trên để bổ sung script."
info "Sẽ dùng: $TARGET"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)
SCRIPT="$SCRIPT_DIR/$TARGET"
if [ ! -f "$SCRIPT" ]; then
    SCRIPT="/tmp/$TARGET"
    URL="$REPO_RAW/$BRANCH/$TARGET"
    info "Không thấy $TARGET cạnh fix.sh, tải từ $URL"
    if command -v wget >/dev/null; then
        wget -qO "$SCRIPT" "$URL"
    else
        curl -fsSL -o "$SCRIPT" "$URL"
    fi || die "Không tải được $URL (kiểm tra mạng / tên nhánh BRANCH=$BRANCH)."
fi
head -n1 "$SCRIPT" | grep -q '^#!/bin/bash' && bash -n "$SCRIPT" \
    || die "$SCRIPT không phải script hợp lệ (tải lỗi?)."

echo
echo "Lệnh sẽ chạy: ROOT_DEV=$ROOT_DEV bash $SCRIPT $DISK"
read -rp "Tiếp tục? (Y/n): " a
case "$a" in n|N) die "Đã hủy. Không có thay đổi nào trên đĩa." ;; esac

cleanup
trap - EXIT
ROOT_DEV="$ROOT_DEV" exec bash "$SCRIPT" "$DISK"
