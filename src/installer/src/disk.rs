//! Disk enumeration, partitioning and formatting.

use crate::run::{check, out, run, sh, R};
use std::fs;
use std::path::Path;

pub struct Disk {
    pub name: String,   // e.g. "vda", "nvme0n1"
    pub dev: String,    // e.g. "/dev/vda"
    pub bytes: u64,
    pub model: String,
}

impl Disk {
    /// nvme0n1 -> nvme0n1p<idx>, vda -> vda<idx>
    pub fn part(&self, idx: u32) -> String {
        let last = self.name.chars().last().unwrap_or(' ');
        if last.is_ascii_digit() {
            format!("{}p{}", self.dev, idx)
        } else {
            format!("{}{}", self.dev, idx)
        }
    }

    pub fn gib(&self) -> f64 {
        self.bytes as f64 / 1_073_741_824.0
    }
}

pub fn list() -> Vec<Disk> {
    let mut v = Vec::new();
    let Ok(rd) = fs::read_dir("/sys/block") else {
        return v;
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let is_disk = ["sd", "nvme", "vd", "mmcblk"]
            .iter()
            .any(|p| name.starts_with(p));
        if !is_disk {
            continue;
        }
        let bytes = fs::read_to_string(format!("/sys/block/{name}/size"))
            .ok()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .map(|sect| sect * 512)
            .unwrap_or(0);
        let model = fs::read_to_string(format!("/sys/block/{name}/device/model"))
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        v.push(Disk {
            dev: format!("/dev/{name}"),
            name,
            bytes,
            model,
        });
    }
    v.sort_by(|a, b| a.name.cmp(&b.name));
    v
}

/// GPT: 1 MiB BIOS-boot (ef02, GRUB stuffs core.img in there) + root.
/// Returns the root partition.
pub fn partition_bios(disk: &Disk) -> R<String> {
    check(&["sgdisk", "--zap-all", &disk.dev])?;
    check(&[
        "sgdisk",
        "-n1:0:+1M", "-t1:ef02", "-c1:BIOSboot",
        "-n2:0:0", "-t2:8300", "-c2:blueberry-root",
        &disk.dev,
    ])?;
    settle(disk);
    Ok(disk.part(2))
}

/// GPT: 512 MiB ESP (ef00) + root. Returns (esp, root).
pub fn partition_uefi(disk: &Disk) -> R<(String, String)> {
    check(&["sgdisk", "--zap-all", &disk.dev])?;
    check(&[
        "sgdisk",
        "-n1:0:+512M", "-t1:ef00", "-c1:EFI",
        "-n2:0:0", "-t2:8300", "-c2:blueberry-root",
        &disk.dev,
    ])?;
    settle(disk);
    Ok((disk.part(1), disk.part(2)))
}

/// Get the new partition nodes to show up, with udev or busybox mdev.
fn settle(disk: &Disk) {
    let _ = sh(&format!(
        "partprobe {0} 2>/dev/null; udevadm settle 2>/dev/null; mdev -s 2>/dev/null; sync",
        disk.dev
    ));
    for _ in 0..20 {
        if Path::new(&disk.part(2)).exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
    }
}

pub fn mkfs_ext4(dev: &str, label: &str) -> R<()> {
    check(&["mkfs.ext4", "-F", "-L", label, dev])
}

pub fn mkfs_xfs(dev: &str, label: &str) -> R<()> {
    // mkfs.xfs refuses labels over 12 chars
    let l: String = label.chars().take(12).collect();
    check(&["mkfs.xfs", "-f", "-L", &l, dev])
}

pub fn mkfs_btrfs(dev: &str, label: &str) -> R<()> {
    check(&["mkfs.btrfs", "-f", "-L", label, dev])
}

/// Ubuntu-style @ / @home / @snapshots. We don't change the default subvolume:
/// the boot chain pins subvol=@ itself (grub loads /@/boot/..., kernel gets
/// rootflags=subvol=@), and GRUB reads the top level, so /@ resolves no matter
/// what the default is. `tmp` is a scratch mountpoint, unmounted again after.
pub fn btrfs_subvol_layout(dev: &str, tmp: &str) -> R<()> {
    std::fs::create_dir_all(tmp).ok();
    check(&["mount", dev, tmp])?;
    let res = (|| -> R<()> {
        check(&["btrfs", "subvolume", "create", &format!("{tmp}/@")])?;
        check(&["btrfs", "subvolume", "create", &format!("{tmp}/@home")])?;
        // sibling of @ (not inside it) so rolling back root leaves the snapshots alone
        check(&["btrfs", "subvolume", "create", &format!("{tmp}/@snapshots")])
    })();
    let _ = run(&["umount", tmp]);
    res
}

/// One VG on `pv_dev` (raw partition or LUKS mapper), one LV filling it.
pub fn lvm_setup(pv_dev: &str, vg: &str, lv: &str) -> R<String> {
    check(&["pvcreate", "-ff", "-y", pv_dev])?;
    check(&["vgcreate", "-y", vg, pv_dev])?;
    check(&["lvcreate", "-y", "-l", "100%FREE", "-n", lv, vg])?;
    // should already be active, but make sure the node is there
    let _ = run(&["vgchange", "-ay", vg]);
    Ok(format!("/dev/{vg}/{lv}"))
}

pub fn mkfs_root(dev: &str, label: &str, fs: crate::engine::Filesystem) -> R<()> {
    use crate::engine::Filesystem::*;
    match fs {
        Ext4 => mkfs_ext4(dev, label),
        Xfs => mkfs_xfs(dev, label),
        Btrfs => mkfs_btrfs(dev, label),
    }
}

pub fn mkfs_fat(dev: &str, label: &str) -> R<()> {
    check(&["mkfs.fat", "-F32", "-n", label, dev])
}

/// Filesystem UUID via blkid. Busybox blkid ignores -s/-o and dumps
/// `/dev/x: UUID="..."` for every device, so never trust the output blindly.
pub fn uuid(dev: &str) -> String {
    let looks_like_uuid =
        |s: &str| !s.is_empty() && s.len() >= 8 && s.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
    let u = out(&["blkid", "-s", "UUID", "-o", "value", dev]);
    if looks_like_uuid(u.trim()) {
        return u.trim().to_string();
    }
    // busybox: find our own device's line and dig the UUID out
    let all = out(&["blkid"]);
    for line in all.lines().chain(out(&["blkid", dev]).lines()) {
        if !line.starts_with(&format!("{dev}:")) {
            continue;
        }
        if let Some(i) = line.find("UUID=\"") {
            let rest = &line[i + 6..];
            if let Some(end) = rest.find('"') {
                let v = &rest[..end];
                if looks_like_uuid(v) {
                    return v.to_string();
                }
            }
        }
    }
    String::new()
}

/// Best effort: links up + DHCP so bpm can reach the repo.
pub fn ensure_network() {
    if run(&["sh", "-c", "ip route 2>/dev/null | grep -q default"]) {
        return;
    }
    let _ = sh(
        "for i in /sys/class/net/*; do n=$(basename \"$i\"); [ \"$n\" = lo ] && continue; \
         ip link set \"$n\" up 2>/dev/null; \
         (udhcpc -b -i \"$n\" -t 3 -T 2 2>/dev/null || dhcpcd -t 5 \"$n\" 2>/dev/null); done; sleep 1",
    );
}
