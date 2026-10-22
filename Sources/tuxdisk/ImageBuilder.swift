import Foundation

public struct VMAssetPaths: Sendable {
    public let baseDir: URL
    public var rawKernelURL: URL { baseDir.appendingPathComponent("vmlinux.raw") }
    public var baseInitrdURL: URL { baseDir.appendingPathComponent("initramfs-base.img") }
    public var bootInitrdURL: URL { baseDir.appendingPathComponent("initramfs-boot.img") }
    public var rootDiskURL: URL { baseDir.appendingPathComponent("rootfs.img") }
    public var readyMarkerURL: URL { baseDir.appendingPathComponent(".ready-v1") }
    public var scriptsHashURL: URL { baseDir.appendingPathComponent(".scripts-hash") }

    public var isReady: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: rawKernelURL.path)
            && fm.fileExists(atPath: bootInitrdURL.path)
            && fm.fileExists(atPath: rootDiskURL.path)
            && fm.fileExists(atPath: readyMarkerURL.path)
    }
}

public enum ImageBuilderError: LocalizedError {
    case downloadFailed(String, Int32)
    case cpioCreationFailed(String)
    case provisioningFailed(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url, let code):
            return "Failed to download \(url) (curl exit code \(code)). Check your internet connection."
        case .cpioCreationFailed(let detail):
            return "Failed to build initramfs overlay: \(detail)"
        case .provisioningFailed(let detail):
            return "VM rootfs provisioning failed: \(detail)"
        }
    }
}

public enum ImageBuilder {
    public static let alpineBranch = "v3.21"
    public static let alpineVersion = "3.21.3"
    public static let alpineMirror = "https://dl-cdn.alpinelinux.org/alpine"

    /// Resolves the assets directory, respecting `TUXDISK_HOME`, `LINUX_DISK_VM_HOME`, project-local `.vm-assets`, and `SUDO_USER`.
    public static func defaultAssetsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let customHome = env["TUXDISK_HOME"] ?? env["LINUX_DISK_VM_HOME"], !customHome.isEmpty {
            return URL(fileURLWithPath: customHome)
        }
        if let execPath = CommandLine.arguments.first {
            let execURL = URL(fileURLWithPath: execPath).standardizedFileURL
            let repoCandidate = execURL.deletingLastPathComponent().deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: repoCandidate.appendingPathComponent("Package.swift").path) {
                return repoCandidate.appendingPathComponent(".vm-assets")
            }
        }
        if let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty, sudoUser != "root" {
            let sudoHome = URL(fileURLWithPath: "/Users/\(sudoUser)")
            if FileManager.default.fileExists(atPath: sudoHome.path) {
                return sudoHome.appendingPathComponent(".local/share/tuxdisk")
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/tuxdisk")
    }

    @MainActor
    public static func ensurePrepared(assetsDir: URL = defaultAssetsDirectory(), force: Bool = false) async throws -> VMAssetPaths {
        let paths = VMAssetPaths(baseDir: assetsDir)
        let fm = FileManager.default

        if paths.isReady && !force {
            // Preserve base initrd if upgrading from earlier build
            if !fm.fileExists(atPath: paths.baseInitrdURL.path) {
                try? fm.copyItem(at: paths.bootInitrdURL, to: paths.baseInitrdURL)
            }
            try syncRuntimeOverlayIfNeeded(paths: paths)
            return paths
        }

        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        if force {
            try? fm.removeItem(at: paths.readyMarkerURL)
            try? fm.removeItem(at: paths.rootDiskURL)
            try? fm.removeItem(at: paths.rawKernelURL)
            try? fm.removeItem(at: paths.baseInitrdURL)
            try? fm.removeItem(at: paths.bootInitrdURL)
            try? fm.removeItem(at: paths.scriptsHashURL)
        }

        ConsoleStyle.info("Preparing tuxdisk Alpine Linux VM (aarch64) in \(assetsDir.path)...")

        let netbootKernelURL = assetsDir.appendingPathComponent("vmlinuz-virt.netboot")
        let netbootInitrdURL = assetsDir.appendingPathComponent("initramfs-virt.netboot")
        let minirootfsURL = assetsDir.appendingPathComponent("alpine-minirootfs.tar.gz")

        if !fm.fileExists(atPath: netbootKernelURL.path) {
            let url = "\(alpineMirror)/\(alpineBranch)/releases/aarch64/netboot/vmlinuz-virt"
            print("  -> Downloading Alpine Linux arm64 kernel (vmlinuz-virt)...")
            try downloadFile(from: url, to: netbootKernelURL)
        }

        if !fm.fileExists(atPath: netbootInitrdURL.path) {
            let url = "\(alpineMirror)/\(alpineBranch)/releases/aarch64/netboot/initramfs-virt"
            print("  -> Downloading Alpine Linux arm64 initramfs (initramfs-virt)...")
            try downloadFile(from: url, to: netbootInitrdURL)
        }

        if !fm.fileExists(atPath: minirootfsURL.path) {
            let url = "\(alpineMirror)/\(alpineBranch)/releases/aarch64/alpine-minirootfs-\(alpineVersion)-aarch64.tar.gz"
            print("  -> Downloading Alpine minirootfs (\(alpineVersion))...")
            try downloadFile(from: url, to: minirootfsURL)
        }

        let bootstrapKernelURL = assetsDir.appendingPathComponent("vmlinux-bootstrap.raw")
        print("  -> Extracting uncompressed ARM64 kernel Image...")
        _ = try KernelExtractor.ensureUncompressedKernel(at: netbootKernelURL, outputURL: bootstrapKernelURL)

        let scriptsDir = assetsDir.appendingPathComponent("guest-scripts")
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        for item in GuestScripts.allFiles {
            let name = URL(fileURLWithPath: item.guestPath).lastPathComponent
            try writeExecutableScript(item.content, to: scriptsDir.appendingPathComponent(name))
        }

        print("  -> Creating 2 GB sparse root disk image (rootfs.img)...")
        try createSparseDiskImage(at: paths.rootDiskURL, sizeBytes: 2 * 1024 * 1024 * 1024)

        let bootstrapInitrdURL = assetsDir.appendingPathComponent("initramfs-bootstrap.img")
        try buildCombinedInitramfs(
            baseInitrd: netbootInitrdURL,
            initScriptContent: bootstrapOverlayInitScript,
            extraFiles: [],
            outputURL: bootstrapInitrdURL
        )

        let setupSuccessMarker = assetsDir.appendingPathComponent(".setup-done")
        try? fm.removeItem(at: setupSuccessMarker)

        print("  -> Booting VM to format rootfs.img and install filesystem tools")
        print("     (ext2/3/4, Btrfs, XFS, F2FS, LUKS/cryptsetup, LVM2, Midnight Commander, rsync)...")

        let setupOptions = VMConfigurationOptions(
            kernelURL: bootstrapKernelURL,
            initrdURL: bootstrapInitrdURL,
            rootDiskURL: paths.rootDiskURL,
            rootDiskReadOnly: false,
            externalDisks: [],
            sharedDirectories: [("setup", assetsDir, false)],
            cpuCount: 2,
            memorySizeMB: 2048,
            kernelCommandLine: "console=hvc0 quiet vm.setup=1",
            rawTerminal: false
        )

        try await VMRunner.run(options: setupOptions)

        guard fm.fileExists(atPath: setupSuccessMarker.path) else {
            throw ImageBuilderError.provisioningFailed("Bootstrap VM exited before completing setup. Check network connectivity.")
        }

        let installedKernelURL = assetsDir.appendingPathComponent("installed-vmlinuz-virt")
        let installedInitrdURL = assetsDir.appendingPathComponent("installed-initramfs-virt")

        let sourceKernelForBoot = fm.fileExists(atPath: installedKernelURL.path) ? installedKernelURL : netbootKernelURL
        let sourceInitrdForBoot = fm.fileExists(atPath: installedInitrdURL.path) ? installedInitrdURL : netbootInitrdURL

        try? fm.removeItem(at: paths.rawKernelURL)
        _ = try KernelExtractor.ensureUncompressedKernel(at: sourceKernelForBoot, outputURL: paths.rawKernelURL)

        try? fm.removeItem(at: paths.baseInitrdURL)
        try fm.copyItem(at: sourceInitrdForBoot, to: paths.baseInitrdURL)

        try syncRuntimeOverlayIfNeeded(paths: paths, forceRebuild: true)

        try? fm.removeItem(at: bootstrapKernelURL)
        try? fm.removeItem(at: bootstrapInitrdURL)
        try? fm.removeItem(at: installedKernelURL)
        try? fm.removeItem(at: installedInitrdURL)
        try? fm.removeItem(at: setupSuccessMarker)

        try Data("ready\n".utf8).write(to: paths.readyMarkerURL)
        ConsoleStyle.success("Setup complete! tuxdisk VM image is ready at \(assetsDir.path)")
        return paths
    }

    /// Rebuilds `initramfs-boot.img` with the latest `GuestScripts` whenever scripts change
    public static func syncRuntimeOverlayIfNeeded(paths: VMAssetPaths, forceRebuild: Bool = false) throws {
        let fm = FileManager.default
        let combinedContent = GuestScripts.allFiles.map { "\($0.guestPath):\($0.content)" }.joined(separator: "\n---\n") + runtimeOverlayInitScript
        let currentHash = String(combinedContent.hashValue)

        if !forceRebuild,
           fm.fileExists(atPath: paths.bootInitrdURL.path),
           let savedHash = try? String(contentsOf: paths.scriptsHashURL, encoding: .utf8),
           savedHash == currentHash {
            return
        }

        let baseInitrd = fm.fileExists(atPath: paths.baseInitrdURL.path) ? paths.baseInitrdURL : paths.bootInitrdURL
        guard fm.fileExists(atPath: baseInitrd.path) else { return }

        let tempOut = paths.baseDir.appendingPathComponent("initramfs-boot.img.tmp")
        try buildCombinedInitramfs(
            baseInitrd: baseInitrd,
            initScriptContent: runtimeOverlayInitScript,
            extraFiles: GuestScripts.allFiles,
            outputURL: tempOut
        )

        if fm.fileExists(atPath: paths.bootInitrdURL.path) {
            try fm.removeItem(at: paths.bootInitrdURL)
        }
        try fm.moveItem(at: tempOut, to: paths.bootInitrdURL)
        try Data(currentHash.utf8).write(to: paths.scriptsHashURL)
    }

    public static func createSparseDiskImage(at url: URL, sizeBytes: Int64) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(sizeBytes))
    }

    private static func writeExecutableScript(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func downloadFile(from urlString: String, to destinationURL: URL) throws {
        let tempURL = destinationURL.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: tempURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-fL", "--progress-bar", "-o", tempURL.path, urlString]
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ImageBuilderError.downloadFailed(urlString, proc.terminationStatus)
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
    }

    private static func buildCombinedInitramfs(
        baseInitrd: URL,
        initScriptContent: String,
        extraFiles: [(guestPath: String, content: String)],
        outputURL: URL
    ) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("tuxdisk-cpio-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let initFile = tempDir.appendingPathComponent("init")
        try writeExecutableScript(initScriptContent, to: initFile)

        for item in extraFiles {
            let dest = tempDir.appendingPathComponent("overlay-files").appendingPathComponent(item.guestPath)
            try writeExecutableScript(item.content, to: dest)
        }

        let overlayGz = tempDir.appendingPathComponent("overlay.cpio.gz")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.currentDirectoryURL = tempDir
        proc.arguments = [
            "-c",
            "find init overlay-files -print 2>/dev/null | /usr/bin/cpio -o -H newc 2>/dev/null | /usr/bin/gzip -1 > \"\(overlayGz.path)\""
        ]
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fm.fileExists(atPath: overlayGz.path) else {
            throw ImageBuilderError.cpioCreationFailed("cpio exited with code \(proc.terminationStatus)")
        }

        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }
        try fm.copyItem(at: baseInitrd, to: outputURL)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outHandle.close() }
        try outHandle.seekToEnd()
        let overlayData = try Data(contentsOf: overlayGz)
        try outHandle.write(contentsOf: overlayData)
    }

    private static let runtimeOverlayInitScript = #"""
#!/bin/sh
/bin/busybox mkdir -p /bin /sbin /usr/bin /usr/sbin /proc /sys /dev /ro /rw /sysroot
/bin/busybox --install -s
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
trap 'poweroff -f' EXIT

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

for mod in virtio_pci virtio_blk ext4 crc32c overlay; do
    modprobe "$mod" 2>/dev/null || true
done

mdev -s 2>/dev/null || true

i=0
while [ ! -b /dev/vda ] && [ $i -lt 30 ]; do
    sleep 0.1
    mdev -s 2>/dev/null || true
    i=$((i + 1))
done

if mount -t ext4 -o ro,noload /dev/vda /ro 2>/dev/null || mount -t ext4 -o ro /dev/vda /ro 2>/dev/null; then
    mount -t tmpfs -o size=256M,mode=0755 tmpfs /rw
    mkdir -p /rw/upper /rw/work
    if mount -t overlay overlay -o lowerdir=/ro,upperdir=/rw/upper,workdir=/rw/work /sysroot 2>/dev/null; then
        mkdir -p /sysroot/.ro /sysroot/.rw
        mount -o move /ro /sysroot/.ro 2>/dev/null || true
        mount -o move /rw /sysroot/.rw 2>/dev/null || true
    else
        umount /ro 2>/dev/null || true
        mount -t ext4 -o rw /dev/vda /sysroot
    fi
else
    mount -t ext4 -o rw /dev/vda /sysroot
fi

# Sync latest guest scripts from overlay-files into rootfs
if [ -d /overlay-files ]; then
    cp -af /overlay-files/. /sysroot/ 2>/dev/null || true
fi

mount -o move /dev /sysroot/dev 2>/dev/null || true
mount -o move /proc /sysroot/proc 2>/dev/null || true
mount -o move /sys /sysroot/sys 2>/dev/null || true

trap - EXIT
exec switch_root /sysroot /sbin/vm-init
"""#

    private static let bootstrapOverlayInitScript = #"""
#!/bin/sh
/bin/busybox mkdir -p /bin /sbin /usr/bin /usr/sbin /proc /sys /dev /tmp /mnt/setup /mnt/target
/bin/busybox --install -s
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
set -e
trap 'echo "==> [Bootstrap VM] Error occurred, shutting down..."; poweroff -f' EXIT

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /tmp /mnt/setup /mnt/target
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /tmp

echo "==> [Bootstrap VM] Loading kernel modules..."
for mod in virtio_pci virtio_blk virtio_net virtiofs ext4 crc32c; do
    modprobe "$mod" 2>/dev/null || true
done
mdev -s 2>/dev/null || true

echo "==> [Bootstrap VM] Configuring NAT networking..."
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -f -q -s /usr/share/udhcpc/default.script 2>/dev/null || udhcpc -i eth0 -f -q

echo "==> [Bootstrap VM] Mounting host setup share..."
mount -t virtiofs setup /mnt/setup

echo "==> [Bootstrap VM] Extracting Alpine minirootfs in RAM..."
mkdir -p /tmp/stage
tar -xzf /mnt/setup/alpine-minirootfs.tar.gz -C /tmp/stage
cp /etc/resolv.conf /tmp/stage/etc/resolv.conf

mount -o bind /proc /tmp/stage/proc
mount -o bind /sys /tmp/stage/sys
mount -o bind /dev /tmp/stage/dev

echo "==> [Bootstrap VM] Installing kernel modules and filesystem packages via apk..."
chroot /tmp/stage /bin/sh -e <<'CHROOT_EOF'
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
apk update
apk add --no-cache \
    linux-virt \
    mkinitfs \
    e2fsprogs e2fsprogs-extra \
    btrfs-progs \
    xfsprogs \
    f2fs-tools \
    cryptsetup \
    lvm2 device-mapper \
    util-linux lsblk blkid findmnt \
    parted gptfdisk \
    dosfstools exfatprogs ntfs-3g \
    rsync file tree mc nano \
    bash coreutils grep sed gawk tar gzip zstd xz

mkdir -p /etc/mkinitfs
echo 'features="base virtio ext4 btrfs xfs lvm cryptsetup"' > /etc/mkinitfs/mkinitfs.conf
KVER=$(ls /lib/modules | head -n 1)
mkinitfs -o /boot/initramfs-virt "$KVER"
CHROOT_EOF

echo "==> [Bootstrap VM] Preparing rootfs files in /tmp/stage..."
umount /tmp/stage/dev
umount /tmp/stage/sys
umount /tmp/stage/proc

mkdir -p /tmp/stage/proc /tmp/stage/sys /tmp/stage/dev /tmp/stage/run /tmp/stage/tmp /tmp/stage/mnt/host /tmp/stage/mnt/disks /tmp/stage/usr/local/bin

cp /mnt/setup/guest-scripts/vm-init /tmp/stage/sbin/vm-init
chmod 755 /tmp/stage/sbin/vm-init

for s in disks mount-disk unmount-all check-disk luks-info probe-disks fs-bridge; do
    if [ -f "/mnt/setup/guest-scripts/$s" ]; then
        cp "/mnt/setup/guest-scripts/$s" "/tmp/stage/usr/local/bin/$s"
        chmod 755 "/tmp/stage/usr/local/bin/$s"
    fi
done

if [ -f /tmp/stage/boot/vmlinuz-virt ]; then
    cp /tmp/stage/boot/vmlinuz-virt /mnt/setup/installed-vmlinuz-virt
fi
if [ -f /tmp/stage/boot/initramfs-virt ]; then
    cp /tmp/stage/boot/initramfs-virt /mnt/setup/installed-initramfs-virt
fi

echo "==> [Bootstrap VM] Writing ext4 root filesystem to /dev/vda (rootfs.img)..."
LD_LIBRARY_PATH="/tmp/stage/lib:/tmp/stage/usr/lib" /tmp/stage/sbin/mkfs.ext4 -F -q -L "tuxdisk-root" -d /tmp/stage /dev/vda

sync
touch /mnt/setup/.setup-done
sync
umount /mnt/setup
echo "==> [Bootstrap VM] Provisioning finished successfully!"
trap - EXIT
poweroff -f
"""#
}
