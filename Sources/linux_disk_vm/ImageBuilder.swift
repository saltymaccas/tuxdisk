import Foundation

public struct VMAssetPaths: Sendable {
    public let baseDir: URL
    public var rawKernelURL: URL { baseDir.appendingPathComponent("vmlinux.raw") }
    public var bootInitrdURL: URL { baseDir.appendingPathComponent("initramfs-boot.img") }
    public var rootDiskURL: URL { baseDir.appendingPathComponent("rootfs.img") }
    public var readyMarkerURL: URL { baseDir.appendingPathComponent(".ready-v1") }

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

    /// Resolves the assets directory, respecting `LINUX_DISK_VM_HOME` and `SUDO_USER` so running with `sudo` finds the user's setup files.
    public static func defaultAssetsDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let customHome = env["LINUX_DISK_VM_HOME"], !customHome.isEmpty {
            return URL(fileURLWithPath: customHome)
        }
        if let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty, sudoUser != "root" {
            let sudoHome = URL(fileURLWithPath: "/Users/\(sudoUser)")
            if FileManager.default.fileExists(atPath: sudoHome.path) {
                return sudoHome.appendingPathComponent(".local/share/linux-disk-vm")
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/linux-disk-vm")
    }

    @MainActor
    public static func ensurePrepared(assetsDir: URL = defaultAssetsDirectory(), force: Bool = false) async throws -> VMAssetPaths {
        let paths = VMAssetPaths(baseDir: assetsDir)
        if paths.isReady && !force {
            return paths
        }

        let fm = FileManager.default
        try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        if force {
            try? fm.removeItem(at: paths.readyMarkerURL)
            try? fm.removeItem(at: paths.rootDiskURL)
            try? fm.removeItem(at: paths.rawKernelURL)
            try? fm.removeItem(at: paths.bootInitrdURL)
        }

        print("==> Preparing lightweight Alpine Linux VM (aarch64) in \(assetsDir.path)...")

        let netbootKernelURL = assetsDir.appendingPathComponent("vmlinuz-virt.netboot")
        let netbootInitrdURL = assetsDir.appendingPathComponent("initramfs-virt.netboot")
        let minirootfsURL = assetsDir.appendingPathComponent("alpine-minirootfs.tar.gz")

        // 1. Download Alpine netboot kernel, netboot initramfs, and minirootfs if not cached
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

        // 2. Decompress kernel into raw ARM64 Image format for VZLinuxBootLoader
        let bootstrapKernelURL = assetsDir.appendingPathComponent("vmlinux-bootstrap.raw")
        print("  -> Extracting uncompressed ARM64 kernel Image...")
        _ = try KernelExtractor.ensureUncompressedKernel(at: netbootKernelURL, outputURL: bootstrapKernelURL)

        // 3. Write guest scripts to staging folder shared via VirtioFS during bootstrap
        let scriptsDir = assetsDir.appendingPathComponent("guest-scripts")
        try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try writeExecutableScript(GuestScripts.vmInitScript, to: scriptsDir.appendingPathComponent("vm-init"))
        try writeExecutableScript(GuestScripts.disksCommandScript, to: scriptsDir.appendingPathComponent("disks"))
        try writeExecutableScript(GuestScripts.mountDiskScript, to: scriptsDir.appendingPathComponent("mount-disk"))
        try writeExecutableScript(GuestScripts.unmountAllScript, to: scriptsDir.appendingPathComponent("unmount-all"))

        // 4. Create 2 GB sparse rootfs.img file
        print("  -> Creating 2 GB sparse root disk image (rootfs.img)...")
        try createSparseDiskImage(at: paths.rootDiskURL, sizeBytes: 2 * 1024 * 1024 * 1024)

        // 5. Build bootstrap initramfs by concatenating initramfs-virt.netboot + custom overlay /init
        let bootstrapInitrdURL = assetsDir.appendingPathComponent("initramfs-bootstrap.img")
        try buildCombinedInitramfs(
            baseInitrd: netbootInitrdURL,
            initScriptContent: bootstrapOverlayInitScript,
            outputURL: bootstrapInitrdURL
        )

        // 6. Boot the VM in automated setup mode to format rootfs.img and install packages
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

        // 7. Extract the installed kernel & initramfs from the provisioned rootfs so kernel & /lib/modules match 100%
        let installedKernelURL = assetsDir.appendingPathComponent("installed-vmlinuz-virt")
        let installedInitrdURL = assetsDir.appendingPathComponent("installed-initramfs-virt")

        let sourceKernelForBoot = fm.fileExists(atPath: installedKernelURL.path) ? installedKernelURL : netbootKernelURL
        let sourceInitrdForBoot = fm.fileExists(atPath: installedInitrdURL.path) ? installedInitrdURL : netbootInitrdURL

        try? fm.removeItem(at: paths.rawKernelURL)
        _ = try KernelExtractor.ensureUncompressedKernel(at: sourceKernelForBoot, outputURL: paths.rawKernelURL)

        try buildCombinedInitramfs(
            baseInitrd: sourceInitrdForBoot,
            initScriptContent: runtimeOverlayInitScript,
            outputURL: paths.bootInitrdURL
        )

        // Clean up temporary bootstrap artifacts
        try? fm.removeItem(at: bootstrapKernelURL)
        try? fm.removeItem(at: bootstrapInitrdURL)
        try? fm.removeItem(at: installedKernelURL)
        try? fm.removeItem(at: installedInitrdURL)
        try? fm.removeItem(at: setupSuccessMarker)

        try Data("ready\n".utf8).write(to: paths.readyMarkerURL)
        print("==> Setup complete! Lightweight Linux VM image is ready at \(assetsDir.path)")
        return paths
    }

    private static func writeExecutableScript(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private static func createSparseDiskImage(at url: URL, sizeBytes: Int64) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        fm.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(sizeBytes))
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

    /// Concatenates `baseInitrd` (`cpio.gz`) with a newly generated `cpio.gz` containing `/init`
    private static func buildCombinedInitramfs(baseInitrd: URL, initScriptContent: String, outputURL: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("linux-disk-vm-cpio-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let initFile = tempDir.appendingPathComponent("init")
        try writeExecutableScript(initScriptContent, to: initFile)

        let overlayGz = tempDir.appendingPathComponent("overlay.cpio.gz")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.currentDirectoryURL = tempDir
        proc.arguments = ["-c", "echo init | /usr/bin/cpio -o -H newc 2>/dev/null | /usr/bin/gzip -1 > \"\(overlayGz.path)\""]
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

    /// Fast runtime `/init` inside `initramfs-boot.img`: loads virtio_blk + ext4, mounts `/dev/vda`, and `switch_root`s into `/sbin/vm-init`.
    private static let runtimeOverlayInitScript = #"""
#!/bin/sh
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev

for mod in virtio_pci virtio_blk ext4; do
    modprobe "$mod" 2>/dev/null || true
done

mdev -s 2>/dev/null || true

# Wait up to 3 seconds for /dev/vda
i=0
while [ ! -b /dev/vda ] && [ $i -lt 30 ]; do
    sleep 0.1
    mdev -s 2>/dev/null || true
    i=$((i + 1))
done

mkdir -p /sysroot
mount -t ext4 -o rw /dev/vda /sysroot

mount --move /dev /sysroot/dev 2>/dev/null || true
mount --move /proc /sysroot/proc 2>/dev/null || true
mount --move /sys /sysroot/sys 2>/dev/null || true

exec switch_root /sysroot /sbin/vm-init
"""#

    /// One-time bootstrap `/init` that formats `/dev/vda` as ext4 and installs Alpine + all Linux filesystem & volume packages.
    private static let bootstrapOverlayInitScript = #"""
#!/bin/sh
set -e
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"

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
udhcpc -i eth0 -q -s /usr/share/udhcpc/default.script 2>/dev/null || udhcpc -i eth0 -q

echo "==> [Bootstrap VM] Mounting host setup share..."
mount -t virtiofs setup /mnt/setup

echo "==> [Bootstrap VM] Extracting Alpine minirootfs in RAM..."
mkdir -p /tmp/stage
tar -xzf /mnt/setup/alpine-minirootfs.tar.gz -C /tmp/stage
cp /etc/resolv.conf /tmp/stage/etc/resolv.conf

mount --bind /proc /tmp/stage/proc
mount --bind /sys /tmp/stage/sys
mount --bind /dev /tmp/stage/dev

echo "==> [Bootstrap VM] Installing kernel modules and filesystem packages via apk..."
chroot /tmp/stage /bin/sh -e <<'CHROOT_EOF'
export PATH="/usr/sbin:/usr/bin:/sbin:/bin"
apk update
apk add --no-cache \
    linux-virt \
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
CHROOT_EOF

echo "==> [Bootstrap VM] Formatting /dev/vda (rootfs.img) as ext4..."
chroot /tmp/stage /sbin/mkfs.ext4 -F -q -L "linux-vm-root" /dev/vda

umount /tmp/stage/dev
umount /tmp/stage/sys
umount /tmp/stage/proc

echo "==> [Bootstrap VM] Populating persistent rootfs on /dev/vda..."
mount -t ext4 /dev/vda /mnt/target
cp -a /tmp/stage/. /mnt/target/
mkdir -p /mnt/target/proc /mnt/target/sys /mnt/target/dev /mnt/target/run /mnt/target/tmp /mnt/target/mnt/host /mnt/target/mnt/disks /mnt/target/usr/local/bin

# Install our custom init and disk management scripts
cp /mnt/setup/guest-scripts/vm-init /mnt/target/sbin/vm-init
chmod 755 /mnt/target/sbin/vm-init

for s in disks mount-disk unmount-all; do
    cp "/mnt/setup/guest-scripts/$s" "/mnt/target/usr/local/bin/$s"
    chmod 755 "/mnt/target/usr/local/bin/$s"
done

# Configure root shell prompt and environment
cat > /mnt/target/root/.bash_profile <<'PROFILE_EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PS1='\[\033[1;36m\]linux-disk-vm\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]# '
alias ll='ls -lah --color=auto'
alias ls='ls --color=auto'
PROFILE_EOF

# Export matching kernel & initramfs from linux-virt package back to host
if [ -f /mnt/target/boot/vmlinuz-virt ]; then
    cp /mnt/target/boot/vmlinuz-virt /mnt/setup/installed-vmlinuz-virt
fi
if [ -f /mnt/target/boot/initramfs-virt ]; then
    cp /mnt/target/boot/initramfs-virt /mnt/setup/installed-initramfs-virt
fi

sync
umount /mnt/target
touch /mnt/setup/.setup-done
sync
umount /mnt/setup
echo "==> [Bootstrap VM] Provisioning finished successfully!"
poweroff -f
"""#
}
