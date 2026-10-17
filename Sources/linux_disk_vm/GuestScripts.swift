import Foundation

public enum GuestScripts {
    /// The `/sbin/vm-init` script installed inside `rootfs.img` that runs as PID 1 on every boot.
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

# Remount rootfs read-write
mount -o remount,rw / 2>/dev/null

# Set hostname
hostname linux-disk-vm 2>/dev/null

# Parse kernel cmdline parameters
COLS=80
ROWS=24
READONLY_MODE=0
AUTO_MOUNT=0
HOST_PATH_DISPLAY=""
EXEC_CMD_B64=""

for param in $(cat /proc/cmdline); do
    case "$param" in
        vm.cols=*) COLS="${param#vm.cols=}" ;;
        vm.rows=*) ROWS="${param#vm.rows=}" ;;
        vm.ro=1) READONLY_MODE=1 ;;
        vm.automount=1) AUTO_MOUNT=1 ;;
        vm.hostpath=*) HOST_PATH_DISPLAY="${param#vm.hostpath=}" ;;
        vm.exec64=*) EXEC_CMD_B64="${param#vm.exec64=}" ;;
        TERM=*) export TERM="${param#TERM=}" ;;
    esac
done

export VM_READONLY="$READONLY_MODE"
export VM_HOST_PATH="$HOST_PATH_DISPLAY"

# Configure terminal window size on console
if [ -c /dev/hvc0 ]; then
    stty -F /dev/hvc0 cols "$COLS" rows "$ROWS" 2>/dev/null
fi

# Load filesystem, volume manager, encryption, and virtio kernel modules
for mod in virtio_pci virtio_blk virtio_net virtiofs \
           dm-mod dm-crypt cryptd \
           ext4 crc32c btrfs xfs f2fs \
           loop vfat exfat fuse; do
    modprobe "$mod" 2>/dev/null
done

# Populate device nodes and scan LVM volume groups
mdev -s 2>/dev/null
mkdir -p /run/lvm /run/cryptsetup
vgscan --mknodes >/dev/null 2>&1
vgchange -ay >/dev/null 2>&1

# Bring up loopback and NAT network in background
ip link set lo up 2>/dev/null
if ip link show eth0 >/dev/null 2>&1; then
    ip link set eth0 up 2>/dev/null
    udhcpc -i eth0 -b -q >/dev/null 2>&1 &
fi

# Mount macOS shared directory via VirtioFS at /mnt/host
if mount -t virtiofs host /mnt/host 2>/dev/null; then
    true
fi

# Auto-mount non-encrypted external partitions if requested
if [ "$AUTO_MOUNT" = "1" ]; then
    /usr/local/bin/mount-disk --auto >/dev/null 2>&1
fi

cleanup_and_poweroff() {
    echo ""
    echo -e "\033[1;34m==> Syncing and safely unmounting disks...\033[0m"
    /usr/local/bin/unmount-all --quiet
    umount /mnt/host 2>/dev/null
    mount -o remount,ro / 2>/dev/null
    sync
    poweroff -f
}

# If a one-shot command was passed via --command / -e, execute it and exit
if [ -n "$EXEC_CMD_B64" ]; then
    EXEC_CMD=$(printf "%s" "$EXEC_CMD_B64" | base64 -d 2>/dev/null)
    if [ -c /dev/hvc0 ]; then
        setsid sh -c "$EXEC_CMD" </dev/hvc0 >/dev/hvc0 2>&1
    else
        sh -c "$EXEC_CMD"
    fi
    cleanup_and_poweroff
    exit 0
fi

# Print interactive welcome banner & disk status
clear 2>/dev/null
echo -e "\033[1;36m╭──────────────────────────────────────────────────────────────────────────╮\033[0m"
echo -e "\033[1;36m│\033[0m  \033[1;37mlinux-disk-vm\033[0m — Lightweight Linux Filesystem & Volume Access VM         \033[1;36m│\033[0m"
echo -e "\033[1;36m│\033[0m  Supported: \033[32mext2/3/4\033[0m · \033[32mBtrfs\033[0m · \033[32mXFS\033[0m · \033[32mF2FS\033[0m · \033[33mLUKS1/2\033[0m · \033[33mLVM2\033[0m               \033[1;36m│\033[0m"
echo -e "\033[1;36m╰──────────────────────────────────────────────────────────────────────────╯\033[0m"

if mountpoint -q /mnt/host 2>/dev/null; then
    echo -e "  \033[1;32m● macOS Host Share:\033[0m \033[1m/mnt/host\033[0m -> ${VM_HOST_PATH:-macOS shared folder}"
fi
if [ "$READONLY_MODE" = "1" ]; then
    echo -e "  \033[1;33m● Access Mode:\033[0m      \033[1;33mREAD-ONLY\033[0m (external drives are write-protected)"
else
    echo -e "  \033[1;32m● Access Mode:\033[0m      \033[1;32mREAD-WRITE\033[0m"
fi
echo ""
/usr/local/bin/disks
echo ""
echo -e "\033[1;37mQuick Commands:\033[0m"
echo -e "  \033[36mdisks\033[0m                        Show attached drives, filesystems, LUKS & LVM status"
echo -e "  \033[36mmount-disk <dev> [dir]\033[0m       Unlock LUKS / activate LVM / mount partition (e.g. \033[36mmount-disk /dev/vdb1\033[0m)"
echo -e "  \033[36mmount-disk --all\033[0m             Mount all detected external partitions under \033[1m/mnt/disks/\033[0m"
echo -e "  \033[36munmount-all\033[0m                  Safely unmount all drives, close LUKS & deactivate LVM"
echo -e "  \033[36mmc\033[0m                           Launch Midnight Commander dual-pane file manager"
echo -e "  \033[36mexit\033[0m                         Safely sync, unmount all disks, and shut down VM"
echo ""

# Launch interactive root shell on /dev/hvc0
cd /mnt/disks 2>/dev/null || cd /root
if [ -c /dev/hvc0 ]; then
    setsid /bin/bash --login </dev/hvc0 >/dev/hvc0 2>&1
else
    /bin/bash --login
fi

cleanup_and_poweroff
"""#

    /// `/usr/local/bin/disks` — Displays attached external block devices (excluding `/dev/vda` VM root disk).
    public static let disksCommandScript = #"""
#!/bin/sh
echo -e "\033[1;37mAttached External Drives & Volumes:\033[0m"
echo "──────────────────────────────────────────────────────────────────────────"
# Check if any external disks beyond /dev/vda exist
EXT_DEVS=$(lsblk -dn -o NAME | grep -v '^vda$' | grep -v '^loop' | grep -v '^zram')
if [ -z "$EXT_DEVS" ]; then
    echo -e "  \033[33m(No external drives attached. Pass a disk on macOS, e.g. 'sudo linux-disk-vm /dev/disk4')\033[0m"
    echo "  Note: Internal VM root disk is /dev/vda (hidden from this list)."
else
    lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,UUID | awk '
        NR==1 { printf "  \033[1;37m%s\033[0m\n", $0; next }
        /^vda/ || /^[├└│].*vda/ { next }
        { printf "  %s\n", $0 }
    '
fi
echo "──────────────────────────────────────────────────────────────────────────"
"""#

    /// `/usr/local/bin/mount-disk` — Smart mounter for ext2/3/4, btrfs, xfs, f2fs, LUKS1/2, and LVM2.
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

MOUNT_OPTS=""
if [ "${VM_READONLY:-0}" = "1" ]; then
    MOUNT_OPTS="-o ro"
fi

mount_single_fs() {
    DEV="$1"
    TARGET="$2"
    FSTYPE=$(blkid -s TYPE -o value "$DEV" 2>/dev/null || true)
    LABEL=$(blkid -s LABEL -o value "$DEV" 2>/dev/null || true)

    if [ -z "$FSTYPE" ]; then
        echo "Skipping $DEV: no recognizable filesystem signature found."
        return 1
    fi

    case "$FSTYPE" in
        crypto_LUKS)
            MAP_NAME="luks_$(basename "$DEV")"
            if [ ! -e "/dev/mapper/$MAP_NAME" ]; then
                echo -e "\033[1;33m==> Unlocking LUKS volume on $DEV ($MAP_NAME)...\033[0m"
                if [ "${VM_READONLY:-0}" = "1" ]; then
                    cryptsetup open --readonly "$DEV" "$MAP_NAME"
                else
                    cryptsetup open "$DEV" "$MAP_NAME"
                fi
            fi
            # Rescan LVM in case the LUKS container holds an LVM PV
            vgscan --mknodes >/dev/null 2>&1 || true
            vgchange -ay >/dev/null 2>&1 || true
            sleep 0.2
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

    # Check if already mounted
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

    /// `/usr/local/bin/unmount-all` — Safely unmounts all external disks, deactivates LVM, and closes LUKS volumes.
    public static let unmountAllScript = #"""
#!/bin/sh
QUIET=0
[ "$1" = "--quiet" ] && QUIET=1

log() {
    [ "$QUIET" = "0" ] && echo -e "$1"
}

sync

# Unmount everything under /mnt/disks
for mp in $(awk '$2 ~ /^\/mnt\/disks\// {print $2}' /proc/mounts | sort -r); do
    if umount "$mp" 2>/dev/null; then
        log "\033[32m✓ Unmounted $mp\033[0m"
        rmdir "$mp" 2>/dev/null || true
    fi
done

# Also unmount any /dev/vd[b-z]* or /dev/mapper/* mounted elsewhere (except /)
for mp in $(awk '($1 ~ /^\/dev\/vd[b-z]/ || $1 ~ /^\/dev\/mapper\//) && $2 != "/" {print $2}' /proc/mounts | sort -r); do
    if umount "$mp" 2>/dev/null; then
        log "\033[32m✓ Unmounted $mp\033[0m"
    fi
done

# Deactivate LVM volume groups
vgchange -an >/dev/null 2>&1 || true

# Close any open LUKS containers
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
}
