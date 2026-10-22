# tuxdisk

**`tuxdisk`** is a fast, native macOS CLI utility and lightweight Linux virtual machine built on Apple's `Virtualization.framework` (`ARM64`) for inspecting, mounting, repairing, formatting, and transferring files to and from external drives formatted with Linux filesystems.

---

## Features & Supported Storage Layers

- **Linux Filesystems**: `ext4`, `ext3`, `ext2` (`e2fsprogs`), `Btrfs` + subvolumes (`btrfs-progs`), `XFS` (`xfsprogs`), `F2FS` (`f2fs-tools`), plus `FAT32`, `exFAT`, and `NTFS`
- **Encrypted & Logical Volumes**: Full support for **LUKS1 / LUKS2** (`cryptsetup` / `dm-crypt`) and **LVM2** (`lvm2` physical volumes, volume groups, and logical volumes)
- **Direct Raw Block Device Passthrough**: Attaches `/dev/rdiskN` directly via `VZDiskBlockDeviceStorageDeviceAttachment` while protecting internal macOS system drives (`[INTERNAL - PROTECTED]`)
- **macOS Host File Sharing**: High-speed **VirtioFS** directory sharing (`/mnt/host`) for seamless file transfers between Linux drives and macOS
- **Host-Level & Interactive Workflows**: Inspect drives, run `fsck`/`btrfs check`/`xfs_repair`, copy files (`tuxdisk copy`), or create encrypted container images directly from macOS — or drop into an interactive root shell (`tuxdisk /dev/diskN`) with Midnight Commander (`mc`)

---

## Quick Start

### 1. Build & Sign

```bash
make
```

Compiles `./bin/tuxdisk` and signs it with the `com.apple.security.virtualization` entitlement.
*(Optional)* Install globally to `/usr/local/bin/tuxdisk`:

```bash
sudo make install
```

### 2. Verify Setup & Health (`tuxdisk doctor`)

```bash
./bin/tuxdisk doctor
```

---

## Host CLI Commands

| Command | Description |
| :--- | :--- |
| `tuxdisk list [--external] [--json]` | List macOS block devices, partition tables, and highlight Linux volumes |
| `sudo tuxdisk browse <disk...> [opts]` | Mount Linux drive(s) as a native macOS volume and open in **Finder** |
| `sudo tuxdisk [shell] <disk...> [opts]` | Boot interactive Linux shell with external drive(s) attached (`--browse` to also open in Finder) |
| `sudo tuxdisk inspect <disk...>` | Probe partition tables, `blkid` UUIDs, LVM2 groups, LUKS headers & disk usage |
| `sudo tuxdisk copy <src> <dst>` | Copy files/folders directly between a Linux drive (`<disk>:<path>`) and macOS |
| `sudo tuxdisk check <disk> [--repair]` | Run filesystem integrity checks (`e2fsck`, `btrfs check`, `xfs_repair`, `fsck.f2fs`) |
| `tuxdisk create-image <file.img> [opts]` | Create and format a new sparse Linux disk image (`.img`) with GPT + Linux FS |
| `sudo tuxdisk format <disk> --fs <type>` | Format an external drive or disk image with GPT, optional LUKS2/LVM2, and Linux FS |
| `tuxdisk eject <disk>` | Safely unmount and eject an external drive on macOS (`diskutil eject`) |
| `tuxdisk setup [--force]` | Download and provision the Alpine Linux `aarch64` kernel, initramfs & rootfs |

---

## Common Workflows

### 1. Discover External Linux Drives Connected to Your Mac

```bash
./bin/tuxdisk list
# Or filter to external drives only / output JSON:
./bin/tuxdisk list --external
./bin/tuxdisk list --json
```

### 2. Browse Linux Drives Directly in macOS Finder (`tuxdisk browse`)

```bash
# Mount /dev/disk4 (ext4, Btrfs, XFS, F2FS, LUKS2, or LVM2) and open in macOS Finder:
sudo ./bin/tuxdisk browse /dev/disk4

# Mount in read-only mode or at a custom macOS directory:
sudo ./bin/tuxdisk browse /dev/disk4 --read-only --mount-point ~/Volumes/LinuxDrive
```

- Automatically unlocks LUKS containers (prompting for passphrase if encrypted) and activates LVM2 volume groups.
- Mounts via macOS's built-in `mount_webdav` bridge with zero third-party kernel extensions required.
- Suppresses `.DS_Store`, `._*` AppleDouble, `.Spotlight-V100`, and `.Trashes` clutter so your Linux disk stays clean.
- Press `Ctrl+C` (or click **Eject** in Finder) to flush writes, unmount the volume, and power off the VM cleanly.

### 3. Deep-Inspect an External Drive or Image Without Mounting on macOS

```bash
sudo ./bin/tuxdisk inspect /dev/disk4
```

Outputs the GPT/MBR partition layout, `blkid` filesystem signatures, LVM2 PV/VG/LV hierarchy, LUKS encryption header summary, space usage (`df -hT`), and top-level directory listing.

### 4. Interactive Shell Session (with Optional Finder Mount)

```bash
# Read-write session with current macOS directory shared at /mnt/host:
sudo ./bin/tuxdisk /dev/disk4

# Interactive Linux shell AND macOS Finder volume mounted simultaneously:
sudo ./bin/tuxdisk /dev/disk4 --browse

# Read-only session with automatic partition mounting and ~/Downloads shared at /mnt/host:
sudo ./bin/tuxdisk /dev/disk4 --read-only --auto-mount --share ~/Downloads
```

Inside the interactive VM shell, you have these built-in commands:
- `disks` — Colorized table of attached drives, filesystems, labels, usage %, mountpoints, and UUIDs
- `mount-disk <dev> [dir]` — Automatically unlocks `crypto_LUKS`, activates `LVM2`, and mounts under `/mnt/disks/<label>`
- `mount-disk --all` — Mounts all partitions across attached external drives
- `check-disk <dev> [--repair]` — Runs filesystem verification/repair on a partition
- `luks-info [dev]` — Displays LUKS encryption header details and active keyslots
- `unmount-all` — Flushes writes, unmounts all disks, deactivates LVM, and closes LUKS volumes
- `mc` — Opens **Midnight Commander** dual-pane file manager
- `exit` — Automatically runs `unmount-all`, `sync`, and powers off the VM cleanly

### 4. Direct File Copy Between a Linux Drive and macOS (`tuxdisk copy`)

```bash
# Pull a directory from an external Linux drive to macOS:
sudo ./bin/tuxdisk copy /dev/disk4:/home/alice/Documents ~/Desktop/LinuxDocs

# Push a file from macOS onto an external Linux drive:
sudo ./bin/tuxdisk copy ./backup.tar.zst /dev/disk4:/backups/backup.tar.zst
```

### 5. Create a Portable Linux Disk Image (`tuxdisk create-image`)

```bash
# Create a 512MB Btrfs disk image:
./bin/tuxdisk create-image my-btrfs.img --size 512M --fs btrfs --label DataVault

# Create a 1GB LUKS2-encrypted LVM2 + ext4 disk image:
./bin/tuxdisk create-image encrypted.img --size 1G --fs ext4 --label Secret --luks --lvm
```

### 6. Check & Repair a Linux Filesystem (`tuxdisk check`)

```bash
# Read-only health check across all partitions on /dev/disk4:
sudo ./bin/tuxdisk check /dev/disk4

# Repair filesystem errors:
sudo ./bin/tuxdisk check /dev/disk4 --repair
```
