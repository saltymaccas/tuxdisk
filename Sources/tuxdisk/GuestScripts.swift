import Foundation

public enum GuestScripts {
    /// All guest helper scripts mapped by their destination path inside the rootfs
    public static var allFiles: [(guestPath: String, content: String)] {
        [
            ("sbin/vm-init", vmInitScript),
            ("usr/local/bin/disks", disksCommandScript),
            ("usr/local/bin/mount-disk", mountDiskScript),
            ("usr/local/bin/unmount-all", unmountAllScript),
            ("usr/local/bin/check-disk", checkDiskScript),
            ("usr/local/bin/luks-info", luksInfoScript),
            ("usr/local/bin/probe-disks", probeDisksScript)
        ]
    }

    /// `/sbin/vm-init` — PID 1 inside the VM
    public static let vmInitScript = #"""
#!/bin/sh
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/root"
export TERM="${TERM:-xterm-256color}"

mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm /run /tmp /mnt/host /mnt/disks
mount -t devpts devpts /dev/pts 2>/dev/null
mount -t tmpfs tmpfs /dev/shm 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null
mount -t tmpfs tmpfs /tmp 2>/dev/null

mount -o remount,rw / 2>/dev/null
hostname tuxdisk 2>/dev/null

COLS=100
ROWS=30
READONLY_MODE=0
AUTO_MOUNT=0
QUIET_SHUTDOWN=0
HOST_PATH_DISPLAY=""
EXEC_CMD_B64=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        vm.cols=*) COLS="${param#vm.cols=}" ;;
        vm.rows=*) ROWS="${param#vm.rows=}" ;;
        vm.ro=1) READONLY_MODE=1 ;;
        vm.automount=1) AUTO_MOUNT=1 ;;
        vm.quiet=1) QUIET_SHUTDOWN=1 ;;
        vm.hostpath=*) HOST_PATH_DISPLAY="${param#vm.hostpath=}" ;;
        vm.exec64=*) EXEC_CMD_B64="${param#vm.exec64=}" ;;
        TERM=*) export TERM="${param#TERM=}" ;;
    esac
done

export VM_READONLY="$READONLY_MODE"
export VM_HOST_PATH="$HOST_PATH_DISPLAY"

if [ -c /dev/hvc0 ]; then
    stty -F /dev/hvc0 cols "$COLS" rows "$ROWS" 2>/dev/null
fi

# Batch-load all filesystem, volume manager, encryption, and virtio kernel modules at once
modprobe -a \
    virtio_pci virtio_blk virtio_net virtiofs \
    dm-mod dm-crypt cryptd \
    ext4 crc32c btrfs xfs f2fs \
    loop vfat exfat fuse 2>/dev/null || true

mdev -s >/dev/null 2>&1
mkdir -p /run/lvm /run/cryptsetup

# Only run LVM scan at boot if an LVM2_member signature is present on an attached drive
if blkid 2>/dev/null | grep -q 'LVM2_member'; then
    vgscan --mknodes >/dev/null 2>&1
    vgchange -ay >/dev/null 2>&1
fi

# Bring up loopback and NAT network in background
ip link set lo up 2>/dev/null
if ip link show eth0 >/dev/null 2>&1; then
    ip link set eth0 up 2>/dev/null
    udhcpc -i eth0 -b -q >/dev/null 2>&1 &
fi

# Mount macOS shared directory via VirtioFS at /mnt/host
mount -t virtiofs host /mnt/host 2>/dev/null || true

# Auto-mount non-encrypted external partitions if requested
if [ "$AUTO_MOUNT" = "1" ]; then
    /usr/local/bin/mount-disk --auto >/dev/null 2>&1 || true
fi

# Ensure root bash profile is configured with tuxdisk prompt
cat > /root/.bash_profile <<'PROFILE_EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PS1='\[\033[1;36m\]tuxdisk\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# '
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
PROFILE_EOF

cleanup_and_poweroff() {
    if [ "$QUIET_SHUTDOWN" = "0" ]; then
        echo ""
        echo -e "\033[1;34m==> [tuxdisk] Syncing and safely unmounting disks...\033[0m"
    fi
    /usr/local/bin/unmount-all --quiet
    umount /mnt/host 2>/dev/null || true
    mount -o remount,ro / 2>/dev/null || true
    sync
    poweroff -f
}

# One-shot command mode (-e / --command / inspect / check / copy / format)
if [ -n "$EXEC_CMD_B64" ]; then
    EXEC_CMD=$(printf "%s" "$EXEC_CMD_B64" | base64 -d 2>/dev/null)
    RC=0
    if [ -c /dev/hvc0 ]; then
        setsid sh -c "$EXEC_CMD" </dev/hvc0 >/dev/hvc0 2>&1 || RC=$?
    else
        sh -c "$EXEC_CMD" || RC=$?
    fi
    if [ "$RC" -ne 0 ]; then
        echo "__TUXDISK_EXIT_CODE:${RC}__"
    fi
    cleanup_and_poweroff
    exit 0
fi

# Interactive Shell Banner
clear 2>/dev/null
echo -e "\033[1;36m╭────────────────────────────────────────────────────────────────────────────╮\033[0m"
echo -e "\033[1;36m│\033[0m  \033[1;37mtuxdisk\033[0m — Linux Filesystem & Volume Utility VM for macOS                  \033[1;36m│\033[0m"
echo -e "\033[1;36m│\033[0m  Filesystems: \033[32mext2/3/4\033[0m · \033[32mBtrfs\033[0m · \033[32mXFS\033[0m · \033[32mF2FS\033[0m · \033[33mLUKS1/2\033[0m · \033[33mLVM2\033[0m · \033[32mexFAT/NTFS\033[0m  \033[1;36m│\033[0m"
echo -e "\033[1;36m╰────────────────────────────────────────────────────────────────────────────╯\033[0m"

if mountpoint -q /mnt/host 2>/dev/null; then
    echo -e "  \033[1;32m● macOS Host Share:\033[0m \033[1m/mnt/host\033[0m  ──▶  ${VM_HOST_PATH:-macOS directory}"
fi
if [ "$READONLY_MODE" = "1" ]; then
    echo -e "  \033[1;33m● Access Mode:\033[0m      \033[1;33mREAD-ONLY\033[0m (external drives are write-protected)"
else
    echo -e "  \033[1;32m● Access Mode:\033[0m      \033[1;32mREAD-WRITE\033[0m"
fi
echo ""
/usr/local/bin/disks
echo ""
echo -e "\033[1;37mBuilt-in Guest Commands:\033[0m"
echo -e "  \033[36mdisks\033[0m                        Show attached drives, filesystems, LUKS & LVM status"
echo -e "  \033[36mmount-disk <dev> [dir]\033[0m       Unlock LUKS, activate LVM & mount (e.g. \033[36mmount-disk /dev/vdb1\033[0m)"
echo -e "  \033[36mmount-disk --all\033[0m             Mount all external partitions under \033[1m/mnt/disks/\033[0m"
echo -e "  \033[36mcheck-disk <dev> [--repair]\033[0m  Run fsck / btrfs check / xfs_repair on a drive or partition"
echo -e "  \033[36mluks-info <dev>\033[0m              Inspect LUKS encryption header, ciphers, and keyslots"
echo -e "  \033[36munmount-all\033[0m                  Safely unmount all drives, close LUKS & deactivate LVM"
echo -e "  \033[36mmc\033[0m                           Launch Midnight Commander dual-pane file manager"
echo -e "  \033[36mexit\033[0m                         Sync, unmount all drives, and shut down VM"
echo ""

cd /mnt/disks 2>/dev/null || cd /root
if [ -c /dev/hvc0 ]; then
    setsid /bin/bash --login </dev/hvc0 >/dev/hvc0 2>&1
else
    /bin/bash --login
fi

cleanup_and_poweroff
"""#

    /// `/usr/local/bin/disks` — Pretty table of external drives
    public static let disksCommandScript = #"""
#!/bin/sh
echo -e "\033[1;37mAttached External Drives & Volumes:\033[0m"
echo "──────────────────────────────────────────────────────────────────────────────"
EXT_DEVS=$(lsblk -dn -o NAME | grep -v '^vda$' | grep -v '^loop' | grep -v '^zram')
if [ -z "$EXT_DEVS" ]; then
    echo -e "  \033[33m(No external drives attached. Pass a disk on macOS, e.g. 'sudo tuxdisk /dev/disk4')\033[0m"
else
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,FSUSE%,MOUNTPOINTS,UUID | awk '
        NR==1 { printf "  \033[1;37m%s\033[0m\n", $0; next }
        /^vda/ || /^[├└│].*vda/ { next }
        { printf "  %s\n", $0 }
    '
fi
echo "──────────────────────────────────────────────────────────────────────────────"
"""#

    /// `/usr/local/bin/mount-disk` — Smart mounter for ext2/3/4, btrfs, xfs, f2fs, LUKS1/2, LVM2, vfat, exfat, ntfs
    public static let mountDiskScript = #"""
#!/bin/sh
set -e

usage() {
    echo "Usage:"
    echo "  mount-disk <device> [mountpoint]   Unlock (if LUKS), activate LVM, and mount"
    echo "  mount-disk --all                   Mount all external partitions under /mnt/disks/"
    echo ""
    echo "Examples:"
    echo "  mount-disk /dev/vdb1"
    echo "  mount-disk /dev/vdb2 /mnt/disks/my-drive"
}

mount_single_fs() {
    DEV="$1"
    TARGET="$2"
    FSTYPE=$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)
    LABEL=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)

    if [ -z "$FSTYPE" ]; then
        return 0
    fi

    case "$FSTYPE" in
        crypto_LUKS)
            MAP_NAME="luks_$(basename "$DEV")"
            if [ ! -e "/dev/mapper/$MAP_NAME" ]; then
                echo -e "\033[1;33m==> Unlocking LUKS volume on $DEV ($MAP_NAME)...\033[0m"
                if [ -n "$TUXDISK_PASS" ]; then
                    if [ "${VM_READONLY:-0}" = "1" ]; then
                        printf "%s" "$TUXDISK_PASS" | cryptsetup open --readonly "$DEV" "$MAP_NAME" -
                    else
                        printf "%s" "$TUXDISK_PASS" | cryptsetup open "$DEV" "$MAP_NAME" -
                    fi
                else
                    if [ "${VM_READONLY:-0}" = "1" ]; then
                        cryptsetup open --readonly "$DEV" "$MAP_NAME"
                    else
                        cryptsetup open "$DEV" "$MAP_NAME"
                    fi
                fi
            fi
            vgscan --mknodes >/dev/null 2>&1 || true
            vgchange -ay >/dev/null 2>&1 || true
            mdev -s >/dev/null 2>&1 || true
            sleep 0.1
            INNER_TYPE=$(blkid -s TYPE -o value "/dev/mapper/$MAP_NAME" 2>/dev/null || true)
            if [ "$INNER_TYPE" = "LVM2_member" ]; then
                echo -e "\033[1;32m==> Activated LVM volume group inside /dev/mapper/$MAP_NAME\033[0m"
                for lv in /dev/mapper/*; do
                    [ "$lv" = "/dev/mapper/control" ] && continue
                    [ "$lv" = "/dev/mapper/$MAP_NAME" ] && continue
                    mount_single_fs "$lv" "" || true
                done
                return 0
            else
                mount_single_fs "/dev/mapper/$MAP_NAME" "$TARGET"
                return $?
            fi
            ;;
        LVM2_member)
            echo -e "\033[1;34m==> Activating LVM Volume Groups on $DEV...\033[0m"
            vgscan --mknodes >/dev/null 2>&1 || true
            vgchange -ay >/dev/null 2>&1 || true
            mdev -s >/dev/null 2>&1 || true
            for lv in /dev/mapper/*; do
                [ "$lv" = "/dev/mapper/control" ] && continue
                case "$(basename "$lv")" in
                    luks_*) continue ;;
                esac
                if [ -b "$lv" ]; then
                    mount_single_fs "$lv" "" || true
                fi
            done
            return 0
            ;;
        swap)
            return 0
            ;;
    esac

    if [ -z "$TARGET" ]; then
        SAFE_LABEL=$(printf "%s" "$LABEL" | tr -cd 'A-Za-z0-9._-')
        if [ -n "$SAFE_LABEL" ]; then
            TARGET="/mnt/disks/${SAFE_LABEL}"
        else
            TARGET="/mnt/disks/$(basename "$DEV")"
        fi
    fi

    EXISTING=$(findmnt -n -o TARGET --source "$DEV" 2>/dev/null | head -n 1 || true)
    if [ -n "$EXISTING" ]; then
        echo -e "\033[32m✓ $DEV ($FSTYPE) is already mounted at $EXISTING\033[0m"
        return 0
    fi

    mkdir -p "$TARGET"
    if [ "${VM_READONLY:-0}" = "1" ]; then
        if [ "$FSTYPE" = "ext4" ] || [ "$FSTYPE" = "ext3" ] || [ "$FSTYPE" = "ext2" ] || [ "$FSTYPE" = "xfs" ]; then
            mount -t "$FSTYPE" -o ro,noload "$DEV" "$TARGET" 2>/dev/null || mount -t "$FSTYPE" -o ro "$DEV" "$TARGET"
        else
            mount -t "$FSTYPE" -o ro "$DEV" "$TARGET"
        fi
    else
        mount -t "$FSTYPE" "$DEV" "$TARGET"
    fi
    echo -e "\033[1;32m✓ Mounted $DEV ($FSTYPE) -> $TARGET\033[0m"

    # If Btrfs, list subvolumes if any exist
    if [ "$FSTYPE" = "btrfs" ]; then
        SUBVOLS=$(btrfs subvolume list "$TARGET" 2>/dev/null | awk '{print $NF}' | tr '\n' ' ' || true)
        if [ -n "$SUBVOLS" ]; then
            echo -e "  \033[36m↳ Btrfs subvolumes:\033[0m $SUBVOLS"
        fi
    fi
}

if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
    usage
    exit 0
fi

if [ "$1" = "--all" ] || [ "$1" = "--auto" ]; then
    MODE="$1"
    for dev in $(lsblk -lnp -o NAME,TYPE | awk '$2=="part" || $2=="disk" || $2=="lvm" || $2=="crypt" {print $1}'); do
        case "$dev" in
            /dev/vda*) continue ;;
        esac
        FSTYPE=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
        [ -z "$FSTYPE" ] && continue
        if [ "$MODE" = "--auto" ] && [ "$FSTYPE" = "crypto_LUKS" ]; then
            continue
        fi
        mount_single_fs "$dev" "" || true
    done
    exit 0
fi

DEV_ARG="$1"
case "$DEV_ARG" in
    /dev/*) ;;
    *) DEV_ARG="/dev/$DEV_ARG" ;;
esac

if [ ! -b "$DEV_ARG" ]; then
    echo "Error: Block device '$DEV_ARG' not found." >&2
    exit 1
fi

mount_single_fs "$DEV_ARG" "${2:-}"
"""#

    /// `/usr/local/bin/unmount-all` — Safely unmounts all external disks, deactivates LVM, and closes LUKS volumes
    public static let unmountAllScript = #"""
#!/bin/sh
QUIET=0
[ "$1" = "--quiet" ] && QUIET=1

log() {
    [ "$QUIET" = "0" ] && echo -e "$1" || true
}

sync

for mp in $(awk '$2 ~ /^\/mnt\/disks\// {print $2}' /proc/mounts | sort -r); do
    if umount "$mp" 2>/dev/null; then
        log "\033[32m✓ Unmounted $mp\033[0m"
        rmdir "$mp" 2>/dev/null || true
    fi
done

for mp in $(awk '($1 ~ /^\/dev\/vd[b-z]/ || $1 ~ /^\/dev\/mapper\//) && $2 != "/" {print $2}' /proc/mounts | sort -r); do
    if umount "$mp" 2>/dev/null; then
        log "\033[32m✓ Unmounted $mp\033[0m"
    fi
done

vgchange -an >/dev/null 2>&1 || true

for dm in /dev/mapper/*; do
    [ "$dm" = "/dev/mapper/control" ] && continue
    [ ! -e "$dm" ] && continue
    NAME=$(basename "$dm")
    if cryptsetup close "$NAME" 2>/dev/null; then
        log "\033[32m✓ Closed LUKS volume $NAME\033[0m"
    fi
done

sync
log "\033[1;32mAll external drives synced and safely unmounted.\033[0m"
"""#

    /// `/usr/local/bin/check-disk` — Filesystem integrity check & repair utility
    public static let checkDiskScript = #"""
#!/bin/sh
set -e

REPAIR=0
TARGET_DEV=""

for arg in "$@"; do
    case "$arg" in
        --repair|-y|-f) REPAIR=1 ;;
        --all) TARGET_DEV="--all" ;;
        -h|--help)
            echo "Usage: check-disk <device|--all> [--repair]"
            echo "Runs filesystem health checks (ext2/3/4, Btrfs, XFS, F2FS, FAT, exFAT)."
            exit 0
            ;;
        *) TARGET_DEV="$arg" ;;
    esac
done

check_one() {
    DEV="$1"
    FSTYPE=$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)
    LABEL=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)
    [ -z "$FSTYPE" ] && return 0
    [ "$FSTYPE" = "swap" ] || [ "$FSTYPE" = "crypto_LUKS" ] || [ "$FSTYPE" = "LVM2_member" ] && return 0

    # Ensure unmounted before fsck
    if findmnt -n --source "$DEV" >/dev/null 2>&1; then
        echo -e "\033[33mUnmounting $DEV before filesystem check...\033[0m"
        umount "$DEV"
    fi

    echo -e "\033[1;36m==> Checking $DEV ($FSTYPE ${LABEL:+"\"$LABEL\""}) [mode: $([ "$REPAIR" = "1" ] && echo "REPAIR" || echo "READ-ONLY CHECK")]...\033[0m"
    case "$FSTYPE" in
        ext2|ext3|ext4)
            if [ "$REPAIR" = "1" ]; then
                e2fsck -f -y "$DEV" || true
            else
                e2fsck -f -n "$DEV"
            fi
            ;;
        btrfs)
            if [ "$REPAIR" = "1" ]; then
                btrfs check --repair "$DEV"
            else
                btrfs check --readonly "$DEV"
            fi
            ;;
        xfs)
            if [ "$REPAIR" = "1" ]; then
                xfs_repair "$DEV"
            else
                xfs_repair -n "$DEV"
            fi
            ;;
        f2fs)
            if [ "$REPAIR" = "1" ]; then
                fsck.f2fs -f "$DEV"
            else
                fsck.f2fs "$DEV"
            fi
            ;;
        vfat|fat)
            fsck.vfat -n "$DEV"
            ;;
        exfat)
            fsck.exfat -n "$DEV"
            ;;
        *)
            echo "No dedicated checker configured for $FSTYPE on $DEV"
            ;;
    esac
    echo -e "\033[1;32m✓ Completed check on $DEV\033[0m"
}

if [ -z "$TARGET_DEV" ] || [ "$TARGET_DEV" = "--all" ]; then
    for dev in $(lsblk -lnp -o NAME,TYPE | awk '$2=="part" || $2=="disk" || $2=="lvm" || $2=="crypt" {print $1}'); do
        case "$dev" in
            /dev/vda*) continue ;;
        esac
        check_one "$dev"
    done
else
    case "$TARGET_DEV" in
        /dev/*) ;;
        *) TARGET_DEV="/dev/$TARGET_DEV" ;;
    esac
    check_one "$TARGET_DEV"
fi
"""#

    /// `/usr/local/bin/luks-info` — Inspects LUKS headers and LVM metadata
    public static let luksInfoScript = #"""
#!/bin/sh
if [ -n "$1" ]; then
    DEV="$1"
    case "$DEV" in
        /dev/*) ;;
        *) DEV="/dev/$DEV" ;;
    esac
    cryptsetup luksDump "$DEV"
    exit $?
fi

FOUND=0
for dev in $(lsblk -lnp -o NAME | grep -v '^/dev/vda'); do
    FSTYPE=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
    if [ "$FSTYPE" = "crypto_LUKS" ]; then
        FOUND=1
        echo -e "\033[1;33m==> LUKS Container Header on $dev:\033[0m"
        cryptsetup luksDump "$dev"
        echo ""
    fi
done

if [ "$FOUND" = "0" ]; then
    echo "No LUKS encrypted partitions detected on attached drives."
fi
"""#

    /// `/usr/local/bin/probe-disks` — Detailed non-interactive inspection report for `tuxdisk inspect`
    public static let probeDisksScript = #"""
#!/bin/sh
echo -e "\033[1;36m╭────────────────────────────────────────────────────────────────────────────╮\033[0m"
echo -e "\033[1;36m│\033[0m  \033[1;37mtuxdisk inspect\033[0m — Deep Linux Block Device & Filesystem Report             \033[1;36m│\033[0m"
echo -e "\033[1;36m╰────────────────────────────────────────────────────────────────────────────╯\033[0m"
echo ""
/usr/local/bin/disks
echo ""

for disk in $(lsblk -dnp -o NAME | grep -v '^/dev/vda' | grep -v '^/dev/loop' | grep -v '^/dev/zram'); do
    echo -e "\033[1;37mPartition Table for $disk:\033[0m"
    parted -s "$disk" print 2>/dev/null | sed 's/^/  /' || fdisk -l "$disk" 2>/dev/null | sed 's/^/  /'
done

echo -e "\033[1;37mBlock Device Signatures (blkid):\033[0m"
blkid | grep -v '^/dev/vda' | sed 's/^/  /' || echo "  (none)"
echo ""

# Check for LVM Volume Groups
if pvs 2>/dev/null | grep -q '/dev/'; then
    echo -e "\033[1;37mLVM2 Physical Volumes / Volume Groups / Logical Volumes:\033[0m"
    pvs | sed 's/^/  /'
    echo ""
    vgs | sed 's/^/  /'
    echo ""
    lvs | sed 's/^/  /'
    echo ""
fi

# Check for LUKS partitions
for dev in $(lsblk -lnp -o NAME | grep -v '^/dev/vda'); do
    FSTYPE=$(blkid -s TYPE -o value "$dev" 2>/dev/null || true)
    if [ "$FSTYPE" = "crypto_LUKS" ]; then
        echo -e "\033[1;33mLUKS Header Summary for $dev:\033[0m"
        cryptsetup luksDump "$dev" 2>/dev/null | head -n 25 | sed 's/^/  /'
        echo ""
    fi
done

# Temporarily mount read-only to report used/available space and top-level contents
echo -e "\033[1;37mFilesystem Space Usage & Top-Level Contents:\033[0m"
VM_READONLY=1 /usr/local/bin/mount-disk --auto >/dev/null 2>&1 || true
MOUNTED_LIST=$(awk '$2 ~ /^\/mnt\/disks\// {print $2}' /proc/mounts)
if [ -z "$MOUNTED_LIST" ]; then
    echo "  (No unencrypted filesystems auto-mounted)"
else
    df -hT $MOUNTED_LIST | sed 's/^/  /'
    echo ""
    for mp in $MOUNTED_LIST; do
        echo -e "  \033[1;36m$mp:\033[0m"
        ls -la "$mp" | head -n 15 | sed 's/^/    /'
        echo ""
    done
fi
/usr/local/bin/unmount-all --quiet >/dev/null 2>&1 || true
"""#
}
