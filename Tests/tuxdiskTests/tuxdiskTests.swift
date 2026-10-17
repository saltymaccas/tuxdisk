import Testing
import Foundation
@testable import tuxdisk

@Test func testByteSizeParsing() throws {
    #expect(ConsoleStyle.parseByteSize("512M") == 512 * 1024 * 1024)
    #expect(ConsoleStyle.parseByteSize("2G") == 2 * 1024 * 1024 * 1024)
    #expect(ConsoleStyle.parseByteSize("1.5GB") == Int64(1.5 * 1024.0 * 1024.0 * 1024.0))
    #expect(ConsoleStyle.parseByteSize("invalid") == nil)
}

@Test func testRawArm64KernelDetectionAndExtraction() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    var mockKernel = Data(repeating: 0, count: 128)
    mockKernel[0x38] = 0x41
    mockKernel[0x39] = 0x52
    mockKernel[0x3A] = 0x4D
    mockKernel[0x3B] = 0x64

    let srcURL = tempDir.appendingPathComponent("Image")
    let outURL = tempDir.appendingPathComponent("vmlinux.raw")
    try mockKernel.write(to: srcURL)

    #expect(try KernelExtractor.isRawArm64Image(at: srcURL) == true)
    let resultURL = try KernelExtractor.ensureUncompressedKernel(at: srcURL, outputURL: outURL)
    #expect(try KernelExtractor.isRawArm64Image(at: resultURL) == true)
}

@Test func testInternalDiskProtection() throws {
    #expect(throws: DiskError.self) {
        _ = try DiskManager.createBlockDeviceConfiguration(
            path: "/dev/disk0",
            readOnly: true,
            allowInternal: false,
            unmountFirst: false
        )
    }
}
