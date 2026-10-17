import Foundation
import Virtualization

public struct VMConfigurationOptions: Sendable {
    public var kernelURL: URL
    public var initrdURL: URL
    public var rootDiskURL: URL?
    public var rootDiskReadOnly: Bool = false
    public var externalDisks: [String] = []
    public var externalDisksReadOnly: Bool = false
    public var allowInternalDisks: Bool = false
    public var sharedDirectories: [(tag: String, hostURL: URL, readOnly: Bool)] = []
    public var cpuCount: Int = 2
    public var memorySizeMB: UInt64 = 2048
    public var kernelCommandLine: String
    public var rawTerminal: Bool = true

    public init(
        kernelURL: URL,
        initrdURL: URL,
        rootDiskURL: URL? = nil,
        rootDiskReadOnly: Bool = false,
        externalDisks: [String] = [],
        externalDisksReadOnly: Bool = false,
        allowInternalDisks: Bool = false,
        sharedDirectories: [(tag: String, hostURL: URL, readOnly: Bool)] = [],
        cpuCount: Int = 2,
        memorySizeMB: UInt64 = 2048,
        kernelCommandLine: String,
        rawTerminal: Bool = true
    ) {
        self.kernelURL = kernelURL
        self.initrdURL = initrdURL
        self.rootDiskURL = rootDiskURL
        self.rootDiskReadOnly = rootDiskReadOnly
        self.externalDisks = externalDisks
        self.externalDisksReadOnly = externalDisksReadOnly
        self.allowInternalDisks = allowInternalDisks
        self.sharedDirectories = sharedDirectories
        self.cpuCount = cpuCount
        self.memorySizeMB = memorySizeMB
        self.kernelCommandLine = kernelCommandLine
        self.rawTerminal = rawTerminal
    }
}

public final class VMDelegate: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let onStop: @Sendable (Error?) -> Void

    public init(onStop: @escaping @Sendable (Error?) -> Void) {
        self.onStop = onStop
    }

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop(nil)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        onStop(error)
    }
}

public enum VMRunner {
    @MainActor
    public static func run(options: VMConfigurationOptions) async throws {
        let config = VZVirtualMachineConfiguration()

        let maxCPUs = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        let minCPUs = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        config.cpuCount = max(minCPUs, min(options.cpuCount, maxCPUs))

        let requestedMem = options.memorySizeMB * 1024 * 1024
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        config.memorySize = max(minMem, min(requestedMem, maxMem))

        config.platform = VZGenericPlatformConfiguration()

        // Bootloader
        let bootLoader = VZLinuxBootLoader(kernelURL: options.kernelURL)
        bootLoader.initialRamdiskURL = options.initrdURL
        bootLoader.commandLine = options.kernelCommandLine
        config.bootLoader = bootLoader

        // Serial Console (hvc0) connected to standard input / output
        let consoleConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
        consoleConfig.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.standardInput,
            fileHandleForWriting: FileHandle.standardOutput
        )
        config.serialPorts = [consoleConfig]

        // Entropy device (fast random numbers for cryptsetup / LUKS)
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        // Network device (NAT)
        let netConfig = VZVirtioNetworkDeviceConfiguration()
        netConfig.attachment = VZNATNetworkDeviceAttachment()
        config.networkDevices = [netConfig]

        // Memory balloon
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        // Storage devices (/dev/vda = rootfs, /dev/vdb+ = external disks)
        var storageDevices: [VZStorageDeviceConfiguration] = []
        if let rootURL = options.rootDiskURL {
            let (rootDev, _) = try DiskManager.createBlockDeviceConfiguration(
                path: rootURL.path,
                readOnly: options.rootDiskReadOnly,
                allowInternal: true,
                unmountFirst: false
            )
            storageDevices.append(rootDev)
        }

        for diskPath in options.externalDisks {
            let (blockDev, resolvedPath) = try DiskManager.createBlockDeviceConfiguration(
                path: diskPath,
                readOnly: options.externalDisksReadOnly,
                allowInternal: options.allowInternalDisks,
                unmountFirst: true
            )
            let modeLabel = options.externalDisksReadOnly ? "read-only" : "read-write"
            FileHandle.standardError.write(Data("==> Attached \(resolvedPath) (\(modeLabel))\n".utf8))
            storageDevices.append(blockDev)
        }
        config.storageDevices = storageDevices

        // VirtioFS Shared Directories
        var directorySharingDevices: [VZDirectorySharingDeviceConfiguration] = []
        for share in options.sharedDirectories {
            let sharedDir = VZSharedDirectory(url: share.hostURL, readOnly: share.readOnly)
            let singleShare = VZSingleDirectoryShare(directory: sharedDir)
            let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            fsConfig.share = singleShare
            directorySharingDevices.append(fsConfig)
        }
        config.directorySharingDevices = directorySharingDevices

        try config.validate()

        let vm = VZVirtualMachine(configuration: config)

        if options.rawTerminal {
            TerminalManager.shared.enableRawMode()
        }
        defer {
            TerminalManager.shared.restore()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let delegate = VMDelegate { stopError in
                TerminalManager.shared.restore()
                if let stopError {
                    continuation.resume(throwing: stopError)
                } else {
                    continuation.resume(returning: ())
                }
            }
            // Keep delegate alive on vm
            objc_setAssociatedObject(vm, "vm_delegate_key", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            vm.delegate = delegate

            vm.start { result in
                switch result {
                case .success:
                    break
                case .failure(let error):
                    TerminalManager.shared.restore()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
