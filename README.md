# cmcfixboot

Bộ script sửa VM Linux **không boot được sau khi chuyển lên OpenStack/KVM**: VM được restore (Acronis...) từ Hyper-V, Azure, VMware hay máy vật lý.

Mọi script đều chạy **từ Ubuntu Live** (ISO Ubuntu Desktop 24.04) boot trên chính instance cần sửa, bằng quyền root. Không cần mật khẩu của VM.

| File | Dùng khi |
|---|---|
| `fix.sh` | **Luôn chạy file này trước.** Khám sức khỏe VM (chỉ đọc), rồi tự chọn và chạy script sửa phù hợp. |
| `convert.sh` | Sửa boot cho **Ubuntu / Debian**. `fix.sh` tự gọi. |
| `convert-centos7.sh` | Sửa boot cho **CentOS 7**. `fix.sh` tự gọi. |
| `vm-chroot.sh` | **CentOS boot được bằng kernel rescue nhưng kernel thường treo.** Cũng dùng để mở shell root trong VM. |

---

## 1. Chuẩn bị

1. **Snapshot volume của VM trên OpenStack.** Bắt buộc: các script có ghi lên đĩa.
2. Gắn ISO Ubuntu Desktop 24.04 vào instance (hoặc dùng rescue mode), boot vào **Try Ubuntu**.
3. Live CD phải **có mạng**: script cần tải gói GRUB.
4. Mở Terminal, lấy script về:

```bash
git clone https://github.com/bachntnhg/cmcfixboot.git ~/cmcfixboot
cd ~/cmcfixboot
# nếu đã clone từ trước:  cd ~/cmcfixboot && git pull
```

Live CD không có git thì tải từng file:

```bash
wget https://raw.githubusercontent.com/bachntnhg/cmcfixboot/main/fix.sh
```

`fix.sh` tự tải script con (`convert.sh`, `convert-centos7.sh`) nếu chúng không nằm cùng thư mục.

> Luôn chạy bằng `sudo bash <file>.sh`. Nếu lỡ gõ `sudo sh`, script tự chuyển sang bash.

---

## 2. Quy trình chuẩn (áp dụng cho mọi VM)

```bash
sudo bash fix.sh --check     # BƯỚC 1: chỉ khám, không sửa gì, chụp màn hình lại
sudo bash fix.sh             # BƯỚC 2: khám rồi hỏi có chạy script sửa không
```

- Báo cáo khám được lưu ở `/tmp/vm-health-<ngày-giờ>.txt` (mất khi tắt Live CD).
- `fix.sh` tự chọn đĩa của VM, bỏ qua đĩa đang chạy Live/rescue. Có nhiều đĩa thì hiện menu để chọn, hoặc chỉ định luôn: `sudo bash fix.sh /dev/vdb`.
- Script sửa luôn **in kế hoạch và bắt gõ `YES`** trước khi ghi đĩa.

---

## 3. Tra cứu nhanh theo tình huống

| Triệu chứng khi boot VM trên OpenStack | Hệ điều hành | Chạy |
|---|---|---|
| Rơi vào **UEFI Interactive Shell** (`Shell>`) | Ubuntu/Debian | `sudo bash fix.sh` (gọi `convert.sh`) |
| | CentOS 7 | `sudo bash fix.sh` (gọi `convert-centos7.sh`) |
| **No bootable device**, dừng ở màn hình SeaBIOS | Ubuntu/Debian | `sudo bash fix.sh` (gọi `convert.sh`) |
| | CentOS 7 | `sudo bash fix.sh` (gọi `convert-centos7.sh`) |
| CentOS **boot được bằng kernel rescue**, kernel thường treo `dracut-initqueue timeout` / `dracut:/#` | CentOS 6/7, Rocky, Alma, Stream | `sudo bash vm-chroot.sh` |
| Boot được nhưng **mất mạng** | Mọi bản | `sudo bash fix.sh` và chọn **Y** ở câu hỏi mạng. Sửa tay: `sudo bash vm-chroot.sh --shell` |
| Báo cáo ghi **không tìm thấy hệ điều hành / filesystem** | – | Dữ liệu volume chưa có hoặc hỏng, xem [mục 6](#6-xử-lý-khi-gặp-lỗi) |
| Báo cáo ghi **chưa có script** (CentOS 5/6, Stream, Rocky 8/9...) | – | Chưa hỗ trợ, gửi báo cáo `fix.sh --check` để bổ sung |

### Các tình huống đã gặp và đã xử lý được

| # | Tình huống (theo báo cáo `fix.sh --check`) | Script | Script làm gì |
|---|---|---|---|
| A | Instance **UEFI**, CentOS 7 cài kiểu **BIOS** (Hyper-V Gen 1, đĩa MBR, `/boot` riêng) | `convert-centos7.sh`, chế độ BIOS | Chép `/boot` vào root, **format phân vùng `/boot` cũ thành ESP**, cài GRUB UEFI + shim, cài lại GRUB BIOS, thêm virtio |
| B | Instance **BIOS**, CentOS 7 cài kiểu **UEFI** (Hyper-V Gen 2: GPT, có ESP, MBR trống) | `convert-centos7.sh`, chế độ UEFI | Giữ nguyên phân vùng, tạo `bios_grub`, cài GRUB BIOS (`grub2-pc`), sửa GRUB UEFI, thêm virtio |
| C | Instance **BIOS**, Ubuntu cài kiểu **UEFI**, có kernel azure | `convert.sh` | Cài GRUB BIOS + UEFI, đổi kernel azure sang generic, tắt dịch vụ Hyper-V |
| D | Instance **UEFI**, Ubuntu cài kiểu **BIOS** (đĩa MBR) | `convert.sh` | Chuyển MBR sang GPT, tạo ESP + `bios_grub`, cài GRUB cả hai chế độ |
| E | Ubuntu 18.04 **không có repo chính** trong `sources.list` (chỉ còn PPA) | `convert.sh` | Tự thêm tạm repo `archive.ubuntu.com` / `old-releases`, cài xong thì gỡ |
| F | CentOS chỉ boot được **kernel rescue** | `vm-chroot.sh` | Tạo lại initramfs mọi kernel kèm driver virtio |

Sau khi sửa, **mọi đĩa boot được cả BIOS lẫn UEFI** (nếu đĩa còn chỗ cho `bios_grub`).

---

## 4. Chi tiết từng script

### `fix.sh`: khám sức khỏe và điều phối

```bash
sudo bash fix.sh                 # khám, rồi chạy script sửa
sudo bash fix.sh --check         # chỉ khám
sudo bash fix.sh /dev/vdb        # chỉ định đĩa (kết hợp được với --check)
sudo BRANCH=ten-nhanh bash fix.sh   # tải script con từ nhánh khác main (để thử nghiệm)
```

Báo cáo gồm:
- **Môi trường:** firmware của instance (BIOS hay UEFI, Secure Boot), hypervisor. Firmware đo qua Live CD, nên cũng là firmware mà ổ VM sẽ gặp khi boot.
- **Đĩa:** bảng phân vùng, mã boot ở MBR, từng phân vùng/LV với filesystem và vai trò (ESP, bios_grub, LVM, swap).
- **Hệ điều hành:** phiên bản, kiểu cài (BIOS/UEFI), `/boot`, ESP, kernel, virtio trong initramfs, `root=` trong grub.cfg, từng dòng fstab, cấu hình mạng, dấu vết Azure/Hyper-V/VMware/cloud-init, SELinux.
- **Nhận định:** danh sách vấn đề đánh số kèm hậu quả, và script đề xuất.

| Dòng trong "Nhận định" | Ý nghĩa |
|---|---|
| Instance boot UEFI nhưng đĩa KHÔNG có ESP | Tình huống A/D, rơi vào UEFI Shell |
| Instance boot BIOS nhưng đĩa GPT không có bios_grub / MBR không có mã GRUB | Tình huống B/C, No bootable device |
| Kernel ... thiếu virtio_blk trong initramfs | Kernel không thấy đĩa trên KVM (dracut timeout) |
| ESP thiếu EFI/BOOT/BOOTX64.EFI | Instance UEFI không tự tìm được bootloader |
| fstab: ... không tồn tại | Boot sẽ vào emergency mode |
| ifcfg/netplan gắn HWADDR/MAC cũ, IP tĩnh | Boot được nhưng mất mạng |
| Có kernel azure | Nên đổi sang kernel generic |

### `convert.sh`: Ubuntu / Debian

Root là ext2/3/4 trên phân vùng thường hoặc LVM. `fix.sh` gọi tự động, hoặc chạy tay: `sudo bash convert.sh /dev/vda`.

Các câu hỏi và cách trả lời:

| Câu hỏi | Trả lời |
|---|---|
| `Gõ YES (viết hoa) để tiếp tục` | `YES` sau khi đã snapshot |
| `Gõ SHRINK để xác nhận` (chỉ khi đĩa hết chỗ cho ESP) | Chỉ gõ khi đã snapshot. Hoặc extend volume thêm ~1 GiB trên OpenStack rồi chạy lại (an toàn hơn) |
| `Ghi đè netplan bằng DHCP chung?` | **N** nếu IP tĩnh trong netplan trùng IP OpenStack cấp; **Y** nếu khác (chuyển DHCP, tắt cloud-init quản lý mạng) |
| `Gỡ kernel azure và dùng kernel generic?` | **Y** |

Script làm gì:
1. MBR thì chuyển sang GPT. Tạo ESP (tối đa 512 MiB) và `bios_grub` trong vùng trống.
2. Trong chroot: cài GRUB UEFI + shim, GRUB BIOS (`grub-pc-bin`), virtio vào initramfs, console serial; sửa fstab; tắt dịch vụ Hyper-V/Azure; thêm hook APT để GRUB BIOS tự cài lại khi được nâng cấp.
3. Không dừng vì repo bên thứ ba lỗi (PPA đổi Label) hay gói khác cài dở (ví dụ `mysql-server`). Thiếu repo chính thì tự thêm repo tạm.

### `convert-centos7.sh`: CentOS 7

`fix.sh` gọi tự động, hoặc chạy tay: `sudo bash convert-centos7.sh /dev/vda`. Script tự chọn chế độ:

| Chế độ | Nhận biết | Thay đổi trên đĩa |
|---|---|---|
| **BIOS** | fstab **không có** `/boot/efi` | Chép `/boot` vào root (so sánh khớp rồi mới làm tiếp), **format phân vùng `/boot` cũ thành ESP**, sửa fstab |
| **UEFI** | fstab **đã có** `/boot/efi` | Không đổi phân vùng, chỉ tạo `bios_grub` trong vùng trống đầu đĩa |

Cả hai chế độ đều:
- tải `grub2-efi`, `shim`, `grub2-pc` từ `vault.centos.org` (đúng phiên bản 7.x của VM), chỉ tải khi thiếu;
- cài GRUB UEFI (`EFI/BOOT/BOOTX64.EFI`) và GRUB BIOS;
- thêm virtio cho kernel mới nhất;
- hỏi về mạng: **Y** thay toàn bộ ifcfg bằng `ifcfg-eth0` DHCP, **N** chỉ bỏ `HWADDR`/`UUID`;
- thêm `net.ifnames=0` để card mạng giữ tên `eth0`;
- bật SELinux relabel ở lần boot đầu (máy tự reboot thêm một lần).

Instance là BIOS mà đĩa không còn chỗ cho GRUB BIOS thì script dừng **trước khi ghi đĩa**.

### `vm-chroot.sh`: chạy lệnh trong VM

```bash
sudo bash vm-chroot.sh                       # MẶC ĐỊNH: tạo lại initramfs mọi kernel, kèm virtio
sudo bash vm-chroot.sh --shell               # shell root trong VM, gõ exit để thoát (thay đổi là THẬT)
sudo bash vm-chroot.sh -- <lệnh> [tham số]   # chạy một lệnh, ví dụ: -- cat /etc/fstab
sudo bash vm-chroot.sh --root /dev/mapper/centos-root   # chỉ định root
```

Script tự tìm root, mount `/boot` và `/boot/efi` theo fstab của VM, chroot vào, xong tự umount. Chế độ mặc định ghi thêm `/etc/dracut.conf.d/90-virtio.conf`, để các kernel cài sau này cũng có virtio. Mỗi kernel in `OK` hoặc `LỖI`.

Sau khi chạy: reboot và chọn **kernel thường** (dòng đầu menu GRUB), không chọn rescue.

---

## 5. Sau khi sửa xong

1. Script in **HOÀN TẤT**: tháo ISO / thoát rescue mode, reboot.
2. Trước khi reboot, đọc lại phần cuối output: phải có GRUB BIOS / GRUB UEFI cài thành công, và `root=` trỏ đúng root.
3. Sau khi boot, kiểm tra:

```bash
[ -d /sys/firmware/efi ] && echo UEFI || echo BIOS
systemctl --failed          # dịch vụ nào lỗi
ip a; df -h                 # IP và các mount
sudo dpkg --configure -a    # Ubuntu: hoàn tất gói cài dở (nếu script có cảnh báo)
```

Những điều bình thường ở lần boot đầu:
- CentOS bật SELinux: relabel toàn bộ file, tự reboot thêm một lần, có thể mất vài phút.
- cloud-init (nếu có) tạo lại SSH host key, nên SSH báo đổi host key.

---

## 6. Xử lý khi gặp lỗi

| Hiện tượng | Nguyên nhân / cách xử lý |
|---|---|
| `Syntax error: redirection unexpected` | Đang dùng bản cũ, chạy bằng `sh`. `git pull` rồi chạy `sudo bash ...` |
| `Không tìm thấy hệ điều hành Linux nào` | Kiểm tra dữ liệu: `sudo blkid -p /dev/vda1` phải có `TYPE=`. Không có thì volume chưa có dữ liệu (restore chưa xong) hoặc hỏng, script không sửa được |
| `fstab đã có /boot/efi` (bản cũ) | `git pull`, bản mới có chế độ UEFI |
| `E: Repository ... changed its 'Label'` | Repo bên thứ ba, script tự bỏ qua, chạy tiếp |
| `Errors were encountered while processing: mysql-server-8.0` | Gói khác cài dở từ trước, script tự bỏ qua. Sau khi boot: `sudo dpkg --configure -a` |
| `Package 'grub-efi-amd64' has no installation candidate` | VM thiếu repo chính, bản mới tự thêm repo tạm. `git pull` rồi chạy lại |
| Cảnh báo `setlocale: ... C.UTF-8` | Vô hại |
| Bước dracut chạy lâu | Bình thường, mỗi kernel từ vài chục giây tới vài phút |
| Script dừng giữa chừng | Đọc dòng đỏ `[x]`. Script nói rõ đĩa đã bị đổi gì: **chưa bị đổi** thì sửa nguyên nhân rồi chạy lại; nếu ghi **ĐỪNG reboot** thì gửi ảnh để xử lý tiếp |

Khi cần hỗ trợ, gửi kèm:
1. Báo cáo `sudo bash fix.sh --check` (ảnh chụp, hoặc nội dung `/tmp/vm-health-*.txt`);
2. Triệu chứng khi boot trên OpenStack (UEFI Shell, No bootable device, dracut timeout, mất mạng...);
3. Ảnh đoạn output nơi script dừng.

---

## 7. Script thay đổi gì trên VM

**Không đụng tới:** dữ liệu ứng dụng (`/home`, `/var/lib/mysql`, `/var/www`...), cấu hình và trạng thái bật/tắt của dịch vụ ứng dụng. `fix.sh` chỉ đọc.

**Có thay đổi:**
- bảng phân vùng (MBR sang GPT, thêm ESP/`bios_grub` trong vùng trống);
- bootloader, kernel/initramfs, fstab, cấu hình mạng (chỉ khi chọn Y);
- tắt các dịch vụ Hyper-V/Azure.

**Thao tác có rủi ro, luôn có xác nhận riêng:**
- thu nhỏ phân vùng (`convert.sh`, gõ `SHRINK`);
- format phân vùng `/boot` cũ (`convert-centos7.sh` chế độ BIOS, chỉ làm sau khi đã chép và so sánh khớp).

**Đổi mạng sang DHCP có thể làm VM đổi IP.** Dịch vụ bind vào IP cũ, firewall, DNS cần cập nhật theo.

**Luôn snapshot trước khi gõ `YES`.**
