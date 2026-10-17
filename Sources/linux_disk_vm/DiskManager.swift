import Foundation
import Virtualization

public struct MacDiskPartition: Sendable {
    public let deviceIdentifier: String
    public let content: String
    public let volumeName: String?
    public let size: Int64
    public let mountPoint: String?
}

public struct MacDiskInfo: Sendable {
    public let deviceIdentifier: String
    public let mediaName: String
    public let size: Int64
    public let isInternal: Bool
    public let isWholeDisk: Bool
    public let isWritable: Bool
    public let busProtocol: String
    public let partitions: [MacDiskPartition]

    public var rawDevicePath: String {
        "/dev/r\(deviceIdentifier)"
    }

    public var blockDevicePath: String {
        "/dev/\(deviceIdentifier)"
    }
}

public enum DiskError: LocalizedError {
    case deviceNotFound(String)
    case internalDiskProtected(String)
    case permissionDenied(String)
    case unmountFailed(String, String)
    case attachmentFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .deviceNotFound(let path):
            return "Disk or image not found: \(path)"
        case .internalDiskProtected(let dev):
            return "Refusing to attach internal system disk '\(dev)' for safety. Pass --allow-internal if you really intend to do this."
        case .permissionDenied(let path):
            return """
            Permission denied opening '\(path)'.
            Raw block device access on macOS requires root privileges.
            Please re-run with sudo:
              sudo linux-disk-vm ...
            """
        case .unmountFailed(let dev, let output):
            return "Failed to unmount '\(dev)' on macOS before VM attachment: \(output)"
        case .attachmentFailed(let path, let err):
            return "Failed to attach '\(path)' to VM: \(err.localizedDescription)"
        }
    }
}

public enum DiskManager {
    /// Lists physical disks on macOS using `diskutil`
    public static func listMacDisks() throws -> [MacDiskInfo] {
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
            let mediaName = (infoPlist["MediaName"] as? String) ?? (infoPlist["IORegistryEntryName"] as? String) ?? "Disk"
            let size = (infoPlist["TotalSize"] as? Int64) ?? (entry["Size"] as? Int64) ?? 0
            let isWritable = (infoPlist["Writable"] as? Bool) ?? true
            let busProtocol = (infoPlist["BusProtocol"] as? String) ?? "Unknown"

            var partitions: [MacDiskPartition] = []
            if let parts = entry["Partitions"] as? [[String: Any]] {
                for part in parts {
                    guard let partId = part["DeviceIdentifier"] as? String else { continue }
                    let content = (part["Content"] as? String) ?? "Unknown"
                    let volName = part["VolumeName"] as? String
                    let partSize = (part["Size"] as? Int64) ?? 0
                    let mountPoint = part["MountPoint"] as? String
                    partitions.append(MacDiskPartition(
                        deviceIdentifier: partId,
                        content: content,
                        volumeName: volName,
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
                isWholeDisk: true,
                isWritable: isWritable,
                busProtocol: busProtocol,
                partitions: partitions
            ))
        }
        return results
    }

    /// Prints a formatted summary of macOS disks, highlighting external drives and Linux partitions
    public static func printDiskList() throws {
        let disks = try listMacDisks()
        if disks.isEmpty {
            print("No disks returned by diskutil.")
            return
        }

        print("Discovered macOS Disks:")
        print(String(repeating: "─", count: 78))
        for disk in disks {
            let locationTag = disk.isInternal ? "\u{001B}[33m[INTERNAL - PROTECTED]\u{001B}[0m" : "\u{001B}[32m[EXTERNAL]\u{001B}[0m"
            let sizeStr = ByteCountFormatter.string(fromByteCount: disk.size, countStyle: .file)
            print("  /dev/\(disk.deviceIdentifier)  (\(disk.mediaName), \(sizeStr), \(disk.busProtocol)) \(locationTag)")

            if disk.partitions.isEmpty {
                print("    └─ (No recognized partition table or raw volume)")
            } else {
                for (idx, part) in disk.partitions.enumerated() {
                    let branch = (idx == disk.partitions.count - 1) ? "└─" : "├─"
                    let pSize = ByteCountFormatter.string(fromByteCount: part.size, countStyle: .file)
                    let namePart = part.volumeName.map { " \"\($0)\"" } ?? ""
                    let mountPart = part.mountPoint.map { " [mounted: \($0)]" } ?? ""
                    let isLinux = part.content.localizedCaseInsensitiveContains("Linux")
                        || part.content.localizedCaseInsensitiveContains("ext")
                        || part.content.localizedCaseInsensitiveContains("LVM")
                        || part.content.localizedCaseInsensitiveContains("LUKS")
                    let highlight = isLinux ? " \u{001B}[36m<-- Linux Partition\u{001B}[0m" : ""
                    print("    \(branch) /dev/\(part.deviceIdentifier): \(part.content)\(namePart) (\(pSize))\(mountPart)\(highlight)")
                }
            }
            print("")
        }
        print("Usage example to attach an external drive:")
        print("  sudo linux-disk-vm /dev/disk4")
        print("  sudo linux-disk-vm /dev/disk4 --read-only")
    }

    /// Creates a VZVirtioBlockDeviceConfiguration for either a raw block device (`/dev/diskN`, `/dev/rdiskN`) or a disk image file
    public static func createBlockDeviceConfiguration(
        path: String,
        readOnly: Bool,
        allowInternal: Bool,
        unmountFirst: Bool = true
    ) throws -> (VZVirtioBlockDeviceConfiguration, String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            throw DiskError.deviceNotFound(path)
        }

        if path.hasPrefix("/dev/disk") || path.hasPrefix("/dev/rdisk") {
            // Normalize device identifier (e.g., /dev/disk4 -> disk4, /dev/rdisk4 -> disk4)
            let devName = URL(fileURLWithPath: path).lastPathComponent
            let normalizedDiskId = devName.hasPrefix("rdisk")
                ? String(devName.dropFirst(1))
                : devName

            // Check if internal disk
            if let infoData = try? runProcess("/usr/sbin/diskutil", arguments: ["info", "-plist", normalizedDiskId]),
               let plist = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] {
                let isInternal = (plist["Internal"] as? Bool) ?? (normalizedDiskId.hasPrefix("disk0") || normalizedDiskId.hasPrefix("disk1"))
                if isInternal && !allowInternal {
                    throw DiskError.internalDiskProtected("/dev/\(normalizedDiskId)")
                }
            }

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
            let url = URL(fileURLWithPath: path)
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
                throw DiskError.attachmentFailed(path, error)
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
}
