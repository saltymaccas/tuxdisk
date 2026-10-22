// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tuxdisk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "tuxdisk", targets: ["tuxdisk"])
    ],
    targets: [
        .executableTarget(
            name: "tuxdisk",
            linkerSettings: [
                .linkedFramework("Virtualization")
            ]
        ),
        .testTarget(
            name: "tuxdiskTests",
            dependencies: ["tuxdisk"]
        ),
    ]
)
