import Foundation
import Virtualization

public struct MacDiskPartition: Codable, Sendable {
    public let deviceIdentifier: String
    public let content: String
    public let volumeName: String?
    public let volumeUUID: String?
    public let size: Int64
    public let mountPoint: String?

    public var isLikelyLinux: Bool {
        let c = content.lowercased()
        return c.contains("linux")
            || c.contains("ext")
            || c.contains("btrfs")
            || c.contains("xfs")
            || c.contains("lvm")
            || c.contains("luks")
            || c.contains("0fc63daf-8483-4772-8e79-3d69d8477de4") // GPT Linux filesystem GUID
            || c.contains("e6d6d379-f507-44c2-a23c-238f2a3df928") // GPT Linux LVM GUID
            || c.contains("ca7d7ccb-63ed-4c53-861c-1742536059cc") // GPT LUKS GUID
    }
}

public struct MacDiskInfo: Codable, Sendable {
    public let deviceIdentifier: String
    public let mediaName: String
    public let size: Int64
    public let isInternal: Bool
    public let isRemovable: Bool
    public let isWholeDisk: Bool
    public let isWritable: Bool
    public let busProtocol: String
    public let partitionScheme: String
    public let partitions: [MacDiskPartition]

    public var rawDevicePath: String {
        "/dev/r\(deviceIdentifier)"
    }

    public var blockDevicePath: String {
        "/dev/\(deviceIdentifier)"
    }

    public var isDiskImage: Bool {
        busProtocol == "Disk Image"
    }
}

public enum DiskError: LocalizedError {
    case deviceNotFound(String)
    case internalDiskProtected(String)
    case permissionDenied(String)
    case unmountFailed(String, String)
    case ejectFailed(String, String)
    case attachmentFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let path):
            return "Disk or image not found: \(path)"
        case .internalDiskProtected(let dev):
            return "Refusing to operate on internal macOS system disk '\(dev)' for safety. Pass --allow-internal to override."
        case .permissionDenied(let path):
            return """
            Permission denied opening '\(path)'.
            Raw block device access on macOS requires root privileges.
            Please re-run with sudo:
              sudo tuxdisk ...
            """
        case .unmountFailed(let dev, let output):
            return "Failed to unmount '\(dev)' on macOS before VM attachment: \(output)"
        case .ejectFailed(let dev, let output):
            return "Failed to eject '\(dev)': \(output)"
        case .attachmentFailed(let path, let err):
            return "Failed to attach '\(path)' to VM: \(err.localizedDescription)"
        }
    }
}

public enum DiskManager {
    /// Normalizes `/dev/disk4`, `/dev/rdisk4s1`, or `disk4` into `disk4` (or `disk4s1`).
    public static func normalizeDiskIdentifier(_ input: String) -> String {
        let name = URL(fileURLWithPath: input).lastPathComponent
        if name.hasPrefix("rdisk") {
            return String(name.dropFirst(1))
        }
        return name
    }

    public static func isBlockDevicePath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return path.hasPrefix("/dev/disk") || path.hasPrefix("/dev/rdisk")
            || (name.hasPrefix("disk") && !FileManager.default.fileExists(atPath: path) && FileManager.default.fileExists(atPath: "/dev/\(name)"))
    }

    public static func resolveDiskPath(_ input: String) -> String {
        if input.hasPrefix("/dev/disk") || input.hasPrefix("/dev/rdisk") {
            return input
        }
        if input.hasPrefix("disk") || input.hasPrefix("rdisk") {
            let candidate = "/dev/\(input)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return (input as NSString).expandingTildeInPath
    }

    /// Lists physical disks on macOS using `diskutil`
    public static func listMacDisks(externalOnly: Bool = false) throws -> [MacDiskInfo] {
        let listData = try runProcess("/usr/sbin/diskutil", arguments: ["list", "-plist"])
        guard let plist = try PropertyListSerialization.propertyList(from: listData, format: nil) as? [String: Any],
              let allDisksAndPartitions = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        var results: [MacDiskInfo] = []
        for entry in allDisksAndPartitions {
            guard let devId = entry["DeviceIdentifier"] as? String else { continue }
            let infoData = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", devId])
            let infoPlist = infoData.flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            } ?? [:]

            // Skip synthesized APFS virtual containers when listing physical disks
            if let isSynthesized = infoPlist["APFSContainerReference"] as? String, !isSynthesized.isEmpty,
               (infoPlist["VirtualOrPhysical"] as? String) == "Virtual" {
                continue
            }

            let isInternal = (infoPlist["Internal"] as? Bool) ?? (devId == "disk0" || devId == "disk1")
            if externalOnly && isInternal {
                continue
            }

            let isRemovable = (infoPlist["RemovableMedia"] as? Bool) ?? (infoPlist["Ejectable"] as? Bool) ?? !isInternal
            let mediaName = (infoPlist["MediaName"] as? String) ?? (infoPlist["IORegistryEntryName"] as? String) ?? "Disk"
            let size = (infoPlist["TotalSize"] as? Int64) ?? (entry["Size"] as? Int64) ?? 0
            let isWritable = (infoPlist["Writable"] as? Bool) ?? true
            let busProtocol = (infoPlist["BusProtocol"] as? String) ?? "Unknown"
            let scheme = (entry["Content"] as? String) ?? (infoPlist["Content"] as? String) ?? "Raw"

            var partitions: [MacDiskPartition] = []
            if let parts = entry["Partitions"] as? [[String: Any]] {
                for part in parts {
                    guard let partId = part["DeviceIdentifier"] as? String else { continue }
                    let content = (part["Content"] as? String) ?? "Unknown"
                    let volName = part["VolumeName"] as? String
                    let volUUID = part["VolumeUUID"] as? String ?? part["DiskUUID"] as? String
                    let partSize = (part["Size"] as? Int64) ?? 0
                    let mountPoint = part["MountPoint"] as? String
                    partitions.append(MacDiskPartition(
                        deviceIdentifier: partId,
                        content: content,
                        volumeName: volName,
                        volumeUUID: volUUID,
                        size: partSize,
                        mountPoint: mountPoint
                    ))
                }
            }

            results.append(MacDiskInfo(
                deviceIdentifier: devId,
                mediaName: mediaName,
                size: size,
                isInternal: isInternal,
                isRemovable: isRemovable,
                isWholeDisk: true,
                isWritable: isWritable,
                busProtocol: busProtocol,
                partitionScheme: scheme,
                partitions: partitions
            ))
        }
        return results
    }

    /// Prints a formatted summary of macOS disks, highlighting external drives and Linux partitions
    public static func printDiskList(externalOnly: Bool = false, asJSON: Bool = false) throws {
        let disks = try listMacDisks(externalOnly: externalOnly)

        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(disks)
            if let jsonString = String(data: data, encoding: .utf8) {
                print(jsonString)
            }
            return
        }

        if disks.isEmpty {
            print(externalOnly ? "No external disks currently connected." : "No disks returned by diskutil.")
            return
        }

        print("\(ConsoleStyle.boldWhite)Discovered macOS Block Devices:\(ConsoleStyle.reset)")
        print(String(repeating: "─", count: 82))
        for disk in disks {
            let locationTag: String
            if disk.isInternal {
                locationTag = "\(ConsoleStyle.yellow)[INTERNAL - PROTECTED]\(ConsoleStyle.reset)"
            } else if disk.isDiskImage {
                locationTag = "\(ConsoleStyle.magenta)[MACOS DISK IMAGE]\(ConsoleStyle.reset)"
            } else {
                locationTag = "\(ConsoleStyle.boldGreen)[EXTERNAL DRIVE]\(ConsoleStyle.reset)"
            }
            let sizeStr = ConsoleStyle.formatBytes(disk.size)
            let rwStr = disk.isWritable ? "RW" : "RO"
            print("  \(ConsoleStyle.bold)/dev/\(disk.deviceIdentifier)\(ConsoleStyle.reset)  \(disk.mediaName) · \(sizeStr) · \(disk.busProtocol) · \(disk.partitionScheme) · \(rwStr) \(locationTag)")

            if disk.partitions.isEmpty {
                print("    └─ \(ConsoleStyle.dim)(Whole unpartitioned volume or unrecognized Linux filesystem)\(ConsoleStyle.reset)")
            } else {
                for (idx, part) in disk.partitions.enumerated() {
                    let branch = (idx == disk.partitions.count - 1) ? "└─" : "├─"
                    let pSize = ConsoleStyle.formatBytes(part.size)
                    let namePart = part.volumeName.map { " \"\($0)\"" } ?? ""
                    let mountPart = part.mountPoint.map { " \(ConsoleStyle.dim)[mounted: \($0)]\(ConsoleStyle.reset)" } ?? ""
                    let highlight = part.isLikelyLinux ? " \(ConsoleStyle.boldCyan)◀ Linux Volume\(ConsoleStyle.reset)" : ""
                    print("    \(branch) /dev/\(part.deviceIdentifier): \(part.content)\(namePart) (\(pSize))\(mountPart)\(highlight)")
                }
            }
            print("")
        }
        print("\(ConsoleStyle.dim)Tip: Run 'sudo tuxdisk inspect /dev/diskN' to probe filesystems or 'sudo tuxdisk /dev/diskN' for an interactive shell.\(ConsoleStyle.reset)")
    }

    /// Safely unmounts and ejects an external disk via `diskutil eject`
    public static func ejectDisk(_ input: String) throws {
        let resolved = resolveDiskPath(input)
        let normId = normalizeDiskIdentifier(resolved)

        if let infoData = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", normId]),
           let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] {
            let isInternal = (plist["Internal"] as? Bool) ?? (normId.hasPrefix("disk0") || normId.hasPrefix("disk1"))
            if isInternal {
                throw DiskError.internalDiskProtected("/dev/\(normId)")
            }
        }

        ConsoleStyle.info("Unmounting and ejecting /dev/\(normId)...")
        let (status, out) = try runProcessWithStatus("/usr/sbin/diskutil", arguments: ["eject", "/dev/\(normId)"])
        guard status == 0 else {
            throw DiskError.ejectFailed("/dev/\(normId)", out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        ConsoleStyle.success("Safely ejected /dev/\(normId). You may now unplug the drive.")
    }

    public static func verifyNotInternalDisk(_ path: String, allowInternal: Bool) throws {
        let resolved = resolveDiskPath(path)
        guard resolved.hasPrefix("/dev/disk") || resolved.hasPrefix("/dev/rdisk") else {
            return
        }
        let normalizedDiskId = normalizeDiskIdentifier(resolved)
        if let infoData = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", normalizedDiskId]),
           let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] {
            let isInternal = (plist["Internal"] as? Bool) ?? (normalizedDiskId.hasPrefix("disk0") || normalizedDiskId.hasPrefix("disk1"))
            if isInternal && !allowInternal {
                throw DiskError.internalDiskProtected("/dev/\(normalizedDiskId)")
            }
        } else if (normalizedDiskId.hasPrefix("disk0") || normalizedDiskId.hasPrefix("disk1")) && !allowInternal {
            throw DiskError.internalDiskProtected("/dev/\(normalizedDiskId)")
        }
    }

    /// Creates a VZVirtioBlockDeviceConfiguration for either a raw block device (`/dev/diskN`, `/dev/rdiskN`) or a disk image file
    public static func createBlockDeviceConfiguration(
        path: String,
        readOnly: Bool,
        allowInternal: Bool,
        unmountFirst: Bool = true
    ) throws -> (VZVirtioBlockDeviceConfiguration, String) {
        let resolved = resolveDiskPath(path)
        let fm = FileManager.default
        guard fm.fileExists(atPath: resolved) else {
            throw DiskError.deviceNotFound(resolved)
        }

        if resolved.hasPrefix("/dev/disk") || resolved.hasPrefix("/dev/rdisk") {
            let normalizedDiskId = normalizeDiskIdentifier(resolved)
            try verifyNotInternalDisk(resolved, allowInternal: allowInternal)

            // Unmount any macOS-mounted partitions on this disk so macOS releases exclusive lock
            if unmountFirst {
                _ = try? runProcess("/usr/sbin/diskutil", arguments: ["unmountDisk", "/dev/\(normalizedDiskId)"])
            }

            // Prefer raw character device /dev/rdiskN for VZDiskBlockDeviceStorageDeviceAttachment
            let rawPath = "/dev/r\(normalizedDiskId)"
            let targetPath = fm.fileExists(atPath: rawPath) ? rawPath : "/dev/\(normalizedDiskId)"

            let flags: Int32 = readOnly ? O_RDONLY : O_RDWR
            let fd = open(targetPath, flags)
            if fd < 0 {
                let err = errno
                if err == EACCES || err == EPERM {
                    throw DiskError.permissionDenied(targetPath)
                }
                throw DiskError.attachmentFailed(
                    targetPath,
                    NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                        NSLocalizedDescriptionKey: String(cString: strerror(err))
                    ])
                )
            }

            let fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                let attachment = try VZDiskBlockDeviceStorageDeviceAttachment(
                    fileHandle: fileHandle,
                    readOnly: readOnly,
                    synchronizationMode: .full
                )
                let config = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                return (config, targetPath)
            } catch {
                throw DiskError.attachmentFailed(targetPath, error)
            }
        } else {
            // Regular disk image file (.img, .raw, etc.)
            let url = URL(fileURLWithPath: resolved)
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: url,
                    readOnly: readOnly,
                    cachingMode: .automatic,
                    synchronizationMode: .full
                )
                let config = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                return (config, url.path)
            } catch {
                throw DiskError.attachmentFailed(resolved, error)
            }
        }
    }

    private static func runProcess(_ executable: String, arguments: [String]) throws -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return outData
    }

    private static func runProcessWithStatus(_ executable: String, arguments: [String]) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(data: outData, encoding: .utf8) ?? "")
    }
}
