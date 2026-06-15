/* blueberry-install — guided installer for Blueberry Linux.
 *
 * Runs on the live (ISO) system. Partitions a target disk (GPT: EFI + root),
 * formats it, lays down the full rootfs from a payload shipped on the boot
 * media, installs the GRUB EFI bootloader, writes fstab, and sets the root
 * password. Optionally installs extra packages via bpm into the new system.
 *
 * Required tools on the live system: sgdisk, mkfs.fat, mkfs.ext4, blkid,
 * busybox (mount/umount/chroot/...). The payload directory (found on the boot
 * media) must contain:
 *     rootfs.tar.zst         the full system to install
 *     vmlinuz                kernel
 *     initramfs.cpio.zst     initramfs
 *     bootx64.efi            prebuilt GRUB EFI binary (reads /grub/grub.cfg)
 *
 * Deliberately small and dependency-light (libc only).
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/wait.h>

static void die(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs("\n[install] ERROR: ", stderr); vfprintf(stderr, fmt, ap);
    fputc('\n', stderr); va_end(ap); exit(1);
}
static void step(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    fputs(":: ", stdout); vprintf(fmt, ap); fputc('\n', stdout);
    va_end(ap); fflush(stdout);
}

/* Run a shell command; return exit status. */
static int run(const char *fmt, ...) {
    char cmd[4096];
    va_list ap; va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap); va_end(ap);
    int rc = system(cmd);
    return WIFEXITED(rc) ? WEXITSTATUS(rc) : -1;
}
/* Run; die on failure. */
static void runck(const char *fmt, ...) {
    char cmd[4096];
    va_list ap; va_start(ap, fmt);
    vsnprintf(cmd, sizeof cmd, fmt, ap); va_end(ap);
    if (run("%s", cmd) != 0) die("command failed: %s", cmd);
}

static char *prompt(const char *q) {
    static char buf[256];
    printf("%s", q); fflush(stdout);
    if (!fgets(buf, sizeof buf, stdin)) die("no input");
    buf[strcspn(buf, "\n")] = '\0';
    return buf;
}

/* Read a disk's size in bytes from /sys/block/<name>/size (512B sectors). */
static unsigned long long disk_bytes(const char *name) {
    char p[256]; snprintf(p, sizeof p, "/sys/block/%s/size", name);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    unsigned long long sect = 0; if (fscanf(f, "%llu", &sect) != 1) sect = 0;
    fclose(f); return sect * 512ULL;
}

/* List candidate target disks; let the user pick one. Returns "/dev/<name>". */
static char *choose_disk(void) {
    static char dev[64];
    char names[32][256]; int n = 0;
    DIR *d = opendir("/sys/block");
    if (!d) die("cannot scan /sys/block");
    struct dirent *de;
    while ((de = readdir(d)) && n < 32) {
        const char *nm = de->d_name;
        if (nm[0] == '.') continue;
        /* real disks only: sd*, nvme*, vd*, mmcblk*; skip loop/ram/sr */
        if (strncmp(nm, "sd", 2) && strncmp(nm, "nvme", 4) &&
            strncmp(nm, "vd", 2) && strncmp(nm, "mmcblk", 6)) continue;
        snprintf(names[n++], 256, "%s", nm);
    }
    closedir(d);
    if (n == 0) die("no installable disks found");

    printf("\nAvailable disks:\n");
    for (int i = 0; i < n; i++) {
        char model[128] = "";
        char mp[256]; snprintf(mp, sizeof mp, "/sys/block/%s/device/model", names[i]);
        FILE *mf = fopen(mp, "r");
        if (mf) { if (fgets(model, sizeof model, mf)) model[strcspn(model, "\n")] = 0; fclose(mf); }
        printf("  [%d] /dev/%-10s %6.1f GiB  %s\n", i + 1, names[i],
               disk_bytes(names[i]) / 1073741824.0, model);
    }
    int sel = atoi(prompt("\nSelect disk number to INSTALL TO (everything on it is erased): "));
    if (sel < 1 || sel > n) die("invalid selection");
    snprintf(dev, sizeof dev, "/dev/%s", names[sel - 1]);
    return dev;
}

/* Partition suffix: nvme0n1 -> nvme0n1p1; sda -> sda1. */
static void partdev(char *out, size_t n, const char *disk, int idx) {
    size_t l = strlen(disk);
    if (l && isdigit((unsigned char)disk[l - 1])) snprintf(out, n, "%sp%d", disk, idx);
    else snprintf(out, n, "%s%d", disk, idx);
}

/* Read a device's filesystem UUID by parsing blkid output (works with both
 * busybox and util-linux blkid). out[0]='\0' if not found. */
static void read_uuid(const char *dev, char *out, size_t n) {
    out[0] = '\0';
    char cmd[160]; snprintf(cmd, sizeof cmd, "blkid %s 2>/dev/null", dev);
    FILE *p = popen(cmd, "r");
    if (!p) return;
    char line[512];
    if (fgets(line, sizeof line, p)) {
        char *u = strstr(line, "UUID=\"");
        if (u) {
            u += 6;
            char *e = strchr(u, '"');
            if (e) {
                size_t len = (size_t)(e - u);
                if (len >= n) len = n - 1;
                memcpy(out, u, len); out[len] = '\0';
            }
        }
    }
    pclose(p);
}

/* Locate the payload by trying to mount each block device read-only and
 * checking for rootfs.tar.zst. Returns a static mountpoint path. */
static const char *find_payload(void) {
    static const char *MP = "/run/blueberry-media";
    mkdir("/run", 0755); mkdir(MP, 0755);

    /* already mounted / shipped in initramfs? */
    if (access("/blueberry/rootfs.tar.zst", R_OK) == 0) return "/blueberry";

    DIR *d = opendir("/sys/block");
    if (!d) return NULL;
    struct dirent *de;
    char cands[64][288]; int n = 0;
    while ((de = readdir(d)) && n < 60) {
        const char *nm = de->d_name;
        if (nm[0] == '.') continue;
        if (!strncmp(nm, "loop", 4) || !strncmp(nm, "ram", 3)) continue;
        snprintf(cands[n++], 288, "/dev/%s", nm);          /* whole device (CD/ISO) */
        for (int p = 1; p <= 4 && n < 60; p++) {          /* and its partitions */
            char pd[80]; partdev(pd, sizeof pd, nm, p);
            snprintf(cands[n++], 288, "/dev/%s", pd);
        }
    }
    closedir(d);

    const char *fstypes[] = { "iso9660", "vfat", "ext4", NULL };
    for (int i = 0; i < n; i++) {
        for (int f = 0; fstypes[f]; f++) {
            if (mount(cands[i], MP, fstypes[f], MS_RDONLY, NULL) == 0) {
                if (access("/run/blueberry-media/blueberry/rootfs.tar.zst", R_OK) == 0) {
                    static char pp[256];
                    snprintf(pp, sizeof pp, "%s/blueberry", MP);
                    return pp;
                }
                umount(MP);
            }
        }
    }
    return NULL;
}

int main(void) {
    if (geteuid() != 0) die("must run as root");
    /* the bundled tools live in /usr/{bin,sbin} with libs in /usr/lib, which
     * may not be in the live image's PATH / ld.so.cache — make sure they're found. */
    putenv("PATH=/usr/sbin:/usr/bin:/sbin:/bin");
    putenv("LD_LIBRARY_PATH=/usr/lib:/lib");

    printf("\n=== Blueberry Linux installer ===\n");

    step("locating install payload");
    const char *pay = find_payload();
    if (!pay) die("could not find the install payload (rootfs.tar.zst) on any boot medium");
    printf("   payload: %s\n", pay);

    /* Non-interactive mode for scripted installs / CI:
     *   BLUEBERRY_TARGET=/dev/sdX  BLUEBERRY_YES=1  BLUEBERRY_ROOTPW=secret */
    const char *env_disk = getenv("BLUEBERRY_TARGET");
    char *disk = (env_disk && *env_disk) ? (char *)env_disk : choose_disk();
    printf("\nThis will ERASE ALL DATA on %s.\n", disk);
    if (!getenv("BLUEBERRY_YES") &&
        strcmp(prompt("Type 'yes' to continue: "), "yes") != 0)
        die("aborted by user");

    char efi[96], root[96];
    partdev(efi, sizeof efi, disk, 1);
    partdev(root, sizeof root, disk, 2);

    step("partitioning %s (GPT: 512M EFI + root)", disk);
    runck("sgdisk --zap-all %s", disk);
    runck("sgdisk -n1:0:+512M -t1:ef00 -c1:EFI "
          "-n2:0:0 -t2:8300 -c2:blueberry-root %s", disk);
    /* make the new partition nodes appear (busybox: re-scan /sys) */
    run("partprobe %s 2>/dev/null; mdev -s 2>/dev/null; sync; sleep 1", disk);

    step("formatting");
    runck("mkfs.fat -F32 -n EFI %s", efi);
    runck("mkfs.ext4 -F -L blueberry-root %s", root);

    step("mounting target");
    runck("mkdir -p /mnt/blueberry");
    runck("mount %s /mnt/blueberry", root);
    runck("mkdir -p /mnt/blueberry/boot");
    runck("mount %s /mnt/blueberry/boot", efi);

    step("extracting root filesystem (this takes a moment)");
    runck("zstd -dcq %s/rootfs.tar.zst | tar -x -C /mnt/blueberry", pay);

    step("installing kernel + bootloader");
    runck("cp %s/vmlinuz /mnt/blueberry/boot/vmlinuz", pay);
    runck("cp %s/initramfs.cpio.zst /mnt/blueberry/boot/initramfs.cpio.zst", pay);
    runck("mkdir -p /mnt/blueberry/boot/EFI/BOOT /mnt/blueberry/boot/grub");
    runck("cp %s/bootx64.efi /mnt/blueberry/boot/EFI/BOOT/BOOTX64.EFI", pay);

    /* root partition UUID for the kernel cmdline */
    char uuid[128];
    read_uuid(root, uuid, sizeof uuid);
    if (!*uuid) die("could not read root UUID");

    step("writing boot config (root=UUID=%s)", uuid);
    FILE *g = fopen("/mnt/blueberry/boot/grub/grub.cfg", "w");
    if (!g) die("cannot write grub.cfg");
    fprintf(g,
        "set timeout=3\n"
        "menuentry 'Blueberry Linux' {\n"
        "    linux /vmlinuz root=UUID=%s rw console=tty0 console=ttyS0,115200\n"
        "    initrd /initramfs.cpio.zst\n"
        "}\n", uuid);
    fclose(g);

    /* fstab */
    FILE *fs = fopen("/mnt/blueberry/etc/fstab", "w");
    if (fs) {
        fprintf(fs, "UUID=%s  /      ext4  rw,relatime  0 1\n", uuid);
        char efiuuid[128];
        read_uuid(efi, efiuuid, sizeof efiuuid);
        if (*efiuuid) fprintf(fs, "UUID=%s  /boot  vfat  rw,relatime  0 2\n", efiuuid);
        fclose(fs);
    }

    step("set the root password for the installed system");
    const char *pw = getenv("BLUEBERRY_ROOTPW");
    if (pw && *pw) {
        if (run("printf 'root:%s\\n' | chroot /mnt/blueberry /usr/sbin/chpasswd 2>/dev/null"
                " || printf 'root:%s\\n' | chroot /mnt/blueberry chpasswd", pw, pw) != 0)
            die("could not set root password");
    } else {
        while (run("chroot /mnt/blueberry /usr/bin/passwd root") != 0)
            printf("   passwords didn't match; try again\n");
    }

    step("unmounting");
    run("umount /mnt/blueberry/boot");
    run("umount /mnt/blueberry");

    printf("\n=== Installation complete. Remove the install medium and reboot. ===\n");
    return 0;
}
