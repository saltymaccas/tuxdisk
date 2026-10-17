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
}
