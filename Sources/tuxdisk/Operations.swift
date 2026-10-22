import Foundation
import Virtualization

public enum Operations {
    /// Runs a one-shot command inside the VM with the specified disks and options
    @MainActor
    public static func runOneShotCommand(
        disks: [String],
        readOnly: Bool,
        allowInternal: Bool = false,
        shareURL: URL? = nil,
        shareReadOnly: Bool = false,
        command: String,
        interactiveTTY: Bool = false,
        quietLogs: Bool = false
    ) async throws {
        let assets = try await ImageBuilder.ensurePrepared(force: false)
        let hostShareURL = shareURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
        let winSize = TerminalManager.currentWindowSize()
        let termEnv = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"
        let b64 = Data(command.utf8).base64EncodedString()

        let cmdline = [
            "console=hvc0",
            "quiet",
            "TERM=\(termEnv)",
            "vm.cols=\(winSize.cols)",
            "vm.rows=\(winSize.rows)",
            "vm.ro=\(readOnly ? 1 : 0)",
            "vm.quiet=1",
            "vm.hostpath=\(hostShareURL.path)",
            "vm.exec64=\(b64)"
        ].joined(separator: " ")

        let shares: [(tag: String, hostURL: URL, readOnly: Bool)] = shareURL != nil
            ? [("host", hostShareURL, shareReadOnly)]
            : []

        let vmOpts = VMConfigurationOptions(
            kernelURL: assets.rawKernelURL,
            initrdURL: assets.bootInitrdURL,
            rootDiskURL: assets.rootDiskURL,
            rootDiskReadOnly: true,
            externalDisks: disks,
            externalDisksReadOnly: readOnly,
            allowInternalDisks: allowInternal,
            sharedDirectories: shares,
            cpuCount: 2,
            memorySizeMB: 2048,
            kernelCommandLine: cmdline,
            rawTerminal: interactiveTTY,
            quietAttachmentLogs: quietLogs
        )

        try await VMRunner.run(options: vmOpts)
    }

    /// `tuxdisk inspect <disk...>`
    @MainActor
    public static func inspectDisks(_ disks: [String], allowInternal: Bool) async throws {
        guard !disks.isEmpty else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Please specify at least one disk or image to inspect (e.g. 'sudo tuxdisk inspect /dev/disk4')."
            ])
        }
        try await runOneShotCommand(
            disks: disks,
            readOnly: true,
            allowInternal: allowInternal,
            command: "/usr/local/bin/probe-disks",
            interactiveTTY: false,
            quietLogs: false
        )
    }

    /// `tuxdisk check <disk...> [--repair]`
    @MainActor
    public static func checkDisks(_ disks: [String], repair: Bool, allowInternal: Bool) async throws {
        guard !disks.isEmpty else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Please specify a disk or image to check (e.g. 'sudo tuxdisk check /dev/disk4')."
            ])
        }
        let cmd = repair ? "/usr/local/bin/check-disk --all --repair" : "/usr/local/bin/check-disk --all"
        try await runOneShotCommand(
            disks: disks,
            readOnly: !repair,
            allowInternal: allowInternal,
            command: cmd,
            interactiveTTY: true,
            quietLogs: false
        )
    }

    /// `tuxdisk create-image <path> --size <size> --fs <fs> [--label <label>] [--luks] [--lvm]`
    @MainActor
    public static func createDiskImage(
        path: String,
        sizeString: String,
        filesystem: String,
        label: String?,
        useLUKS: Bool,
        useLVM: Bool,
        passphrase: String?
    ) async throws {
        guard let sizeBytes = ConsoleStyle.parseByteSize(sizeString), sizeBytes >= 16 * 1024 * 1024 else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Invalid image size '\(sizeString)'. Specify at least 16M (e.g., 512M, 2G, 10G)."
            ])
        }

        let fs = filesystem.lowercased()
        guard ["ext4", "ext3", "ext2", "btrfs", "xfs", "f2fs", "exfat", "vfat"].contains(fs) else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported filesystem '\(filesystem)'. Supported: ext4, ext3, ext2, btrfs, xfs, f2fs, exfat, vfat."
            ])
        }

        if fs == "xfs" && sizeBytes < 320 * 1024 * 1024 {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "XFS requires a minimum image size of 320M (e.g. --size 512M or --size 1G)."
            ])
        }

        let resolvedPath = (path as NSString).expandingTildeInPath
        let imageURL = URL(fileURLWithPath: resolvedPath).standardizedFileURL
        let volLabel = label ?? "TuxDisk"

        ConsoleStyle.info("Creating \(ConsoleStyle.formatBytes(sizeBytes)) sparse image at \(imageURL.path)...")
        try ImageBuilder.createSparseDiskImage(at: imageURL, sizeBytes: sizeBytes)

        try await formatAttachedDisk(
            diskPath: imageURL.path,
            filesystem: fs,
            label: volLabel,
            useLUKS: useLUKS,
            useLVM: useLVM,
            passphrase: passphrase,
            allowInternal: false
        )

        ConsoleStyle.success("Created and formatted \(imageURL.path) (\(fs.uppercased())\(useLUKS ? " + LUKS2" : "")\(useLVM ? " + LVM2" : ""), label: \"\(volLabel)\")")
    }

    /// `tuxdisk format <disk> --fs <fs> [--label <label>] [--luks] [--lvm] [--yes]`
    @MainActor
    public static func formatDisk(
        diskPath: String,
        filesystem: String,
        label: String?,
        useLUKS: Bool,
        useLVM: Bool,
        passphrase: String?,
        skipConfirm: Bool,
        allowInternal: Bool
    ) async throws {
        let resolved = DiskManager.resolveDiskPath(diskPath)
        try DiskManager.verifyNotInternalDisk(resolved, allowInternal: allowInternal)

        let fs = filesystem.lowercased()
        guard ["ext4", "ext3", "ext2", "btrfs", "xfs", "f2fs", "exfat", "vfat"].contains(fs) else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported filesystem '\(filesystem)'. Supported: ext4, ext3, ext2, btrfs, xfs, f2fs, exfat, vfat."
            ])
        }

        let volLabel = label ?? "TuxDisk"

        if !skipConfirm {
            print("\(ConsoleStyle.boldYellow)WARNING:\(ConsoleStyle.reset) This will ERASE ALL DATA on '\(resolved)' and format it as \(fs.uppercased())\(useLUKS ? " + LUKS2" : "")\(useLVM ? " + LVM2" : "").")
            print("Type 'yes' to continue: ", terminator: "")
            fflush(stdout)
            guard let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                  response.lowercased() == "yes" else {
                print("Aborted.")
                return
            }
        }

        try await formatAttachedDisk(
            diskPath: resolved,
            filesystem: fs,
            label: volLabel,
            useLUKS: useLUKS,
            useLVM: useLVM,
            passphrase: passphrase,
            allowInternal: allowInternal
        )
        ConsoleStyle.success("Formatted \(resolved) as \(fs.uppercased()) (label: \"\(volLabel)\")")
    }

    @MainActor
    private static func formatAttachedDisk(
        diskPath: String,
        filesystem: String,
        label: String,
        useLUKS: Bool,
        useLVM: Bool,
        passphrase: String?,
        allowInternal: Bool
    ) async throws {
        let safeLabel = label.replacingOccurrences(of: "\"", with: "")
        var scriptLines: [String] = [
            "set -e",
            "echo '==> Creating GPT partition table on /dev/vdb...'",
            "wipefs -a /dev/vdb >/dev/null 2>&1 || true",
            "parted -s /dev/vdb mklabel gpt mkpart primary 1MiB 100%",
            "mdev -s >/dev/null 2>&1 || true",
            "partx -u /dev/vdb 2>/dev/null || true",
            "sleep 0.2",
            "TARGET_DEV=/dev/vdb1"
        ]

        if useLUKS {
            if let pass = passphrase {
                let passB64 = Data(pass.utf8).base64EncodedString()
                scriptLines.append("echo '==> Formatting /dev/vdb1 with LUKS2 encryption...'")
                scriptLines.append("printf '%s' '\(passB64)' | base64 -d | cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 -q /dev/vdb1 -")
                scriptLines.append("printf '%s' '\(passB64)' | base64 -d | cryptsetup open /dev/vdb1 luks_vdb1 -")
            } else {
                scriptLines.append("echo '==> Formatting /dev/vdb1 with LUKS2 encryption (enter new passphrase)...'")
                scriptLines.append("cryptsetup luksFormat --type luks2 /dev/vdb1")
                scriptLines.append("echo '==> Opening LUKS2 container (re-enter passphrase)...'")
                scriptLines.append("cryptsetup open /dev/vdb1 luks_vdb1")
            }
            scriptLines.append("TARGET_DEV=/dev/mapper/luks_vdb1")
        }

        if useLVM {
            scriptLines.append("echo '==> Creating LVM2 Volume Group (vg_tuxdisk) and Logical Volume (lv_main)...'")
            scriptLines.append("pvcreate -ff -y \"$TARGET_DEV\" >/dev/null")
            scriptLines.append("vgcreate vg_tuxdisk \"$TARGET_DEV\" >/dev/null")
            scriptLines.append("lvcreate -l 100%FREE -n lv_main vg_tuxdisk >/dev/null")
            scriptLines.append("vgchange -ay >/dev/null")
            scriptLines.append("mdev -s >/dev/null 2>&1 || true")
            scriptLines.append("TARGET_DEV=/dev/mapper/vg_tuxdisk-lv_main")
        }

        scriptLines.append("echo '==> Formatting '$TARGET_DEV' as \(filesystem) (label: \(safeLabel))...'")
        switch filesystem {
        case "ext4", "ext3", "ext2":
            scriptLines.append("mkfs.\(filesystem) -F -q -L \"\(safeLabel)\" \"$TARGET_DEV\"")
        case "btrfs":
            scriptLines.append("mkfs.btrfs -f -q -L \"\(safeLabel)\" \"$TARGET_DEV\"")
        case "xfs":
            scriptLines.append("mkfs.xfs -f -L \"\(String(safeLabel.prefix(12)))\" \"$TARGET_DEV\" >/dev/null")
        case "f2fs":
            scriptLines.append("mkfs.f2fs -f -q -l \"\(safeLabel)\" \"$TARGET_DEV\"")
        case "exfat":
            scriptLines.append("mkfs.exfat -L \"\(String(safeLabel.prefix(15)))\" \"$TARGET_DEV\" >/dev/null")
        case "vfat":
            scriptLines.append("mkfs.vfat -n \"\(String(safeLabel.prefix(11)).uppercased())\" \"$TARGET_DEV\" >/dev/null")
        default:
            break
        }

        scriptLines.append("/usr/local/bin/unmount-all --quiet")

        try await runOneShotCommand(
            disks: [diskPath],
            readOnly: false,
            allowInternal: allowInternal,
            command: scriptLines.joined(separator: "\n"),
            interactiveTTY: (useLUKS && passphrase == nil),
            quietLogs: false
        )
    }

    /// `tuxdisk copy <src> <dst>` — Copies files between a Linux disk (`<disk>:<path>`) and macOS
    @MainActor
    public static func copyFiles(source: String, destination: String, allowInternal: Bool) async throws {
        // Determine which endpoint is the Linux disk (<disk>:<path>)
        if let (diskSpec, guestRelPath) = parseDiskEndpoint(source) {
            // Pulling from Linux drive -> macOS destination
            let macDestURL = URL(fileURLWithPath: (destination as NSString).expandingTildeInPath).standardizedFileURL
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let destExists = fm.fileExists(atPath: macDestURL.path, isDirectory: &isDir)

            let shareDir: URL
            let targetNameInShare: String
            if destExists && isDir.boolValue {
                shareDir = macDestURL
                targetNameInShare = "."
            } else {
                shareDir = macDestURL.deletingLastPathComponent()
                targetNameInShare = macDestURL.lastPathComponent
                try fm.createDirectory(at: shareDir, withIntermediateDirectories: true)
            }

            let cleanRel = guestRelPath.hasPrefix("/") ? String(guestRelPath.dropFirst()) : guestRelPath
            let cmd = #"""
            set -e
            /usr/local/bin/mount-disk --all >/dev/null
            if ! mountpoint -q /mnt/host 2>/dev/null; then
                echo "Error: macOS VirtioFS share (/mnt/host) is not mounted." >&2
                exit 1
            fi
            MATCH=""
            if [ -e "/mnt/disks/\#(cleanRel)" ]; then
                MATCH="/mnt/disks/\#(cleanRel)"
            else
                for mp in /mnt/disks/*; do
                    if [ -e "$mp/\#(cleanRel)" ]; then
                        MATCH="$mp/\#(cleanRel)"
                        break
                    fi
                done
            fi
            if [ -z "$MATCH" ]; then
                echo "Error: Path '\#(guestRelPath)' not found on mounted volume(s). Available mounts:" >&2
                ls -1 /mnt/disks >&2
                exit 1
            fi
            echo "==> Copying from Linux volume ($MATCH) to macOS (\#(macDestURL.path))..."
            rsync -aHAX --info=progress2 "$MATCH" "/mnt/host/\#(targetNameInShare)"
            sync
            """#

            try await runOneShotCommand(
                disks: [diskSpec],
                readOnly: true,
                allowInternal: allowInternal,
                shareURL: shareDir,
                shareReadOnly: false,
                command: cmd,
                interactiveTTY: true,
                quietLogs: false
            )
            ConsoleStyle.success("Copied \(source) ──▶ \(macDestURL.path)")
        } else if let (diskSpec, guestRelPath) = parseDiskEndpoint(destination) {
            // Pushing from macOS source -> Linux drive
            let macSrcURL = URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: macSrcURL.path) else {
                throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "macOS source file or directory not found: \(macSrcURL.path)"
                ])
            }
            let shareDir = macSrcURL.deletingLastPathComponent()
            let srcName = macSrcURL.lastPathComponent
            let cleanRel = guestRelPath.hasPrefix("/") ? String(guestRelPath.dropFirst()) : guestRelPath

            let cmd = #"""
            set -e
            /usr/local/bin/mount-disk --all >/dev/null
            if ! mountpoint -q /mnt/host 2>/dev/null; then
                echo "Error: macOS VirtioFS share (/mnt/host) is not mounted." >&2
                exit 1
            fi
            FIRST_MP=$(ls -1d /mnt/disks/* 2>/dev/null | head -n 1 || true)
            if [ -z "$FIRST_MP" ]; then
                echo "Error: No writable Linux filesystem could be mounted from external drive." >&2
                exit 1
            fi
            if [ -d "/mnt/disks/\#(cleanRel)" ]; then
                DEST_PATH="/mnt/disks/\#(cleanRel)"
            else
                DEST_PATH="$FIRST_MP/\#(cleanRel)"
            fi
            mkdir -p "$(dirname "$DEST_PATH")"
            echo "==> Copying from macOS (\#(macSrcURL.path)) to Linux volume ($DEST_PATH)..."
            rsync -aHAX --info=progress2 "/mnt/host/\#(srcName)" "$DEST_PATH"
            sync
            """#

            try await runOneShotCommand(
                disks: [diskSpec],
                readOnly: false,
                allowInternal: allowInternal,
                shareURL: shareDir,
                shareReadOnly: true,
                command: cmd,
                interactiveTTY: true,
                quietLogs: false
            )
            ConsoleStyle.success("Copied \(macSrcURL.path) ──▶ \(destination)")
        } else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                Specify the Linux disk endpoint as <disk>:<path>, for example:
                  sudo tuxdisk copy /dev/disk4:/photos ./mac-photos
                  sudo tuxdisk copy ./archive.tar.gz /dev/disk4:/backups/
                """
            ])
        }
    }

    private static func parseDiskEndpoint(_ spec: String) -> (disk: String, path: String)? {
        guard let colonIdx = spec.firstIndex(of: ":") else { return nil }
        let diskPart = String(spec[..<colonIdx])
        let pathPart = String(spec[spec.index(after: colonIdx)...])
        guard !diskPart.isEmpty && !pathPart.isEmpty else { return nil }
        return (DiskManager.resolveDiskPath(diskPart), pathPart)
    }

    /// `tuxdisk doctor` — Verifies host virtualization support, entitlements, VM assets, and guest tools
    @MainActor
    public static func runDoctor() async throws {
        print("\(ConsoleStyle.boldCyan)╭────────────────────────────────────────────────────────────────────────────╮\(ConsoleStyle.reset)")
        print("\(ConsoleStyle.boldCyan)│\(ConsoleStyle.reset)  \(ConsoleStyle.boldWhite)tuxdisk doctor\(ConsoleStyle.reset) — Environment & Virtualization Health Check                \(ConsoleStyle.boldCyan)│\(ConsoleStyle.reset)")
        print("\(ConsoleStyle.boldCyan)╰────────────────────────────────────────────────────────────────────────────╯\(ConsoleStyle.reset)")
        print("")

        let isSupported = VZVirtualMachine.isSupported
        print("  \(isSupported ? "\(ConsoleStyle.boldGreen)✓\(ConsoleStyle.reset)" : "\(ConsoleStyle.boldRed)✗\(ConsoleStyle.reset)") Apple Virtualization.framework Supported: \(isSupported)")

        let assetsDir = ImageBuilder.defaultAssetsDirectory()
        let paths = VMAssetPaths(baseDir: assetsDir)
        print("  \(paths.isReady ? "\(ConsoleStyle.boldGreen)✓\(ConsoleStyle.reset)" : "\(ConsoleStyle.boldYellow)⚠\(ConsoleStyle.reset)") VM Assets Directory: \(assetsDir.path) (\(paths.isReady ? "Ready" : "Needs 'tuxdisk setup'"))")

        if paths.isReady {
            print("  \(ConsoleStyle.boldGreen)✓\(ConsoleStyle.reset) Kernel Image:        \(paths.rawKernelURL.lastPathComponent)")
            print("  \(ConsoleStyle.boldGreen)✓\(ConsoleStyle.reset) Boot Initramfs:      \(paths.bootInitrdURL.lastPathComponent)")
            print("  \(ConsoleStyle.boldGreen)✓\(ConsoleStyle.reset) Root Filesystem:     \(paths.rootDiskURL.lastPathComponent)")
            print("")
            ConsoleStyle.info("Booting micro-VM to verify guest kernel modules & filesystem tools...")

            let checkCmd = """
            echo "  ✓ Guest Kernel:        $(uname -sr)"
            echo "  ✓ e2fsprogs (ext4):    $(mkfs.ext4 -V 2>&1 | head -n 1)"
            echo "  ✓ btrfs-progs:         $(btrfs --version | head -n 1)"
            echo "  ✓ xfsprogs:            $(mkfs.xfs -V)"
            echo "  ✓ f2fs-tools:          f2fs-tools installed ($(which mkfs.f2fs))"
            echo "  ✓ cryptsetup (LUKS):   $(cryptsetup --version)"
            echo "  ✓ LVM2:                $(lvm version | head -n 1 | sed 's/^ *//')"
            echo "  ✓ rsync:               $(rsync --version | head -n 1)"
            """
            try await runOneShotCommand(
                disks: [],
                readOnly: true,
                command: checkCmd,
                interactiveTTY: false,
                quietLogs: true
            )
            print("")
            ConsoleStyle.success("All checks passed! tuxdisk is ready.")
        }
    }

    /// `tuxdisk browse <disk...> [--read-only] [--mount-point <dir>] [--port <port>] [--no-open]`
    @MainActor
    public static func browseDisks(
        _ disks: [String],
        readOnly: Bool,
        allowInternal: Bool,
        passphrase: String?,
        mountPoint: String?,
        preferredPort: UInt16,
        openFinder: Bool,
        cpuCount: Int = 2,
        memoryMB: UInt64 = 2048
    ) async throws {
        guard !disks.isEmpty else {
            throw NSError(domain: "tuxdisk", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Please specify at least one disk or image to browse in Finder (e.g. 'sudo tuxdisk browse /dev/disk4')."
            ])
        }

        let assets = try await ImageBuilder.ensurePrepared(force: false)
        let winSize = TerminalManager.currentWindowSize()
        let termEnv = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"

        var cmdlineParts = [
            "console=hvc0",
            "quiet",
            "TERM=\(termEnv)",
            "vm.cols=\(winSize.cols)",
            "vm.rows=\(winSize.rows)",
            "vm.ro=\(readOnly ? 1 : 0)",
            "vm.bridge=1",
            "vm.browse_only=1"
        ]

        if let pass = passphrase {
            let passB64 = Data(pass.utf8).base64EncodedString()
            cmdlineParts.append("vm.pass64=\(passB64)")
        }

        let bridgePipes = SerialBridgePipes()
        let controller = FinderSessionController(
            pipes: bridgePipes,
            readOnly: readOnly,
            mountPoint: mountPoint,
            preferredPort: preferredPort,
            openFinder: openFinder,
            isBrowseOnly: true
        )
        defer {
            controller.cleanup()
        }

        let vmOpts = VMConfigurationOptions(
            kernelURL: assets.rawKernelURL,
            initrdURL: assets.bootInitrdURL,
            rootDiskURL: assets.rootDiskURL,
            rootDiskReadOnly: true,
            externalDisks: disks,
            externalDisksReadOnly: readOnly,
            allowInternalDisks: allowInternal,
            sharedDirectories: [],
            cpuCount: cpuCount,
            memorySizeMB: memoryMB,
            kernelCommandLine: cmdlineParts.joined(separator: " "),
            rawTerminal: true,
            quietAttachmentLogs: false,
            bridgePipes: bridgePipes,
            onVMStarted: {
                controller.startBridgeAsync()
            }
        )

        try await VMRunner.run(options: vmOpts)
        if let startupError = controller.startupError {
            throw startupError
        }
    }
}

/// Manages the lifecycle of the host WebDAV server, Finder volume mount, and signal/eject watchers
public final class FinderSessionController: @unchecked Sendable {
    public let client: SerialGuestFSClient
    public let readOnly: Bool
    public let mountPoint: String?
    public let preferredPort: UInt16
    public let openFinder: Bool
    public let isBrowseOnly: Bool

    private let lock = NSLock()
    private var server: FinderWebDAVServer? = nil
    private var mounter: FinderMounter? = nil
    private var sigIntSource: DispatchSourceSignal? = nil
    private var sigTermSource: DispatchSourceSignal? = nil
    private var ejectTimer: DispatchSourceTimer? = nil
    private var cleanedUp = false
    public private(set) var startupError: Error? = nil

    public init(
        pipes: SerialBridgePipes,
        readOnly: Bool,
        mountPoint: String?,
        preferredPort: UInt16,
        openFinder: Bool,
        isBrowseOnly: Bool
    ) {
        self.client = SerialGuestFSClient(readHandle: pipes.hostReadHandle, writeHandle: pipes.hostWriteHandle)
        self.readOnly = readOnly
        self.mountPoint = mountPoint
        self.preferredPort = preferredPort
        self.openFinder = openFinder
        self.isBrowseOnly = isBrowseOnly
    }

    public func startBridgeAsync() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let volumeLabel = try self.client.waitUntilReady(timeoutSeconds: 180.0)
                if self.isBrowseOnly {
                    TerminalManager.shared.restore()
                }

                let webdav = FinderWebDAVServer(
                    backend: self.client,
                    readOnly: self.readOnly,
                    suppressMacMetadata: true
                )
                try webdav.start(preferredPort: self.preferredPort)

                let finderMounter = FinderMounter(
                    volumeLabel: volumeLabel,
                    webdavURLString: webdav.baseURLString,
                    customMountPoint: self.mountPoint
                )
                try finderMounter.mountAndOpenInFinder(openWindow: self.openFinder)

                self.lock.lock()
                self.server = webdav
                self.mounter = finderMounter
                self.lock.unlock()

                if self.isBrowseOnly {
                    print("")
                    print("\(ConsoleStyle.boldCyan)╭────────────────────────────────────────────────────────────────────────────╮\(ConsoleStyle.reset)")
                    print("\(ConsoleStyle.boldCyan)│\(ConsoleStyle.reset)  \(ConsoleStyle.boldWhite)tuxdisk browse\(ConsoleStyle.reset) — Linux Volume Mounted in macOS Finder                     \(ConsoleStyle.boldCyan)│\(ConsoleStyle.reset)")
                    print("\(ConsoleStyle.boldCyan)╰────────────────────────────────────────────────────────────────────────────╯\(ConsoleStyle.reset)")
                    print("  \(ConsoleStyle.boldGreen)● Volume Label:\(ConsoleStyle.reset)  \(ConsoleStyle.boldWhite)\(finderMounter.volumeLabel)\(ConsoleStyle.reset)")
                    if finderMounter.isMountedOnHost {
                        print("  \(ConsoleStyle.boldGreen)● Finder Mount:\(ConsoleStyle.reset)  \(ConsoleStyle.boldWhite)\(finderMounter.mountPointURL.path)\(ConsoleStyle.reset)")
                    }
                    print("  \(ConsoleStyle.boldGreen)● WebDAV URL:\(ConsoleStyle.reset)    \(webdav.baseURLString)")
                    let modeText = self.readOnly
                        ? "\(ConsoleStyle.boldYellow)READ-ONLY\(ConsoleStyle.reset)"
                        : "\(ConsoleStyle.boldGreen)READ-WRITE\(ConsoleStyle.reset) (.DS_Store / ._ clutter suppressed)"
                    print("  \(ConsoleStyle.boldGreen)● Access Mode:\(ConsoleStyle.reset)   \(modeText)")
                    print("")
                    ConsoleStyle.info("Press Ctrl+C (or Eject \"\(finderMounter.volumeLabel)\" in Finder) to sync, unmount, and exit.")
                    fflush(stdout)
                    self.installSignalAndEjectHandlers()
                }
            } catch {
                if self.isBrowseOnly {
                    TerminalManager.shared.restore()
                }
                self.lock.lock()
                self.startupError = error
                self.lock.unlock()
                try? self.client.shutdown()
            }
        }
    }

    private func installSignalAndEjectHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        sigInt.setEventHandler { [weak self] in
            print("\n\(ConsoleStyle.boldCyan)==> [tuxdisk] Unmounting Finder volume and syncing Linux disk...\(ConsoleStyle.reset)")
            self?.cleanup()
        }
        sigInt.resume()

        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInitiated))
        sigTerm.setEventHandler { [weak self] in
            self?.cleanup()
        }
        sigTerm.resume()

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let currentMounter = self.mounter
            self.lock.unlock()
            if let currentMounter, currentMounter.isMountedOnHost && !currentMounter.isStillMounted() {
                print("\n\(ConsoleStyle.boldCyan)==> [tuxdisk] Volume ejected in Finder; syncing Linux disk and shutting down...\(ConsoleStyle.reset)")
                self.cleanup()
            }
        }
        timer.resume()

        lock.lock()
        self.sigIntSource = sigInt
        self.sigTermSource = sigTerm
        self.ejectTimer = timer
        lock.unlock()
    }

    public func cleanup() {
        lock.lock()
        if cleanedUp {
            lock.unlock()
            return
        }
        cleanedUp = true
        let currentMounter = mounter
        let currentServer = server
        let sigInt = sigIntSource
        let sigTerm = sigTermSource
        let timer = ejectTimer
        mounter = nil
        server = nil
        sigIntSource = nil
        sigTermSource = nil
        ejectTimer = nil
        lock.unlock()

        timer?.cancel()
        sigInt?.cancel()
        sigTerm?.cancel()

        currentMounter?.unmountAndCleanup()
        currentServer?.stop()
        try? client.shutdown()
    }
}
