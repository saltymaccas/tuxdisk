import Testing
import Foundation
@testable import linux_disk_vm

@Test func testRawArm64KernelDetectionAndExtraction() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Create a mock 128-byte ARM64 Linux Image with "ARM\x64" magic at 0x38
    var mockKernel = Data(repeating: 0, count: 128)
    mockKernel[0x38] = 0x41 // 'A'
    mockKernel[0x39] = 0x52 // 'R'
    mockKernel[0x3A] = 0x4D // 'M'
    mockKernel[0x3B] = 0x64 // 0x64

    let srcURL = tempDir.appendingPathComponent("Image")
    let outURL = tempDir.appendingPathComponent("vmlinux.raw")
    try mockKernel.write(to: srcURL)

    #expect(try KernelExtractor.isRawArm64Image(at: srcURL) == true)
    let resultURL = try KernelExtractor.ensureUncompressedKernel(at: srcURL, outputURL: outURL)
    #expect(try KernelExtractor.isRawArm64Image(at: resultURL) == true)
}

@Test func testEfiZbootKernelExtraction() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("zboot-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Create a mock ARM64 Image and gzip it
    var rawImage = Data(repeating: 0, count: 256)
    rawImage[0x38] = 0x41
    rawImage[0x39] = 0x52
    rawImage[0x3A] = 0x4D
    rawImage[0x3B] = 0x64

    let rawURL = tempDir.appendingPathComponent("raw.img")
    try rawImage.write(to: rawURL)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    proc.arguments = ["-c", rawURL.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    try proc.run()
    let gzData = pipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()

    // Construct an EFI zboot header ("MZ" at 0, "zboot" at 0x18, offset=64 at 0x20, size at 0x24, "gzip" at 0x30)
    var zbootHeader = Data(repeating: 0, count: 64)
    zbootHeader[0] = 0x4D // 'M'
    zbootHeader[1] = 0x5A // 'Z'
    let zbootMagic = Array("zboot".utf8)
    for (i, b) in zbootMagic.enumerated() {
        zbootHeader[0x18 + i] = b
    }
    var offsetLE = UInt32(64).littleEndian
    var sizeLE = UInt32(gzData.count).littleEndian
    withUnsafeBytes(of: &offsetLE) { bytes in
        for i in 0..<4 { zbootHeader[0x20 + i] = bytes[i] }
    }
    withUnsafeBytes(of: &sizeLE) { bytes in
        for i in 0..<4 { zbootHeader[0x24 + i] = bytes[i] }
    }
    let compMagic = Array("gzip".utf8)
    for (i, b) in compMagic.enumerated() {
        zbootHeader[0x30 + i] = b
    }

    var zbootFile = zbootHeader
    zbootFile.append(gzData)

    let zbootURL = tempDir.appendingPathComponent("vmlinuz-virt")
    let extractedURL = tempDir.appendingPathComponent("vmlinux.raw")
    try zbootFile.write(to: zbootURL)

    let out = try KernelExtractor.ensureUncompressedKernel(at: zbootURL, outputURL: extractedURL)
    #expect(try KernelExtractor.isRawArm64Image(at: out) == true)
}

@Test func testInternalDiskProtection() throws {
    // Verify that attempting to attach /dev/disk0 without --allow-internal throws internalDiskProtected
    #expect(throws: DiskError.self) {
        _ = try DiskManager.createBlockDeviceConfiguration(
            path: "/dev/disk0",
            readOnly: true,
            allowInternal: false,
            unmountFirst: false
        )
    }
}
