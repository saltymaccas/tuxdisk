import Foundation

public enum KernelError: LocalizedError {
    case fileNotFound(String)
    case unsupportedKernelFormat(String)
    case decompressionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "Kernel file not found at \(path)"
        case .unsupportedKernelFormat(let path):
            return "Unsupported kernel format at \(path). Expected ARM64 Linux Image, gzip Image, or EFI zboot image."
        case .decompressionFailed(let detail):
            return "Failed to decompress kernel image: \(detail)"
        }
    }
}

public enum KernelExtractor {
    /// Ensures the kernel at `sourceURL` is in raw uncompressed ARM64 `Image` format
    /// required by `VZLinuxBootLoader` on Apple Silicon.
    /// Supports:
    ///   1. Uncompressed ARM64 Linux `Image` (magic `ARM\x64` at offset 0x38)
    ///   2. Gzip-compressed `Image.gz` (magic `1f 8b 08` at offset 0)
    ///   3. EFI `zboot` compressed kernel (`MZ` at offset 0, `"zboot"` at offset 0x18, embedded gzip/zstd payload)
    public static func ensureUncompressedKernel(at sourceURL: URL, outputURL: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw KernelError.fileNotFound(sourceURL.path)
        }

        // If output already exists and is newer than source, and has ARM\x64 magic, reuse it
        if fm.fileExists(atPath: outputURL.path),
           try isRawArm64Image(at: outputURL) {
            return outputURL
        }

        if try isRawArm64Image(at: sourceURL) {
            if sourceURL != outputURL {
                if fm.fileExists(atPath: outputURL.path) {
                    try fm.removeItem(at: outputURL)
                }
                try fm.copyItem(at: sourceURL, to: outputURL)
            }
            return outputURL
        }

        let data = try Data(contentsOf: sourceURL)
        guard data.count >= 64 else {
            throw KernelError.unsupportedKernelFormat(sourceURL.path)
        }

        // Check standard gzip header (1f 8b 08) at offset 0
        if data[0] == 0x1F && data[1] == 0x8B && data[2] == 0x08 {
            try gunzipData(data, to: outputURL)
            return outputURL
        }

        // Check EFI zboot header ("MZ" at 0, "zboot" at 0x18)
        // EFI zboot header layout (drivers/firmware/efi/libstub/zboot-header.S):
        //   0x00: "MZ"
        //   0x18: "zboot\0\0\0" (or "zboot")
        //   0x20: uint32_t payload_offset
        //   0x24: uint32_t payload_size
        //   0x30: compression type string ("gzip", "zstd", "lzma", etc.)
        if data[0] == 0x4D && data[1] == 0x5A {
            let zbootMagic = String(data: data.subdata(in: 0x18..<0x1D), encoding: .ascii)
            if zbootMagic == "zboot" {
                let payloadOffset = data.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: 0x20, as: UInt32.self).littleEndian
                }
                let payloadSize = data.withUnsafeBytes { raw -> UInt32 in
                    raw.loadUnaligned(fromByteOffset: 0x24, as: UInt32.self).littleEndian
                }
                let compTypeData = data.subdata(in: 0x30..<0x38)
                let compType = String(bytes: compTypeData.prefix(while: { $0 != 0 }), encoding: .ascii) ?? "gzip"

                let start = Int(payloadOffset)
                let end = min(data.count, start + Int(payloadSize))
                guard start > 0 && start < end else {
                    throw KernelError.decompressionFailed("Invalid EFI zboot payload range (\(start)..<\(end))")
                }

                let payload = data.subdata(in: start..<end)
                if compType == "gzip" || (payload.count >= 3 && payload[payload.startIndex] == 0x1F && payload[payload.startIndex + 1] == 0x8B) {
                    try gunzipData(payload, to: outputURL)
                    return outputURL
                } else {
                    throw KernelError.decompressionFailed("Unsupported EFI zboot compression type: \(compType)")
                }
            }

            // Fallback: scan for embedded gzip stream (1f 8b 08 00) inside PE wrapper
            let gzipPattern = Data([0x1F, 0x8B, 0x08, 0x00])
            if let range = data.range(of: gzipPattern) {
                let payload = data.subdata(in: range.lowerBound..<data.count)
                try gunzipData(payload, to: outputURL)
                if try isRawArm64Image(at: outputURL) {
                    return outputURL
                }
            }
        }

        throw KernelError.unsupportedKernelFormat(sourceURL.path)
    }

    /// Checks for ARM64 Linux kernel Image magic (`ARM\x64` = 0x41 0x52 0x4D 0x64 at offset 0x38)
    public static func isRawArm64Image(at url: URL) throws -> Bool {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        guard let header = try fh.read(upToCount: 64), header.count >= 60 else {
            return false
        }
        return header[0x38] == 0x41 && header[0x39] == 0x52 && header[0x3A] == 0x4D && header[0x3B] == 0x64
    }

    private static func gunzipData(_ compressed: Data, to outputURL: URL) throws {
        let tempGzURL = outputURL.deletingLastPathComponent().appendingPathComponent(".tmp-kernel-\(ProcessInfo.processInfo.processIdentifier).gz")
        defer { try? FileManager.default.removeItem(at: tempGzURL) }
        try compressed.write(to: tempGzURL)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        proc.arguments = ["-d", "-c", tempGzURL.path]

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outHandle.close() }

        let errPipe = Pipe()
        proc.standardOutput = outHandle
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        // Note: gzip exits with code 2 (trailing garbage ignored) when decompressing
        // an embedded gzip stream inside an EFI zboot image; that is normal and valid.
        if proc.terminationStatus != 0 && proc.terminationStatus != 2 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KernelError.decompressionFailed("gzip exited with status \(proc.terminationStatus): \(errStr)")
        }

        guard try isRawArm64Image(at: outputURL) else {
            throw KernelError.decompressionFailed("Decompressed file does not have ARM64 Linux Image magic (ARM\\x64)")
        }
    }
}
