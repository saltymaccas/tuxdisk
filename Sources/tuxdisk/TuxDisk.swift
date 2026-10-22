import Foundation

public struct CLIOptions: Sendable {
    public enum Subcommand: Sendable {
        case list
        case browse
        case inspect
        case check
        case copy(source: String, destination: String)
        case createImage(path: String)
        case format(disk: String)
        case eject(disk: String)
        case doctor
        case setup(force: Bool)
        case shell
        case version
        case help
    }

    public var subcommand: Subcommand = .shell
    public var disks: [String] = []
    public var readOnly: Bool = false
    public var allowInternal: Bool = false
    public var autoMount: Bool = false
    public var noShare: Bool = false
    public var sharePath: String? = nil
    public var cpuCount: Int = 2
    public var memoryMB: UInt64 = 2048
    public var execCommand: String? = nil

    // Flags for Finder browsing
    public var browseInFinder: Bool = false
    public var mountPoint: String? = nil
    public var webdavPort: UInt16 = 0
    public var noOpenFinder: Bool = false

    // Flags for list
    public var externalOnly: Bool = false
    public var jsonOutput: Bool = false

    // Flags for check / create-image / format
    public var repair: Bool = false
    public var imageSize: String = "1G"
    public var filesystem: String = "ext4"
    public var label: String? = nil
    public var useLUKS: Bool = false
    public var useLVM: Bool = false
    public var passphrase: String? = nil
    public var yesConfirm: Bool = false
}

#if !TUXDISK_TEST_RUNNER
@main
#endif
struct TuxDisk {
    static let version = "1.2.0"

    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            switch options.subcommand {
            case .help:
                printHelp()
            case .version:
                print("tuxdisk \(version) (Apple Virtualization.framework / ARM64)")
            case .list:
                try DiskManager.printDiskList(externalOnly: options.externalOnly, asJSON: options.jsonOutput)
            case .browse:
                try await Operations.browseDisks(
                    options.disks,
                    readOnly: options.readOnly,
                    allowInternal: options.allowInternal,
                    passphrase: options.passphrase,
                    mountPoint: options.mountPoint,
                    preferredPort: options.webdavPort,
                    openFinder: !options.noOpenFinder,
                    cpuCount: options.cpuCount,
                    memoryMB: options.memoryMB
                )
            case .inspect:
                try await Operations.inspectDisks(options.disks, allowInternal: options.allowInternal)
            case .check:
                try await Operations.checkDisks(options.disks, repair: options.repair, allowInternal: options.allowInternal)
            case .copy(let src, let dst):
                try await Operations.copyFiles(source: src, destination: dst, allowInternal: options.allowInternal)
            case .createImage(let path):
                try await Operations.createDiskImage(
                    path: path,
                    sizeString: options.imageSize,
                    filesystem: options.filesystem,
                    label: options.label,
                    useLUKS: options.useLUKS,
                    useLVM: options.useLVM,
                    passphrase: options.passphrase
                )
            case .format(let disk):
                try await Operations.formatDisk(
                    diskPath: disk,
                    filesystem: options.filesystem,
                    label: options.label,
                    useLUKS: options.useLUKS,
                    useLVM: options.useLVM,
                    passphrase: options.passphrase,
                    skipConfirm: options.yesConfirm,
                    allowInternal: options.allowInternal
                )
            case .eject(let disk):
                try DiskManager.ejectDisk(disk)
            case .doctor:
                try await Operations.runDoctor()
            case .setup(let force):
                _ = try await ImageBuilder.ensurePrepared(force: force)
            case .shell:
                let assets = try await ImageBuilder.ensurePrepared(force: false)

                let hostShareURL: URL
                if let customShare = options.sharePath {
                    hostShareURL = URL(fileURLWithPath: (customShare as NSString).expandingTildeInPath).standardizedFileURL
                } else {
                    hostShareURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
                }

                let winSize = TerminalManager.currentWindowSize()
                let termEnv = ProcessInfo.processInfo.environment["TERM"] ?? "xterm-256color"

                var cmdlineParts = [
                    "console=hvc0",
                    "quiet",
                    "TERM=\(termEnv)",
                    "vm.cols=\(winSize.cols)",
                    "vm.rows=\(winSize.rows)",
                    "vm.ro=\(options.readOnly ? 1 : 0)",
                    "vm.automount=\(options.autoMount ? 1 : 0)",
                    "vm.hostpath=\(hostShareURL.path)"
                ]

                if let pass = options.passphrase {
                    let passB64 = Data(pass.utf8).base64EncodedString()
                    cmdlineParts.append("vm.pass64=\(passB64)")
                }

                var bridgePipes: SerialBridgePipes? = nil
                var finderController: FinderSessionController? = nil
                if options.browseInFinder && !options.disks.isEmpty {
                    cmdlineParts.append("vm.bridge=1")
                    let pipes = SerialBridgePipes()
                    bridgePipes = pipes
                    finderController = FinderSessionController(
                        pipes: pipes,
                        readOnly: options.readOnly,
                        mountPoint: options.mountPoint,
                        preferredPort: options.webdavPort,
                        openFinder: !options.noOpenFinder,
                        isBrowseOnly: false
                    )
                }
                defer {
                    finderController?.cleanup()
                }

                if let execCmd = options.execCommand {
                    let b64 = Data(execCmd.utf8).base64EncodedString()
                    cmdlineParts.append("vm.exec64=\(b64)")
                }

                let isInteractive = (options.execCommand == nil)
                let shares: [(tag: String, hostURL: URL, readOnly: Bool)] = options.noShare
                    ? []
                    : [("host", hostShareURL, false)]

                let capturedController = finderController
                let vmOptions = VMConfigurationOptions(
                    kernelURL: assets.rawKernelURL,
                    initrdURL: assets.bootInitrdURL,
                    rootDiskURL: assets.rootDiskURL,
                    rootDiskReadOnly: true,
                    externalDisks: options.disks,
                    externalDisksReadOnly: options.readOnly,
                    allowInternalDisks: options.allowInternal,
                    sharedDirectories: shares,
                    cpuCount: options.cpuCount,
                    memorySizeMB: options.memoryMB,
                    kernelCommandLine: cmdlineParts.joined(separator: " "),
                    rawTerminal: isInteractive,
                    bridgePipes: bridgePipes,
                    onVMStarted: {
                        capturedController?.startBridgeAsync()
                    }
                )

                try await VMRunner.run(options: vmOptions)
            }
        } catch {
            TerminalManager.shared.restore()
            ConsoleStyle.error(error.localizedDescription)
            exit(1)
        }
    }

    public static func parseArguments(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var idx = 0
        var positional: [String] = []
        var explicitSubcommand: String? = nil

        if let first = args.first, !first.hasPrefix("-") {
            let knownSubcommands: Set<String> = [
                "list", "ls", "disks",
                "browse", "mount", "finder",
                "inspect", "info", "probe",
                "check", "fsck", "repair",
                "copy", "cp", "pull", "push",
                "create-image", "mkimg",
                "format", "mkfs",
                "eject", "unmount",
                "doctor", "status",
                "setup",
                "shell", "run",
                "version",
                "help"
            ]
            if knownSubcommands.contains(first) {
                explicitSubcommand = first
                idx = 1
            }
        }

        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                opts.subcommand = .help
                return opts
            case "-v", "--version":
                opts.subcommand = .version
                return opts
            case "-l", "--list":
                explicitSubcommand = "list"
            case "--external":
                opts.externalOnly = true
            case "--json":
                opts.jsonOutput = true
            case "-r", "--read-only", "--ro":
                opts.readOnly = true
            case "-a", "--auto-mount":
                opts.autoMount = true
            case "-b", "--browse", "--finder":
                opts.browseInFinder = true
            case "--no-open":
                opts.noOpenFinder = true
            case "--mount-point":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing value for --mount-point")
                }
                opts.mountPoint = args[idx]
            case "--port":
                idx += 1
                guard idx < args.count, let p = UInt16(args[idx]) else {
                    throw cliError("Invalid value for --port")
                }
                opts.webdavPort = p
            case "--no-share":
                opts.noShare = true
            case "--allow-internal":
                opts.allowInternal = true
            case "--repair":
                opts.repair = true
            case "--luks":
                opts.useLUKS = true
            case "--lvm":
                opts.useLVM = true
            case "-y", "--yes", "--force", "-f":
                opts.yesConfirm = true
            case "--size":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing value for --size (e.g., --size 1G)")
                }
                opts.imageSize = args[idx]
            case "--fs", "--filesystem":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing value for --fs (e.g., --fs ext4)")
                }
                opts.filesystem = args[idx]
            case "--label", "-L":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing value for --label")
                }
                opts.label = args[idx]
            case "--passphrase", "--password":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing value for --passphrase")
                }
                opts.passphrase = args[idx]
            case "-d", "--disk":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing argument for \(arg)")
                }
                opts.disks.append(args[idx])
            case "-s", "--share":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing argument for \(arg)")
                }
                opts.sharePath = args[idx]
            case "-c", "--cpus":
                idx += 1
                guard idx < args.count, let cpus = Int(args[idx]), cpus > 0 else {
                    throw cliError("Invalid CPU count")
                }
                opts.cpuCount = cpus
            case "-m", "--memory":
                idx += 1
                guard idx < args.count, let mem = UInt64(args[idx]), mem >= 512 else {
                    throw cliError("Invalid memory size in MB (min 512)")
                }
                opts.memoryMB = mem
            case "-e", "--command":
                idx += 1
                guard idx < args.count else {
                    throw cliError("Missing command string for \(arg)")
                }
                opts.execCommand = args[idx]
            default:
                if arg.hasPrefix("-") {
                    throw cliError("Unknown option '\(arg)'. Run 'tuxdisk --help' for usage.")
                }
                positional.append(arg)
            }
            idx += 1
        }

        switch explicitSubcommand {
        case "list", "ls", "disks":
            opts.subcommand = .list
        case "browse", "mount", "finder":
            opts.disks.append(contentsOf: positional)
            opts.subcommand = .browse
        case "inspect", "info", "probe":
            opts.disks.append(contentsOf: positional)
            opts.subcommand = .inspect
        case "check", "fsck":
            opts.disks.append(contentsOf: positional)
            opts.subcommand = .check
        case "repair":
            opts.disks.append(contentsOf: positional)
            opts.repair = true
            opts.subcommand = .check
        case "copy", "cp", "pull", "push":
            guard positional.count == 2 else {
                throw cliError("Usage: tuxdisk copy <source> <destination>\nExample: sudo tuxdisk copy /dev/disk4:/photos ./mac-photos")
            }
            opts.subcommand = .copy(source: positional[0], destination: positional[1])
        case "create-image", "mkimg":
            guard let imgPath = positional.first else {
                throw cliError("Usage: tuxdisk create-image <file.img> [--size 1G] [--fs ext4|btrfs|xfs|f2fs] [--label Name] [--luks] [--lvm]")
            }
            opts.subcommand = .createImage(path: imgPath)
        case "format", "mkfs":
            guard let targetDisk = positional.first else {
                throw cliError("Usage: sudo tuxdisk format <disk> --fs <ext4|btrfs|xfs|f2fs> [--label Name] [--luks] [--lvm]")
            }
            opts.subcommand = .format(disk: targetDisk)
        case "eject", "unmount":
            guard let targetDisk = positional.first else {
                throw cliError("Usage: tuxdisk eject <disk> (e.g., tuxdisk eject /dev/disk4)")
            }
            opts.subcommand = .eject(disk: targetDisk)
        case "doctor", "status":
            opts.subcommand = .doctor
        case "setup":
            opts.subcommand = .setup(force: opts.yesConfirm)
        case "version":
            opts.subcommand = .version
        case "help":
            opts.subcommand = .help
        default:
            opts.disks.append(contentsOf: positional)
            opts.subcommand = .shell
        }

        return opts
    }

    private static func cliError(_ message: String) -> NSError {
        NSError(domain: "tuxdisk", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func printHelp() {
        print("""
        \(ConsoleStyle.boldCyan)tuxdisk\(ConsoleStyle.reset) v\(version) — Lightweight Linux Filesystem & Volume Utility VM for macOS
        Powered by Apple Virtualization.framework (ARM64)

        \(ConsoleStyle.boldWhite)SUPPORTED FILESYSTEMS & VOLUMES:\(ConsoleStyle.reset)
          • ext4, ext3, ext2 (e2fsprogs)      • Btrfs & subvolumes (btrfs-progs)
          • XFS (xfsprogs)                    • F2FS (f2fs-tools)
          • LUKS1 / LUKS2 (cryptsetup)        • LVM2 volume groups (lvm2)
          • FAT32 / exFAT / NTFS              • macOS Finder WebDAV & VirtioFS

        \(ConsoleStyle.boldWhite)COMMANDS:\(ConsoleStyle.reset)
          \(ConsoleStyle.cyan)tuxdisk list\(ConsoleStyle.reset) [--external] [--json]        List macOS block devices & highlight Linux partitions
          \(ConsoleStyle.cyan)tuxdisk browse\(ConsoleStyle.reset) <disk...> [options]        Mount Linux drive(s) as a volume in macOS Finder
          \(ConsoleStyle.cyan)tuxdisk [shell]\(ConsoleStyle.reset) [disks...] [options]      Boot interactive Linux shell with external drive(s)
          \(ConsoleStyle.cyan)tuxdisk inspect\(ConsoleStyle.reset) <disk...>                 Probe partition tables, UUIDs, LVM/LUKS & disk usage
          \(ConsoleStyle.cyan)tuxdisk copy\(ConsoleStyle.reset) <src> <dst>                  Copy files between a Linux drive (<disk>:<path>) and macOS
          \(ConsoleStyle.cyan)tuxdisk check\(ConsoleStyle.reset) <disk> [--repair]           Run fsck / btrfs check / xfs_repair on drive partitions
          \(ConsoleStyle.cyan)tuxdisk create-image\(ConsoleStyle.reset) <file.img> [opts]    Create & format a sparse Linux disk image (.img)
          \(ConsoleStyle.cyan)tuxdisk format\(ConsoleStyle.reset) <disk> --fs <type> [opts]  Format an external drive or image with GPT + Linux FS
          \(ConsoleStyle.cyan)tuxdisk eject\(ConsoleStyle.reset) <disk>                      Safely unmount and eject an external drive on macOS
          \(ConsoleStyle.cyan)tuxdisk doctor\(ConsoleStyle.reset)                            Verify virtualization support, assets & guest tools
          \(ConsoleStyle.cyan)tuxdisk setup\(ConsoleStyle.reset) [--force]                   Download & build the Alpine Linux VM rootfs image

        \(ConsoleStyle.boldWhite)FINDER / SHELL / GENERAL OPTIONS:\(ConsoleStyle.reset)
          -d, --disk <path>       Attach a raw block device (e.g. /dev/disk4) or image file (.img)
          -b, --browse, --finder  Mount attached Linux drive(s) in macOS Finder alongside shell
          --mount-point <dir>     Custom macOS directory for Finder WebDAV mount (default: ~/Volumes/<label>)
          --port <port>           Localhost port for embedded WebDAV bridge (default: auto)
          --no-open               Mount volume without automatically opening a Finder window
          -r, --read-only         Attach external drive(s) in read-only mode
          -a, --auto-mount        Automatically mount non-encrypted partitions under /mnt/disks/
          -s, --share <dir>       Share a macOS directory at /mnt/host via VirtioFS (default: current dir)
          --no-share              Disable VirtioFS host directory sharing
          -e, --command <cmd>     Execute a shell command inside the VM and exit
          -c, --cpus <count>      Number of virtual CPUs (default: 2)
          -m, --memory <MB>       VM RAM in megabytes (default: 2048)

        \(ConsoleStyle.boldWhite)IMAGE / FORMAT OPTIONS:\(ConsoleStyle.reset)
          --size <size>           Image size for create-image (e.g. 512M, 2G, 10G; default: 1G)
          --fs <type>             Filesystem type: ext4, btrfs, xfs, f2fs, exfat, vfat (default: ext4)
          -L, --label <name>      Filesystem volume label (default: TuxDisk)
          --luks                  Wrap volume in a LUKS2 encrypted container
          --lvm                   Create an LVM2 volume group (vg_tuxdisk) & logical volume (lv_main)
          -y, --yes               Skip confirmation prompt when formatting

        \(ConsoleStyle.boldWhite)EXAMPLES:\(ConsoleStyle.reset)
          \(ConsoleStyle.dim)# 1. Discover connected external drives on macOS:\(ConsoleStyle.reset)
          tuxdisk list

          \(ConsoleStyle.dim)# 2. Mount and browse an external Linux drive directly in macOS Finder:\(ConsoleStyle.reset)
          sudo tuxdisk browse /dev/disk4

          \(ConsoleStyle.dim)# 3. Inspect partitions, LUKS headers, LVM volumes, and files on /dev/disk4:\(ConsoleStyle.reset)
          sudo tuxdisk inspect /dev/disk4

          \(ConsoleStyle.dim)# 4. Enter interactive Linux shell AND browse in macOS Finder simultaneously:\(ConsoleStyle.reset)
          sudo tuxdisk /dev/disk4 --browse

          \(ConsoleStyle.dim)# 5. Copy a folder directly from an external Linux drive to macOS:\(ConsoleStyle.reset)
          sudo tuxdisk copy /dev/disk4:/home/alice/Photos ~/Downloads/Photos

          \(ConsoleStyle.dim)# 6. Create an encrypted 1GB Btrfs + LUKS2 + LVM2 disk image:\(ConsoleStyle.reset)
          tuxdisk create-image vault.img --size 1G --fs btrfs --label Vault --luks --lvm
        """)
    }
}
