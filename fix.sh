#!/bin/bash
# ==========================================================================
# fix.sh  (v1)
# Script điều phối: tự nhận diện hệ điều hành trên đĩa VM rồi chạy đúng script sửa boot
#   - Ubuntu/Debian -> convert.sh
#   - CentOS 7      -> convert-centos7.sh
# Chỉ ĐỌC đĩa (mount ro) để nhận diện, việc ghi đĩa do script con làm (có hỏi xác nhận).
# Chạy trong Ubuntu Live (có mạng), bằng quyền root:
#
#     sudo bash fix.sh              # tự chọn đĩa
#     sudo bash fix.sh /dev/vdb     # chỉ định đĩa
#
# Nếu convert.sh / convert-centos7.sh không nằm cùng thư mục, script tự tải từ GitHub.
# Biến môi trường tùy chọn:
#     BRANCH=test-centos7   nhánh GitHub để tải script con (mặc định main)
# ==========================================================================
set -u

REPO_RAW=https://raw.githubusercontent.com/bachntnhg/cmcfixboot
BRANCH="${BRANCH:-main}"
PROBE=/tmp/probe-os

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'
info() { echo "${G}[+]${N} $*"; }
warn() { echo "${Y}[!]${N} $*"; }
die()  { echo "${R}[x] $*${N}" >&2; exit 1; }
step() { echo; echo "${B}=== $* ===${N}"; }

cleanup() {
    mountpoint -q "$PROBE" 2>/dev/null && umount "$PROBE" 2>/dev/null
}
trap cleanup EXIT

# Đọc một khóa trong os-release: $1=file, $2=khóa
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
DISK="${1:-}"
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
while read -r dev fs; do
    case "$fs" in ext2|ext3|ext4|xfs|btrfs) ;; *) continue ;; esac
    mount -o ro "$dev" "$PROBE" 2>/dev/null \
        || mount -o ro,norecovery "$dev" "$PROBE" 2>/dev/null \
        || continue
    if [ -f "$PROBE/etc/fstab" ] && os=$(detect_os "$PROBE"); then
        found_dev+=("$dev"); found_os+=("$os")
        echo "  $dev ($fs): ${os##*|}"
    fi
    umount "$PROBE"
done < <(lsblk -nrpo PATH,FSTYPE "$DISK")

if   [ "${#found_dev[@]}" -eq 0 ]; then
    die "Không tìm thấy hệ điều hành Linux nào trên $DISK."
elif [ "${#found_dev[@]}" -eq 1 ]; then
    idx=0
else
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
info "Root: $ROOT_DEV"
info "Hệ điều hành: $OS_NAME (ID=$OS_ID, ID_LIKE=${OS_LIKE:-trống}, VERSION_ID=$OS_VER)"

# --------------------------------------------------------------------------
step "Bước 3: Chọn script"
TARGET=""
case " $OS_ID $OS_LIKE " in
    *" ubuntu "*|*" debian "*)
        TARGET=convert.sh ;;
    *" centos "*|*" rhel "*)
        if [ "$OS_ID" = "centos" ] && [ "${OS_VER%%.*}" = "7" ]; then
            TARGET=convert-centos7.sh
        else
            die "$OS_NAME chưa được hỗ trợ (chỉ có script cho CentOS 7). Không có thay đổi nào trên đĩa."
        fi ;;
    *)
        die "$OS_NAME chưa được hỗ trợ. Không có thay đổi nào trên đĩa." ;;
esac
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
