import Foundation

public struct CLIOptions: Sendable {
    public enum Subcommand: Sendable {
        case list
        case setup(force: Bool)
        case shell
        case help
    }

    public var subcommand: Subcommand = .shell
    public var disks: [String] = []
    public var readOnly: Bool = false
    public var allowInternal: Bool = false
    public var autoMount: Bool = false
    public var sharePath: String? = nil
    public var cpuCount: Int = 2
    public var memoryMB: UInt64 = 2048
    public var execCommand: String? = nil
}

@main
struct LinuxDiskVM {
    static func main() async {
        do {
            let options = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            switch options.subcommand {
            case .help:
                printHelp()
            case .list:
                try DiskManager.printDiskList()
            case .setup(let force):
                _ = try await ImageBuilder.ensurePrepared(force: force)
            case .shell:
                let assets = try await ImageBuilder.ensurePrepared(force: false)
                try syncGuestScriptsIfNeeded(assets: assets)

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

                if let execCmd = options.execCommand {
                    let b64 = Data(execCmd.utf8).base64EncodedString()
                    cmdlineParts.append("vm.exec64=\(b64)")
                }

                let isInteractive = (options.execCommand == nil)
                let vmOptions = VMConfigurationOptions(
                    kernelURL: assets.rawKernelURL,
                    initrdURL: assets.bootInitrdURL,
                    rootDiskURL: assets.rootDiskURL,
                    rootDiskReadOnly: false,
                    externalDisks: options.disks,
                    externalDisksReadOnly: options.readOnly,
                    allowInternalDisks: options.allowInternal,
                    sharedDirectories: [("host", hostShareURL, false)],
                    cpuCount: options.cpuCount,
                    memorySizeMB: options.memoryMB,
                    kernelCommandLine: cmdlineParts.joined(separator: " "),
                    rawTerminal: isInteractive
                )

                try await VMRunner.run(options: vmOptions)
            }
        } catch {
            TerminalManager.shared.restore()
            FileHandle.standardError.write(Data("\u{001B}[1;31mError:\u{001B}[0m \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func syncGuestScriptsIfNeeded(assets: VMAssetPaths) throws {
        let scriptsDir = assets.baseDir.appendingPathComponent("guest-scripts")
        try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
        try Data(GuestScripts.vmInitScript.utf8).write(to: scriptsDir.appendingPathComponent("vm-init"))
        try Data(GuestScripts.disksCommandScript.utf8).write(to: scriptsDir.appendingPathComponent("disks"))
        try Data(GuestScripts.mountDiskScript.utf8).write(to: scriptsDir.appendingPathComponent("mount-disk"))
        try Data(GuestScripts.unmountAllScript.utf8).write(to: scriptsDir.appendingPathComponent("unmount-all"))
    }

    private static func parseArguments(_ args: [String]) throws -> CLIOptions {
        var opts = CLIOptions()
        var idx = 0

        if let first = args.first {
            switch first {
            case "list", "disks", "--list", "-l":
                opts.subcommand = .list
                return opts
            case "help", "--help", "-h":
                opts.subcommand = .help
                return opts
            case "setup":
                let force = args.dropFirst().contains("--force") || args.dropFirst().contains("-f")
                opts.subcommand = .setup(force: force)
                return opts
            case "shell", "run":
                idx = 1
            default:
                break
            }
        }

        while idx < args.count {
            let arg = args[idx]
            switch arg {
            case "-h", "--help":
                opts.subcommand = .help
                return opts
            case "-l", "--list":
                opts.subcommand = .list
                return opts
            case "-r", "--read-only", "--ro":
                opts.readOnly = true
            case "-a", "--auto-mount":
                opts.autoMount = true
            case "--allow-internal":
                opts.allowInternal = true
            case "-d", "--disk":
                idx += 1
                guard idx < args.count else {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing argument for \(arg)"])
                }
                opts.disks.append(args[idx])
            case "-s", "--share":
                idx += 1
                guard idx < args.count else {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing argument for \(arg)"])
                }
                opts.sharePath = args[idx]
            case "-c", "--cpus":
                idx += 1
                guard idx < args.count, let cpus = Int(args[idx]), cpus > 0 else {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid CPU count"])
                }
                opts.cpuCount = cpus
            case "-m", "--memory":
                idx += 1
                guard idx < args.count, let mem = UInt64(args[idx]), mem >= 512 else {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid memory size in MB (min 512)"])
                }
                opts.memoryMB = mem
            case "-e", "--command":
                idx += 1
                guard idx < args.count else {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing command string for \(arg)"])
                }
                opts.execCommand = args[idx]
            default:
                if arg.hasPrefix("-") {
                    throw NSError(domain: "CLI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown option '\(arg)'. Run 'linux-disk-vm --help' for usage."])
                }
                opts.disks.append(arg)
            }
            idx += 1
        }

        return opts
    }

    private static func printHelp() {
        print("""
        linux-disk-vm — Lightweight Linux VM for accessing external Linux drives on macOS
        Powered by Apple Virtualization.framework (ARM64)

        SUPPORTED FILESYSTEMS & VOLUMES:
          • ext4, ext3, ext2 (e2fsprogs)
          • Btrfs (btrfs-progs)
          • XFS (xfsprogs)
          • F2FS (f2fs-tools)
          • LUKS1 / LUKS2 encrypted containers (cryptsetup / dm-crypt)
          • LVM2 volume groups & logical volumes (lvm2)

        USAGE:
          linux-disk-vm list                          List macOS disks and identify external Linux drives
          linux-disk-vm setup [--force]               Download & build the Alpine Linux VM rootfs image
          sudo linux-disk-vm [disks...] [options]     Boot interactive Linux shell with external drive(s)

        OPTIONS:
          -d, --disk <path>       Attach a raw block device (e.g. /dev/disk4) or image file (.img)
          -r, --read-only         Attach external drive(s) in read-only mode
          -a, --auto-mount        Automatically mount non-encrypted partitions under /mnt/disks/
          -s, --share <dir>       Share a macOS directory at /mnt/host via VirtioFS (default: current dir)
          -e, --command <cmd>     Execute a command inside the VM and exit immediately
          -c, --cpus <count>      Number of virtual CPUs (default: 2)
          -m, --memory <MB>       VM RAM in megabytes (default: 2048)
          --allow-internal        Override safety lock blocking macOS internal disks
          -h, --help              Show this help message

        EXAMPLES:
          # 1. Find the device identifier of your external USB/Thunderbolt Linux drive:
          linux-disk-vm list

          # 2. Boot the VM with /dev/disk4 attached and current macOS directory shared at /mnt/host:
          sudo linux-disk-vm /dev/disk4

          # 3. Boot in read-only mode and auto-mount partitions:
          sudo linux-disk-vm /dev/disk4 --read-only --auto-mount

          # 4. Inspect a disk image file (no sudo needed for image files):
          linux-disk-vm ./my-linux-drive.img
        """)
    }
}
