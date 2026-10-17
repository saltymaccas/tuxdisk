// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "linux-disk-vm",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "linux-disk-vm", targets: ["linux_disk_vm"])
    ],
    targets: [
        .executableTarget(
            name: "linux_disk_vm",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        ),
        .testTarget(
            name: "linux_disk_vmTests",
            dependencies: ["linux_disk_vm"]
        ),
    ]
)
