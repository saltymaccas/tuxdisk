import Foundation
import Darwin
#if !TUXDISK_TEST_RUNNER
import Testing
@testable import tuxdisk
#endif

private func assertTrue(_ condition: @autoclosure () throws -> Bool, _ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) throws {
    if !(try condition()) {
        throw NSError(domain: "tuxdiskTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "\(message) (\(file):\(line))"
        ])
    }
}

func runByteSizeParsingTest() throws {
    try assertTrue(ConsoleStyle.parseByteSize("512M") == 512 * 1024 * 1024, "512M byte parsing")
    try assertTrue(ConsoleStyle.parseByteSize("2G") == 2 * 1024 * 1024 * 1024, "2G byte parsing")
    try assertTrue(ConsoleStyle.parseByteSize("1.5GB") == Int64(1.5 * 1024.0 * 1024.0 * 1024.0), "1.5GB byte parsing")
    try assertTrue(ConsoleStyle.parseByteSize("invalid") == nil, "invalid byte parsing")
}

func runRawArm64KernelDetectionTest() throws {
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

    try assertTrue(try KernelExtractor.isRawArm64Image(at: srcURL) == true, "Detect raw ARM64 kernel header")
    let resultURL = try KernelExtractor.ensureUncompressedKernel(at: srcURL, outputURL: outURL)
    try assertTrue(try KernelExtractor.isRawArm64Image(at: resultURL) == true, "Extract raw ARM64 kernel")
}

func runInternalDiskProtectionTest() throws {
    var threw = false
    do {
        _ = try DiskManager.createBlockDeviceConfiguration(
            path: "/dev/disk0",
            readOnly: true,
            allowInternal: false,
            unmountFirst: false
        )
    } catch is DiskError {
        threw = true
    }
    try assertTrue(threw, "Expected DiskError when attempting to attach /dev/disk0 without --allow-internal")
}

func runBrowseCLIArgumentParsingTest() throws {
    let browseOpts = try TuxDisk.parseArguments([
        "browse", "/dev/disk4", "--read-only", "--mount-point", "/tmp/my-mount", "--port", "18080", "--no-open"
    ])
    if case .browse = browseOpts.subcommand {
        // expected
    } else {
        throw NSError(domain: "tuxdiskTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected .browse subcommand"])
    }
    try assertTrue(browseOpts.disks == ["/dev/disk4"], "Disks parsed")
    try assertTrue(browseOpts.readOnly == true, "readOnly parsed")
    try assertTrue(browseOpts.mountPoint == "/tmp/my-mount", "mountPoint parsed")
    try assertTrue(browseOpts.webdavPort == 18080, "webdavPort parsed")
    try assertTrue(browseOpts.noOpenFinder == true, "noOpenFinder parsed")

    let mountAliasOpts = try TuxDisk.parseArguments(["mount", "test.img"])
    if case .browse = mountAliasOpts.subcommand {
        // expected
    } else {
        throw NSError(domain: "tuxdiskTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected .browse for mount alias"])
    }
    try assertTrue(mountAliasOpts.disks == ["test.img"], "mount alias positional disk")

    let shellBrowseOpts = try TuxDisk.parseArguments(["/dev/disk4", "--browse"])
    if case .shell = shellBrowseOpts.subcommand {
        // expected
    } else {
        throw NSError(domain: "tuxdiskTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected .shell subcommand"])
    }
    try assertTrue(shellBrowseOpts.browseInFinder == true, "--browse flag in shell mode")
    try assertTrue(shellBrowseOpts.disks == ["/dev/disk4"], "disk in shell mode")
}

func runFinderMetadataFilterTest() throws {
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/.DS_Store") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/photos/.DS_Store") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/photos/._IMG_0001.JPG") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/.Spotlight-V100/Store-V2/index") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/.Trashes/501/file.txt") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/.fseventsd/fseventsd-uuid") == true)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/photos/IMG_0001.JPG") == false)
    try assertTrue(FinderMetadataFilter.isMacMetadataPath("/home/alice/.bashrc") == false)
}

final class MockGuestFSBackend: GuestFSBackend, @unchecked Sendable {
    private let lock = NSLock()
    var files: [String: Data] = ["/hello.txt": Data("Hello from Linux!".utf8)]
    var dirs: Set<String> = ["/", "/docs"]

    func ping() throws -> String { "TestLinuxVol" }

    func stat(path: String) throws -> GuestFSItem {
        lock.lock()
        defer { lock.unlock() }
        let norm = path.isEmpty ? "/" : path
        if dirs.contains(norm) {
            let name = norm == "/" ? "/" : URL(fileURLWithPath: norm).lastPathComponent
            return GuestFSItem(name: name, isDirectory: true, size: 0, modifiedTime: 1700000000)
        }
        if let data = files[norm] {
            let name = URL(fileURLWithPath: norm).lastPathComponent
            return GuestFSItem(name: name, isDirectory: false, size: Int64(data.count), modifiedTime: 1700000000)
        }
        throw GuestFSError.notFound
    }

    func list(path: String) throws -> [GuestFSItem] {
        lock.lock()
        defer { lock.unlock() }
        let norm = path.isEmpty ? "/" : path
        guard dirs.contains(norm) else { throw GuestFSError.notFound }
        let prefix = norm == "/" ? "/" : norm + "/"
        var items: [GuestFSItem] = []

        for d in dirs where d != norm && d.hasPrefix(prefix) {
            let rel = String(d.dropFirst(prefix.count))
            if !rel.contains("/") {
                items.append(GuestFSItem(name: rel, isDirectory: true, size: 0, modifiedTime: 1700000000))
            }
        }
        for (f, data) in files where f.hasPrefix(prefix) {
            let rel = String(f.dropFirst(prefix.count))
            if !rel.contains("/") {
                items.append(GuestFSItem(name: rel, isDirectory: false, size: Int64(data.count), modifiedTime: 1700000000))
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    func statfs() throws -> GuestFSStats {
        GuestFSStats(totalBytes: 1024 * 1024 * 1024, usedBytes: 128 * 1024 * 1024, availableBytes: 896 * 1024 * 1024)
    }

    func readFile(path: String, offset: Int64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let data = files[path] else { throw GuestFSError.notFound }
        let start = min(Int(offset), data.count)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }

    func writeFile(path: String, offset: Int64, data: Data, truncate: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        if truncate || files[path] == nil {
            files[path] = data
        } else {
            var current = files[path] ?? Data()
            if Int(offset) == current.count {
                current.append(data)
            } else {
                current.replaceSubrange(Int(offset)..<min(current.count, Int(offset) + data.count), with: data)
            }
            files[path] = current
        }
    }

    func mkdir(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        dirs.insert(path)
    }

    func delete(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if dirs.remove(path) == nil && files.removeValue(forKey: path) == nil {
            throw GuestFSError.notFound
        }
    }

    func move(from: String, to: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let data = files.removeValue(forKey: from) {
            files[to] = data
        } else if dirs.remove(from) != nil {
            dirs.insert(to)
        } else {
            throw GuestFSError.notFound
        }
    }

    func copy(from: String, to: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let data = files[from] {
            files[to] = data
        } else if dirs.contains(from) {
            dirs.insert(to)
        } else {
            throw GuestFSError.notFound
        }
    }

    func sync() throws {}
    func shutdown() throws {}
}

/// Sends a single HTTP/1.1 request to `FinderWebDAVServer` over an in-process UNIX `socketpair`
func sendWebDAVRequestOverSocketPair(
    server: FinderWebDAVServer,
    method: String,
    path: String,
    headers: [String: String] = [:],
    body: Data = Data()
) throws -> (statusCode: Int, headers: [String: String], body: Data) {
    var fds: [Int32] = [-1, -1]
    guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: nil)
    }
    let clientFD = fds[0]
    let serverFD = fds[1]
    defer { Darwin.close(clientFD) }

    DispatchQueue.global(qos: .userInitiated).async {
        server.handleClientConnection(serverFD)
    }

    var reqStr = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    if !body.isEmpty {
        reqStr += "Content-Length: \(body.count)\r\n"
    }
    for (k, v) in headers {
        reqStr += "\(k): \(v)\r\n"
    }
    reqStr += "\r\n"

    var payload = Data(reqStr.utf8)
    payload.append(body)
    payload.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < payload.count {
            let n = Darwin.write(clientFD, base.advanced(by: offset), payload.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }

    var responseData = Data()
    var buf = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = Darwin.read(clientFD, &buf, buf.count)
        if n <= 0 { break }
        responseData.append(buf, count: n)
    }

    let crlfcrlf = Data([13, 10, 13, 10])
    guard let range = responseData.range(of: crlfcrlf) else {
        throw NSError(domain: "tuxdiskTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
    }
    let headerData = responseData.subdata(in: 0..<range.lowerBound)
    let respBody = responseData.subdata(in: range.upperBound..<responseData.count)
    let headerStr = String(data: headerData, encoding: .utf8) ?? ""
    let lines = headerStr.components(separatedBy: "\r\n")
    let statusParts = (lines.first ?? "").split(separator: " ")
    let statusCode = statusParts.count >= 2 ? (Int(statusParts[1]) ?? 0) : 0

    var respHeaders: [String: String] = [:]
    for line in lines.dropFirst() where !line.isEmpty {
        if let colon = line.firstIndex(of: ":") {
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            respHeaders[k] = v
        }
    }
    return (statusCode, respHeaders, respBody)
}

func runWebDAVServerAndMetadataSuppressionTest() throws {
    let backend = MockGuestFSBackend()
    let server = FinderWebDAVServer(backend: backend, readOnly: false, suppressMacMetadata: true)

    // 1. OPTIONS
    let opt = try sendWebDAVRequestOverSocketPair(server: server, method: "OPTIONS", path: "/")
    try assertTrue(opt.statusCode == 200, "OPTIONS status 200")
    try assertTrue(opt.headers["dav"]?.contains("2") == true, "DAV Class 2 header")

    // 2. PROPFIND root
    let prop = try sendWebDAVRequestOverSocketPair(server: server, method: "PROPFIND", path: "/", headers: ["Depth": "1"])
    let propXML = String(data: prop.body, encoding: .utf8) ?? ""
    try assertTrue(prop.statusCode == 207, "PROPFIND status 207")
    try assertTrue(propXML.contains("/hello.txt"), "PROPFIND lists /hello.txt")
    try assertTrue(propXML.contains("/docs/"), "PROPFIND lists /docs/")

    // 3. GET /hello.txt
    let getResp = try sendWebDAVRequestOverSocketPair(server: server, method: "GET", path: "/hello.txt")
    try assertTrue(getResp.statusCode == 200, "GET status 200")
    try assertTrue(String(data: getResp.body, encoding: .utf8) == "Hello from Linux!", "GET body matches")

    // 4. PUT /notes.txt
    let putResp = try sendWebDAVRequestOverSocketPair(
        server: server,
        method: "PUT",
        path: "/notes.txt",
        body: Data("Created via Finder WebDAV".utf8)
    )
    try assertTrue(putResp.statusCode == 201, "PUT status 201")
    try assertTrue(String(data: backend.files["/notes.txt"] ?? Data(), encoding: .utf8) == "Created via Finder WebDAV", "PUT persisted to backend")

    // 5. PUT .DS_Store should return 201 to Finder but NOT pollute backend.files
    let dsResp = try sendWebDAVRequestOverSocketPair(
        server: server,
        method: "PUT",
        path: "/.DS_Store",
        body: Data([0, 1, 2, 3])
    )
    try assertTrue(dsResp.statusCode == 201, "PUT .DS_Store returns 201")
    try assertTrue(backend.files["/.DS_Store"] == nil, ".DS_Store suppressed from Linux backend")

    // 6. LOCK & UNLOCK
    let lockResp = try sendWebDAVRequestOverSocketPair(server: server, method: "LOCK", path: "/notes.txt")
    try assertTrue(lockResp.statusCode == 200, "LOCK status 200")
    try assertTrue(lockResp.headers["lock-token"] != nil, "LOCK token header present")

    let unlockResp = try sendWebDAVRequestOverSocketPair(server: server, method: "UNLOCK", path: "/notes.txt")
    try assertTrue(unlockResp.statusCode == 204, "UNLOCK status 204")
}

@MainActor
func runLiveVMExt4WebDAVIntegrationTest() async throws {
    let assets = try await ImageBuilder.ensurePrepared(force: false)
    let testImgURL = URL(fileURLWithPath: "/tmp/tuxdisk-e2e-\(UUID().uuidString).img")
    defer { try? FileManager.default.removeItem(at: testImgURL) }

    try await Operations.createDiskImage(
        path: testImgURL.path,
        sizeString: "32M",
        filesystem: "ext4",
        label: "FinderE2E",
        useLUKS: false,
        useLVM: false,
        passphrase: nil
    )

    let bridgePipes = SerialBridgePipes()
    let client = SerialGuestFSClient(readHandle: bridgePipes.hostReadHandle, writeHandle: bridgePipes.hostWriteHandle)
    let webdav = FinderWebDAVServer(backend: client, readOnly: false, suppressMacMetadata: true)

    final class Box: @unchecked Sendable {
        var error: Error? = nil
    }
    let box = Box()

    let vmOpts = VMConfigurationOptions(
        kernelURL: assets.rawKernelURL,
        initrdURL: assets.bootInitrdURL,
        rootDiskURL: assets.rootDiskURL,
        rootDiskReadOnly: true,
        externalDisks: [testImgURL.path],
        externalDisksReadOnly: false,
        allowInternalDisks: false,
        sharedDirectories: [],
        cpuCount: 2,
        memorySizeMB: 1024,
        kernelCommandLine: "console=hvc0 quiet vm.ro=0 vm.bridge=1 vm.browse_only=1 vm.quiet=1",
        rawTerminal: false,
        quietAttachmentLogs: true,
        bridgePipes: bridgePipes,
        onVMStarted: {
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let label = try client.waitUntilReady(timeoutSeconds: 60.0)
                    try assertTrue(label == "FinderE2E", "Expected volume label FinderE2E, got \(label)")

                    // MKCOL /Documents
                    let mkcol = try sendWebDAVRequestOverSocketPair(server: webdav, method: "MKCOL", path: "/Documents")
                    try assertTrue(mkcol.statusCode == 201, "Live VM MKCOL /Documents")

                    // PUT /Documents/hello.txt
                    let content = "Hello from macOS Finder on Linux ext4!"
                    let put = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "PUT",
                        path: "/Documents/hello.txt",
                        body: Data(content.utf8)
                    )
                    try assertTrue(put.statusCode == 201, "Live VM PUT /Documents/hello.txt")

                    // PUT .DS_Store & ._hello.txt (should be suppressed from ext4 disk)
                    let putDS = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "PUT",
                        path: "/Documents/.DS_Store",
                        body: Data("junk".utf8)
                    )
                    try assertTrue(putDS.statusCode == 201, "Live VM PUT .DS_Store")

                    let putAD = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "PUT",
                        path: "/Documents/._hello.txt",
                        body: Data("junk".utf8)
                    )
                    try assertTrue(putAD.statusCode == 201, "Live VM PUT ._hello.txt")

                    // GET /Documents/hello.txt
                    let getFull = try sendWebDAVRequestOverSocketPair(server: webdav, method: "GET", path: "/Documents/hello.txt")
                    try assertTrue(getFull.statusCode == 200, "Live VM GET status 200")
                    try assertTrue(String(data: getFull.body, encoding: .utf8) == content, "Live VM GET content matches")

                    // Range GET bytes=6-15 ("from macOS")
                    let getRange = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "GET",
                        path: "/Documents/hello.txt",
                        headers: ["Range": "bytes=6-15"]
                    )
                    try assertTrue(getRange.statusCode == 206, "Live VM Range GET status 206")
                    try assertTrue(String(data: getRange.body, encoding: .utf8) == "from macOS", "Live VM Range GET slice")

                    // MOVE /Documents/hello.txt -> /Documents/renamed.txt
                    let move = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "MOVE",
                        path: "/Documents/hello.txt",
                        headers: ["Destination": "http://localhost/Documents/renamed.txt"]
                    )
                    try assertTrue(move.statusCode == 201, "Live VM MOVE status 201")

                    // PROPFIND /Documents
                    let prop = try sendWebDAVRequestOverSocketPair(
                        server: webdav,
                        method: "PROPFIND",
                        path: "/Documents",
                        headers: ["Depth": "1"]
                    )
                    let propXML = String(data: prop.body, encoding: .utf8) ?? ""
                    try assertTrue(prop.statusCode == 207, "Live VM PROPFIND 207")
                    try assertTrue(propXML.contains("/Documents/renamed.txt"), "PROPFIND contains renamed.txt")
                    try assertTrue(!propXML.contains(".DS_Store"), "PROPFIND omits .DS_Store")

                    // Verify directly on the Linux filesystem that .DS_Store was never written to ext4
                    var dsExistsOnLinux = false
                    if (try? client.stat(path: "/Documents/.DS_Store")) != nil {
                        dsExistsOnLinux = true
                    }
                    try assertTrue(!dsExistsOnLinux, ".DS_Store was never written to Linux ext4 disk")
                } catch {
                    box.error = error
                }
                try? client.shutdown()
            }
        }
    )

    try await VMRunner.run(options: vmOpts)
    if let err = box.error {
        throw err
    }
}

#if TUXDISK_TEST_RUNNER
@main
struct TuxDiskTestRunner {
    static func main() async {
        do {
            print("==> Running tuxdisk unit & integration tests...")
            try runByteSizeParsingTest()
            print("  ✓ testByteSizeParsing passed")
            try runRawArm64KernelDetectionTest()
            print("  ✓ testRawArm64KernelDetectionAndExtraction passed")
            try runInternalDiskProtectionTest()
            print("  ✓ testInternalDiskProtection passed")
            try runBrowseCLIArgumentParsingTest()
            print("  ✓ testBrowseCLIArgumentParsing passed")
            try runFinderMetadataFilterTest()
            print("  ✓ testFinderMetadataFilter passed")
            try runWebDAVServerAndMetadataSuppressionTest()
            print("  ✓ testWebDAVServerAndMetadataSuppression passed")
            try await runLiveVMExt4WebDAVIntegrationTest()
            print("  ✓ testLiveVMExt4WebDAVIntegration passed (ext4 VM mount + WebDAV CRUD + .DS_Store suppression)")
            ConsoleStyle.success("All 7 test suites passed!")
        } catch {
            ConsoleStyle.error("Test failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
#else
@Test func testByteSizeParsing() throws { try runByteSizeParsingTest() }
@Test func testRawArm64KernelDetectionAndExtraction() throws { try runRawArm64KernelDetectionTest() }
@Test func testInternalDiskProtection() throws { try runInternalDiskProtectionTest() }
@Test func testBrowseCLIArgumentParsing() throws { try runBrowseCLIArgumentParsingTest() }
@Test func testFinderMetadataFilter() throws { try runFinderMetadataFilterTest() }
@Test func testWebDAVServerAndMetadataSuppression() throws { try runWebDAVServerAndMetadataSuppressionTest() }
#endif
