import Foundation
import Virtualization

public struct SerialBridgePipes: Sendable {
    public let hostReadHandle: FileHandle
    public let hostWriteHandle: FileHandle
    public let guestReadHandle: FileHandle
    public let guestWriteHandle: FileHandle

    public init() {
        let hostToGuest = Pipe()
        let guestToHost = Pipe()
        self.hostWriteHandle = hostToGuest.fileHandleForWriting
        self.guestReadHandle = hostToGuest.fileHandleForReading
        self.guestWriteHandle = guestToHost.fileHandleForWriting
        self.hostReadHandle = guestToHost.fileHandleForReading
    }
}

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
    public var quietAttachmentLogs: Bool = false
    public var bridgePipes: SerialBridgePipes? = nil
    public var onVMStarted: (@Sendable () -> Void)? = nil

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
        rawTerminal: Bool = true,
        quietAttachmentLogs: Bool = false,
        bridgePipes: SerialBridgePipes? = nil,
        onVMStarted: (@Sendable () -> Void)? = nil
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
        self.quietAttachmentLogs = quietAttachmentLogs
        self.bridgePipes = bridgePipes
        self.onVMStarted = onVMStarted
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
        var serialPorts: [VZVirtioConsoleDeviceSerialPortConfiguration] = [consoleConfig]

        // Optional secondary serial port (hvc1) for Finder filesystem bridge
        if let bridge = options.bridgePipes {
            let bridgePort = VZVirtioConsoleDeviceSerialPortConfiguration()
            bridgePort.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: bridge.guestReadHandle,
                fileHandleForWriting: bridge.guestWriteHandle
            )
            serialPorts.append(bridgePort)
        }
        config.serialPorts = serialPorts

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

        for (index, diskPath) in options.externalDisks.enumerated() {
            let (blockDev, resolvedPath) = try DiskManager.createBlockDeviceConfiguration(
                path: diskPath,
                readOnly: options.externalDisksReadOnly,
                allowInternal: options.allowInternalDisks,
                unmountFirst: true
            )
            if !options.quietAttachmentLogs {
                let guestLetter = String(UnicodeScalar(UInt8(ascii: "b") + UInt8(index)))
                let modeLabel = options.externalDisksReadOnly ? "read-only" : "read-write"
                ConsoleStyle.info("Attached \(resolvedPath) ──▶ /dev/vd\(guestLetter) (\(modeLabel))")
            }
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

        do {
            try await startVM(with: config, rawTerminal: options.rawTerminal, onVMStarted: options.onVMStarted)
        } catch {
            if !config.directorySharingDevices.isEmpty &&
               error.localizedDescription.localizedCaseInsensitiveContains("Fuse sandbox extension") {
                if !options.quietAttachmentLogs {
                    ConsoleStyle.warn("VirtioFS host sharing unavailable in sandboxed environment; booting without /mnt/host share.")
                }
                config.directorySharingDevices = []
                try config.validate()
                try await startVM(with: config, rawTerminal: options.rawTerminal, onVMStarted: options.onVMStarted)
            } else {
                throw error
            }
        }
    }

    @MainActor
    private static func startVM(
        with config: VZVirtualMachineConfiguration,
        rawTerminal: Bool,
        onVMStarted: (@Sendable () -> Void)?
    ) async throws {
        let vm = VZVirtualMachine(configuration: config)

        if rawTerminal {
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
            objc_setAssociatedObject(vm, "vm_delegate_key", delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            vm.delegate = delegate

            vm.start { result in
                switch result {
                case .success:
                    onVMStarted?()
                case .failure(let error):
                    TerminalManager.shared.restore()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
