import Foundation
import Darwin

public struct GuestFSItem: Sendable, Equatable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedTime: Int64

    public init(name: String, isDirectory: Bool, size: Int64, modifiedTime: Int64) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedTime = modifiedTime
    }
}

public struct GuestFSStats: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }
}

public enum GuestFSError: LocalizedError, Equatable {
    case notFound
    case readOnly
    case accessDenied
    case noMount
    case invalidPath
    case ioError(String)
    case bridgeClosed

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "File or directory not found on Linux disk."
        case .readOnly:
            return "Linux disk is mounted in read-only mode."
        case .accessDenied:
            return "Permission denied on Linux disk."
        case .noMount:
            return "No mountable Linux filesystem was found on the attached disk(s)."
        case .invalidPath:
            return "Invalid filesystem path."
        case .ioError(let msg):
            return "Linux filesystem I/O error: \(msg)"
        case .bridgeClosed:
            return "Connection to guest VM filesystem bridge closed."
        }
    }
}

public protocol GuestFSBackend: Sendable {
    func ping() throws -> String
    func stat(path: String) throws -> GuestFSItem
    func list(path: String) throws -> [GuestFSItem]
    func statfs() throws -> GuestFSStats
    func readFile(path: String, offset: Int64, length: Int) throws -> Data
    func writeFile(path: String, offset: Int64, data: Data, truncate: Bool) throws
    func mkdir(path: String) throws
    func delete(path: String) throws
    func move(from: String, to: String) throws
    func copy(from: String, to: String) throws
    func sync() throws
    func shutdown() throws
}

/// Filters macOS Finder metadata clutter files (`.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd`)
public enum FinderMetadataFilter {
    private static let metadataDirectoryNames: Set<String> = [
        ".Spotlight-V100",
        ".Trashes",
        ".fseventsd",
        ".TemporaryItems",
        ".DocumentRevisions-V100"
    ]

    private static let metadataExactFileNames: Set<String> = [
        ".DS_Store",
        ".VolumeIcon.icns",
        ".apdisk",
        ".metadata_never_index",
        "Backups.backupdb"
    ]

    public static func isMacMetadataPath(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last else { return false }
        if last.hasPrefix("._") {
            return true
        }
        if metadataExactFileNames.contains(last) || metadataDirectoryNames.contains(last) {
            return true
        }
        for comp in components {
            if metadataDirectoryNames.contains(comp) {
                return true
            }
        }
        return false
    }

    public static func isMacMetadataName(_ name: String) -> Bool {
        name.hasPrefix("._") || metadataExactFileNames.contains(name) || metadataDirectoryNames.contains(name)
    }
}

/// Communicates with `/usr/local/bin/fs-bridge` inside the Linux VM over `/dev/hvc1`
public final class SerialGuestFSClient: GuestFSBackend, @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let lock = NSLock()
    private var cachedStats: (stats: GuestFSStats, timestamp: TimeInterval)? = nil

    public init(readHandle: FileHandle, writeHandle: FileHandle) {
        self.readFD = readHandle.fileDescriptor
        self.writeFD = writeHandle.fileDescriptor
    }

    /// Waits for `/usr/local/bin/fs-bridge` in the guest VM to finish mounting disks and respond to `PING`
    public func waitUntilReady(timeoutSeconds: TimeInterval = 180.0) throws -> String {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastPingSent = Date.distantPast

        while Date() < deadline {
            if Date().timeIntervalSince(lastPingSent) >= 0.4 {
                _ = try? writeAll(Data("PING\n".utf8), timeoutMs: 200)
                lastPingSent = Date()
            }

            if let line = try readLineWithTimeout(timeoutMs: 400) {
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                if trimmed.hasPrefix("OK\t") {
                    let b64 = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let payload = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) ?? Data()
                    let label = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "TuxDisk"
                    return label.isEmpty ? "TuxDisk" : label
                } else if trimmed.hasPrefix("ERR\t") {
                    let code = String(trimmed.dropFirst(4))
                    if code == "ENOMOUNT" {
                        throw GuestFSError.noMount
                    }
                }
            }
        }
        throw GuestFSError.ioError("Timed out waiting for Linux VM filesystem bridge to become ready.")
    }

    public func ping() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let data = try executeCommand("PING")
        let label = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "TuxDisk"
        return label.isEmpty ? "TuxDisk" : label
    }

    public func stat(path: String) throws -> GuestFSItem {
        lock.lock()
        defer { lock.unlock() }
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        let data = try executeCommand("STAT\t\(b64)")
        guard let text = String(data: data, encoding: .utf8) else {
            throw GuestFSError.ioError("Invalid UTF-8 in STAT response")
        }
        let parts = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else {
            throw GuestFSError.ioError("Malformed STAT response: \(text)")
        }
        let isDir = (parts[0] == "dir")
        let size = Int64(parts[1]) ?? 0
        let mtime = Int64(parts[2]) ?? 0
        let name = URL(fileURLWithPath: path).lastPathComponent
        return GuestFSItem(name: name.isEmpty ? "/" : name, isDirectory: isDir, size: size, modifiedTime: mtime)
    }

    public func list(path: String) throws -> [GuestFSItem] {
        lock.lock()
        defer { lock.unlock() }
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        let data = try executeCommand("LIST\t\(b64)")
        guard let text = String(data: data, encoding: .utf8) else {
            throw GuestFSError.ioError("Invalid UTF-8 in LIST response")
        }
        var items: [GuestFSItem] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4 else { continue }
            let name = parts[3].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if name == "." || name == ".." { continue }
            let isDir = (parts[0] == "dir")
            let size = Int64(parts[1]) ?? 0
            let mtime = Int64(parts[2]) ?? 0
            items.append(GuestFSItem(name: name, isDirectory: isDir, size: size, modifiedTime: mtime))
        }
        return items
    }

    public func statfs() throws -> GuestFSStats {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if let cached = cachedStats, now - cached.timestamp < 2.0 {
            return cached.stats
        }
        let data = try executeCommand("STATFS")
        let text = String(data: data, encoding: .utf8) ?? "0\t0\t0"
        let parts = text.split(separator: "\t").map(String.init)
        let total = parts.count > 0 ? (Int64(parts[0]) ?? 0) : 0
        let used = parts.count > 1 ? (Int64(parts[1]) ?? 0) : 0
        let avail = parts.count > 2 ? (Int64(parts[2]) ?? 0) : 0
        let stats = GuestFSStats(totalBytes: total, usedBytes: used, availableBytes: avail)
        cachedStats = (stats, now)
        return stats
    }

    public func readFile(path: String, offset: Int64, length: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        return try executeCommand("READ\t\(b64)\t\(max(0, offset))\t\(max(0, length))")
    }

    public func writeFile(path: String, offset: Int64, data: Data, truncate: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        cachedStats = nil
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        let truncFlag = truncate ? 1 : 0
        let dataB64 = data.base64EncodedString()
        _ = try executeCommand("WRITE\t\(b64)\t\(max(0, offset))\t\(truncFlag)\t\(dataB64)")
    }

    public func mkdir(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        _ = try executeCommand("MKDIR\t\(b64)")
    }

    public func delete(path: String) throws {
        lock.lock()
        defer { lock.unlock() }
        cachedStats = nil
        let b64 = Data(normalizeRelPath(path).utf8).base64EncodedString()
        _ = try executeCommand("DELETE\t\(b64)")
    }

    public func move(from: String, to: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let srcB64 = Data(normalizeRelPath(from).utf8).base64EncodedString()
        let dstB64 = Data(normalizeRelPath(to).utf8).base64EncodedString()
        _ = try executeCommand("MOVE\t\(srcB64)\t\(dstB64)")
    }

    public func copy(from: String, to: String) throws {
        lock.lock()
        defer { lock.unlock() }
        cachedStats = nil
        let srcB64 = Data(normalizeRelPath(from).utf8).base64EncodedString()
        let dstB64 = Data(normalizeRelPath(to).utf8).base64EncodedString()
        _ = try executeCommand("COPY\t\(srcB64)\t\(dstB64)")
    }

    public func sync() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try executeCommand("SYNC")
    }

    public func shutdown() throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try? executeCommand("SHUTDOWN", timeoutMs: 3000)
    }

    private func normalizeRelPath(_ path: String) -> String {
        var clean = path
        while clean.hasPrefix("/") { clean.removeFirst() }
        while clean.hasSuffix("/") { clean.removeLast() }
        return clean
    }

    private func executeCommand(_ cmd: String, timeoutMs: Int32 = 30000) throws -> Data {
        let headerData = Data((cmd + "\n").utf8)
        try writeAll(headerData, timeoutMs: timeoutMs)

        while true {
            guard let line = try readLineWithTimeout(timeoutMs: timeoutMs) else {
                throw GuestFSError.bridgeClosed
            }
            let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            if trimmed.hasPrefix("OK\t") {
                let b64 = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
                if b64.isEmpty {
                    return Data()
                }
                return Data(base64Encoded: b64, options: .ignoreUnknownCharacters) ?? Data()
            } else if trimmed == "OK" {
                return Data()
            } else if trimmed.hasPrefix("ERR\t") {
                let code = String(trimmed.dropFirst(4))
                switch code {
                case "ENOENT":
                    throw GuestFSError.notFound
                case "EROFS":
                    throw GuestFSError.readOnly
                case "EACCES":
                    throw GuestFSError.accessDenied
                case "ENOMOUNT":
                    throw GuestFSError.noMount
                case "EINVAL":
                    throw GuestFSError.invalidPath
                default:
                    throw GuestFSError.ioError(code)
                }
            }
        }
    }

    private func writeAll(_ data: Data, timeoutMs: Int32) throws {
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                var pfd = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                let pr = Darwin.poll(&pfd, 1, timeoutMs)
                if pr <= 0 {
                    throw GuestFSError.ioError("Write timeout on VM bridge")
                }
                let n = Darwin.write(writeFD, base.advanced(by: offset), data.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw GuestFSError.bridgeClosed
                }
                offset += n
            }
        }
    }

    private func readLineWithTimeout(timeoutMs: Int32) throws -> String? {
        var bytes = Data()
        var byte: UInt8 = 0
        while true {
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, timeoutMs)
            if pr == 0 {
                return nil
            }
            if pr < 0 {
                if errno == EINTR { continue }
                throw GuestFSError.bridgeClosed
            }
            let n = Darwin.read(readFD, &byte, 1)
            if n == 0 {
                return bytes.isEmpty ? nil : String(data: bytes, encoding: .utf8)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw GuestFSError.bridgeClosed
            }
            bytes.append(byte)
            if byte == UInt8(ascii: "\n") {
                return String(data: bytes, encoding: .utf8) ?? ""
            }
        }
    }

    private func readExact(count: Int, timeoutMs: Int32) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var offset = 0
            while offset < count {
                var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
                let pr = Darwin.poll(&pfd, 1, timeoutMs)
                if pr <= 0 {
                    throw GuestFSError.ioError("Read timeout on VM bridge")
                }
                let n = Darwin.read(readFD, base.advanced(by: offset), count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw GuestFSError.bridgeClosed
                }
                offset += n
            }
        }
        return result
    }
}

/// Embedded localhost HTTP/1.1 + WebDAV Class 1 & 2 server for macOS `mount_webdav` / Finder
public final class FinderWebDAVServer: @unchecked Sendable {
    public let backend: GuestFSBackend
    public let readOnly: Bool
    public let suppressMacMetadata: Bool
    public private(set) var port: UInt16 = 0

    private var listenFD: Int32 = -1
    private var isRunning = false
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "tuxdisk.webdav.accept", qos: .userInitiated)
    private let clientQueue = DispatchQueue(label: "tuxdisk.webdav.clients", qos: .userInitiated, attributes: .concurrent)

    private struct EphemeralEntry {
        var isDirectory: Bool
        var data: Data
        var modifiedTime: Int64
    }

    private var ephemeralMetadata: [String: EphemeralEntry] = [:]

    public init(backend: GuestFSBackend, readOnly: Bool = false, suppressMacMetadata: Bool = true) {
        self.backend = backend
        self.readOnly = readOnly
        self.suppressMacMetadata = suppressMacMetadata
    }

    public var baseURLString: String {
        "http://127.0.0.1:\(port)/"
    }

    public func start(preferredPort: UInt16 = 0) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "Failed to create WebDAV socket"
            ])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: "Failed to bind localhost WebDAV server port: \(String(cString: strerror(err)))"
            ])
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: "Failed to listen on localhost WebDAV socket: \(String(cString: strerror(err)))"
            ])
        }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }

        stateLock.lock()
        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.isRunning = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        isRunning = false
        stateLock.unlock()
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let fd = listenFD
            let running = isRunning
            stateLock.unlock()
            guard running && fd >= 0 else { break }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(fd, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            clientQueue.async { [weak self] in
                self?.handleClientConnection(clientFD)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let rawTarget: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    public func handleClientConnection(_ fd: Int32) {
        defer { Darwin.close(fd) }

        while let req = readHTTPRequest(from: fd) {
            let shouldClose = (req.headers["connection"]?.lowercased() == "close")
            handleRequest(req, socketFD: fd)
            if shouldClose {
                break
            }
        }
    }

    private func readHTTPRequest(from fd: Int32) -> HTTPRequest? {
        var headerBuf = Data()
        var byte: UInt8 = 0
        let crlfcrlf = Data([13, 10, 13, 10])

        while headerBuf.count < 65536 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 30000)
            if pr <= 0 { return nil }

            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { return nil }
            headerBuf.append(byte)
            if headerBuf.count >= 4 && headerBuf.suffix(4) == crlfcrlf {
                break
            }
        }

        guard let headerStr = String(data: headerBuf, encoding: .utf8) else { return nil }
        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let reqParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard reqParts.count >= 2 else { return nil }

        let method = reqParts[0].uppercased()
        let rawTarget = reqParts[1]
        let decodedPath = Self.decodeURLPath(rawTarget)

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colon = line.firstIndex(of: ":") {
                let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
                let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        if let expect = headers["expect"], expect.lowercased().contains("100-continue") {
            sendRaw("HTTP/1.1 100 Continue\r\n\r\n", to: fd)
        }

        var body = Data()
        if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
            if let chunkedData = readChunkedBody(from: fd) {
                body = chunkedData
            }
        } else if let clStr = headers["content-length"], let contentLength = Int(clStr), contentLength > 0 {
            guard let exactBody = readExactBytes(from: fd, count: contentLength) else {
                return nil
            }
            body = exactBody
        }

        return HTTPRequest(method: method, rawTarget: rawTarget, path: decodedPath, headers: headers, body: body)
    }

    private func readChunkedBody(from fd: Int32) -> Data? {
        var result = Data()
        while true {
            var lineBytes = Data()
            var b: UInt8 = 0
            while lineBytes.count < 128 {
                let n = Darwin.read(fd, &b, 1)
                if n <= 0 { return nil }
                lineBytes.append(b)
                if lineBytes.count >= 2 && lineBytes.suffix(2) == Data([13, 10]) {
                    break
                }
            }
            guard let sizeLine = String(data: lineBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ";").first,
                let chunkSize = Int(sizeLine, radix: 16) else {
                return nil
            }
            if chunkSize == 0 {
                _ = readExactBytes(from: fd, count: 2)
                break
            }
            guard let chunk = readExactBytes(from: fd, count: chunkSize) else { return nil }
            result.append(chunk)
            _ = readExactBytes(from: fd, count: 2)
        }
        return result
    }

    private func readExactBytes(from fd: Int32, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        var buf = Data(count: count)
        var ok = true
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { ok = false; return }
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    ok = false
                    return
                }
                offset += n
            }
        }
        return ok ? buf : nil
    }

    public static func decodeURLPath(_ rawTarget: String) -> String {
        var pathPart = rawTarget
        if pathPart.hasPrefix("http://") || pathPart.hasPrefix("https://"),
           let url = URL(string: pathPart) {
            pathPart = url.path
        }
        if let qIdx = pathPart.firstIndex(of: "?") {
            pathPart = String(pathPart[..<qIdx])
        }
        let decoded = pathPart.removingPercentEncoding ?? pathPart
        var comps: [String] = []
        for seg in decoded.split(separator: "/") {
            if seg == "." { continue }
            if seg == ".." {
                if !comps.isEmpty { comps.removeLast() }
                continue
            }
            comps.append(String(seg))
        }
        return "/" + comps.joined(separator: "/")
    }

    private func handleRequest(_ req: HTTPRequest, socketFD: Int32) {
        switch req.method {
        case "OPTIONS":
            sendResponse(
                status: "200 OK",
                headers: [
                    "DAV": "1, 2",
                    "MS-Author-Via": "DAV",
                    "Allow": "OPTIONS, GET, HEAD, PUT, POST, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK",
                    "Accept-Ranges": "bytes"
                ],
                body: Data(),
                to: socketFD
            )

        case "LOCK":
            let token = "opaquelocktoken:\(UUID().uuidString.lowercased())"
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:">
              <D:lockdiscovery>
                <D:activelock>
                  <D:locktype><D:write/></D:locktype>
                  <D:lockscope><D:exclusive/></D:lockscope>
                  <D:depth>0</D:depth>
                  <D:timeout>Second-3600</D:timeout>
                  <D:locktoken><D:href>\(token)</D:href></D:locktoken>
                </D:activelock>
              </D:lockdiscovery>
            </D:prop>
            """
            sendResponse(
                status: "200 OK",
                headers: [
                    "Content-Type": "application/xml; charset=\"utf-8\"",
                    "Lock-Token": "<\(token)>"
                ],
                body: Data(xml.utf8),
                to: socketFD
            )

        case "UNLOCK":
            sendResponse(status: "204 No Content", headers: [:], body: Data(), to: socketFD)

        case "PROPPATCH":
            let href = Self.encodeHREF(req.path, isDirectory: false)
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:multistatus xmlns:D="DAV:">
              <D:response>
                <D:href>\(href)</D:href>
                <D:propstat>
                  <D:prop/>
                  <D:status>HTTP/1.1 200 OK</D:status>
                </D:propstat>
              </D:response>
            </D:multistatus>
            """
            sendResponse(
                status: "207 Multi-Status",
                headers: ["Content-Type": "application/xml; charset=\"utf-8\""],
                body: Data(xml.utf8),
                to: socketFD
            )

        case "PROPFIND":
            handlePropfind(req, socketFD: socketFD)

        case "GET":
            handleGetOrHead(req, isHead: false, socketFD: socketFD)

        case "HEAD":
            handleGetOrHead(req, isHead: true, socketFD: socketFD)

        case "PUT":
            handlePut(req, socketFD: socketFD)

        case "MKCOL":
            handleMkcol(req, socketFD: socketFD)

        case "DELETE":
            handleDelete(req, socketFD: socketFD)

        case "MOVE":
            handleMoveOrCopy(req, isMove: true, socketFD: socketFD)

        case "COPY":
            handleMoveOrCopy(req, isMove: false, socketFD: socketFD)

        default:
            sendResponse(status: "405 Method Not Allowed", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handlePropfind(_ req: HTTPRequest, socketFD: Int32) {
        let depth = req.headers["depth"]?.lowercased() ?? "1"

        if suppressMacMetadata && FinderMetadataFilter.isMacMetadataPath(req.path) {
            stateLock.lock()
            let meta = ephemeralMetadata[req.path]
            stateLock.unlock()
            guard let meta else {
                sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
                return
            }
            let item = GuestFSItem(
                name: URL(fileURLWithPath: req.path).lastPathComponent,
                isDirectory: meta.isDirectory,
                size: Int64(meta.data.count),
                modifiedTime: meta.modifiedTime
            )
            let xml = buildMultistatusXML(basePath: req.path, baseItem: item, children: [], stats: nil)
            sendResponse(
                status: "207 Multi-Status",
                headers: ["Content-Type": "application/xml; charset=\"utf-8\""],
                body: Data(xml.utf8),
                to: socketFD
            )
            return
        }

        do {
            let baseItem = try backend.stat(path: req.path)
            var children: [GuestFSItem] = []
            if baseItem.isDirectory && depth != "0" {
                let rawChildren = try backend.list(path: req.path)
                children = rawChildren.filter { item in
                    !(suppressMacMetadata && FinderMetadataFilter.isMacMetadataName(item.name))
                }
            }
            let fsStats = baseItem.isDirectory ? (try? backend.statfs()) : nil
            let xml = buildMultistatusXML(basePath: req.path, baseItem: baseItem, children: children, stats: fsStats)
            sendResponse(
                status: "207 Multi-Status",
                headers: ["Content-Type": "application/xml; charset=\"utf-8\""],
                body: Data(xml.utf8),
                to: socketFD
            )
        } catch GuestFSError.notFound {
            sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handleGetOrHead(_ req: HTTPRequest, isHead: Bool, socketFD: Int32) {
        if suppressMacMetadata && FinderMetadataFilter.isMacMetadataPath(req.path) {
            stateLock.lock()
            let meta = ephemeralMetadata[req.path]
            stateLock.unlock()
            guard let meta, !meta.isDirectory else {
                sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
                return
            }
            sendResponse(
                status: "200 OK",
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Accept-Ranges": "bytes"
                ],
                body: isHead ? Data() : meta.data,
                overrideContentLength: meta.data.count,
                to: socketFD
            )
            return
        }

        do {
            let item = try backend.stat(path: req.path)
            if item.isDirectory {
                sendResponse(
                    status: "200 OK",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data(),
                    to: socketFD
                )
                return
            }

            let totalSize = max(0, item.size)
            var rangeStart: Int64 = 0
            var rangeEnd: Int64 = max(0, totalSize - 1)
            var isPartial = false

            if let rangeHeader = req.headers["range"], rangeHeader.lowercased().hasPrefix("bytes="), totalSize > 0 {
                let spec = String(rangeHeader.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
                let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                if parts.count == 2 {
                    if parts[0].isEmpty, let suffixLen = Int64(parts[1]), suffixLen > 0 {
                        rangeStart = max(0, totalSize - suffixLen)
                        rangeEnd = totalSize - 1
                        isPartial = true
                    } else if let s = Int64(parts[0]), s >= 0 && s < totalSize {
                        rangeStart = s
                        if let e = Int64(parts[1]), e >= s {
                            rangeEnd = min(totalSize - 1, e)
                        } else {
                            rangeEnd = totalSize - 1
                        }
                        isPartial = true
                    }
                }
            }

            let lengthToRead = totalSize == 0 ? 0 : Int(max(0, rangeEnd - rangeStart + 1))
            let status = isPartial ? "206 Partial Content" : "200 OK"
            var respHeaders: [String: String] = [
                "Content-Type": "application/octet-stream",
                "Accept-Ranges": "bytes",
                "Last-Modified": Self.httpDateString(from: item.modifiedTime)
            ]
            if isPartial {
                respHeaders["Content-Range"] = "bytes \(rangeStart)-\(rangeEnd)/\(totalSize)"
            }

            if isHead || lengthToRead == 0 {
                sendResponse(
                    status: status,
                    headers: respHeaders,
                    body: Data(),
                    overrideContentLength: lengthToRead,
                    to: socketFD
                )
                return
            }

            // Stream file data in 256 KB chunks
            var headerLines = "HTTP/1.1 \(status)\r\n"
            respHeaders["Content-Length"] = "\(lengthToRead)"
            for (k, v) in respHeaders {
                headerLines += "\(k): \(v)\r\n"
            }
            headerLines += "\r\n"
            guard sendRaw(headerLines, to: socketFD) else { return }

            let chunkSize = 256 * 1024
            var remaining = lengthToRead
            var currentOffset = rangeStart
            while remaining > 0 {
                let step = min(chunkSize, remaining)
                let chunk = try backend.readFile(path: req.path, offset: currentOffset, length: step)
                if chunk.isEmpty {
                    let padding = Data(repeating: 0, count: remaining)
                    _ = sendData(padding, to: socketFD)
                    break
                }
                guard sendData(chunk, to: socketFD) else { break }
                currentOffset += Int64(chunk.count)
                remaining -= chunk.count
            }
        } catch GuestFSError.notFound {
            sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handlePut(_ req: HTTPRequest, socketFD: Int32) {
        if readOnly {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
            return
        }

        if suppressMacMetadata && FinderMetadataFilter.isMacMetadataPath(req.path) {
            stateLock.lock()
            if ephemeralMetadata.count > 256 {
                ephemeralMetadata.removeAll()
            }
            ephemeralMetadata[req.path] = EphemeralEntry(
                isDirectory: false,
                data: req.body,
                modifiedTime: Int64(Date().timeIntervalSince1970)
            )
            stateLock.unlock()
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
            return
        }

        do {
            let chunkSize = 64 * 1024
            if req.body.isEmpty {
                try backend.writeFile(path: req.path, offset: 0, data: Data(), truncate: true)
            } else {
                var offset = 0
                while offset < req.body.count {
                    let end = min(offset + chunkSize, req.body.count)
                    let slice = req.body.subdata(in: offset..<end)
                    try backend.writeFile(
                        path: req.path,
                        offset: Int64(offset),
                        data: slice,
                        truncate: offset == 0
                    )
                    offset = end
                }
            }
            try? backend.sync()
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.readOnly, GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handleMkcol(_ req: HTTPRequest, socketFD: Int32) {
        if readOnly {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
            return
        }

        if suppressMacMetadata && FinderMetadataFilter.isMacMetadataPath(req.path) {
            stateLock.lock()
            ephemeralMetadata[req.path] = EphemeralEntry(
                isDirectory: true,
                data: Data(),
                modifiedTime: Int64(Date().timeIntervalSince1970)
            )
            stateLock.unlock()
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
            return
        }

        do {
            try backend.mkdir(path: req.path)
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.readOnly, GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handleDelete(_ req: HTTPRequest, socketFD: Int32) {
        if readOnly {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
            return
        }

        if suppressMacMetadata && FinderMetadataFilter.isMacMetadataPath(req.path) {
            stateLock.lock()
            ephemeralMetadata.removeValue(forKey: req.path)
            stateLock.unlock()
            sendResponse(status: "204 No Content", headers: [:], body: Data(), to: socketFD)
            return
        }

        do {
            try backend.delete(path: req.path)
            sendResponse(status: "204 No Content", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.notFound {
            sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.readOnly, GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func handleMoveOrCopy(_ req: HTTPRequest, isMove: Bool, socketFD: Int32) {
        if readOnly {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
            return
        }
        guard let destHeader = req.headers["destination"] else {
            sendResponse(status: "400 Bad Request", headers: [:], body: Data(), to: socketFD)
            return
        }
        let destPath = Self.decodeURLPath(destHeader)

        if suppressMacMetadata && (FinderMetadataFilter.isMacMetadataPath(req.path) || FinderMetadataFilter.isMacMetadataPath(destPath)) {
            stateLock.lock()
            if let existing = ephemeralMetadata[req.path] {
                ephemeralMetadata[destPath] = existing
                if isMove { ephemeralMetadata.removeValue(forKey: req.path) }
            }
            stateLock.unlock()
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
            return
        }

        do {
            if isMove {
                try backend.move(from: req.path, to: destPath)
            } else {
                try backend.copy(from: req.path, to: destPath)
            }
            sendResponse(status: "201 Created", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.notFound {
            sendResponse(status: "404 Not Found", headers: [:], body: Data(), to: socketFD)
        } catch GuestFSError.readOnly, GuestFSError.accessDenied {
            sendResponse(status: "403 Forbidden", headers: [:], body: Data(), to: socketFD)
        } catch {
            sendResponse(status: "500 Internal Server Error", headers: [:], body: Data(), to: socketFD)
        }
    }

    private func buildMultistatusXML(
        basePath: String,
        baseItem: GuestFSItem,
        children: [GuestFSItem],
        stats: GuestFSStats?
    ) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"
        xml += buildResponseElement(path: basePath, item: baseItem, stats: stats)
        if baseItem.isDirectory {
            let prefix = basePath == "/" ? "" : basePath
            for child in children {
                let childPath = "\(prefix)/\(child.name)"
                xml += buildResponseElement(path: childPath, item: child, stats: nil)
            }
        }
        xml += "</D:multistatus>\n"
        return xml
    }

    private func buildResponseElement(path: String, item: GuestFSItem, stats: GuestFSStats?) -> String {
        let href = Self.encodeHREF(path, isDirectory: item.isDirectory)
        let displayName = Self.xmlEscape(item.name == "/" ? "TuxDisk" : item.name)
        let lastMod = Self.httpDateString(from: item.modifiedTime)
        let creationDate = Self.iso8601String(from: item.modifiedTime)

        var prop = "      <D:displayname>\(displayName)</D:displayname>\n"
        prop += "      <D:getlastmodified>\(lastMod)</D:getlastmodified>\n"
        prop += "      <D:creationdate>\(creationDate)</D:creationdate>\n"

        if item.isDirectory {
            prop += "      <D:resourcetype><D:collection/></D:resourcetype>\n"
            if let stats {
                prop += "      <D:quota-available-bytes>\(max(0, stats.availableBytes))</D:quota-available-bytes>\n"
                prop += "      <D:quota-used-bytes>\(max(0, stats.usedBytes))</D:quota-used-bytes>\n"
            }
        } else {
            prop += "      <D:resourcetype/>\n"
            prop += "      <D:getcontentlength>\(max(0, item.size))</D:getcontentlength>\n"
            prop += "      <D:getcontenttype>application/octet-stream</D:getcontenttype>\n"
        }

        return """
          <D:response>
            <D:href>\(href)</D:href>
            <D:propstat>
              <D:prop>
        \(prop)      </D:prop>
              <D:status>HTTP/1.1 200 OK</D:status>
            </D:propstat>
          </D:response>

        """
    }

    private static let allowedHREFChars: CharacterSet = {
        var cs = CharacterSet.urlPathAllowed
        cs.remove(charactersIn: "?#&+;=")
        return cs
    }()

    public static func encodeHREF(_ path: String, isDirectory: Bool) -> String {
        let segments = path.split(separator: "/").map { seg in
            String(seg).addingPercentEncoding(withAllowedCharacters: allowedHREFChars) ?? String(seg)
        }
        var encoded = "/" + segments.joined(separator: "/")
        if isDirectory && !encoded.hasSuffix("/") {
            encoded += "/"
        }
        return xmlEscape(encoded)
    }

    public static func xmlEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "&", with: "&amp;")
           .replacingOccurrences(of: "<", with: "&lt;")
           .replacingOccurrences(of: ">", with: "&gt;")
           .replacingOccurrences(of: "\"", with: "&quot;")
           .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func httpDateString(from epoch: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private static func iso8601String(from epoch: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    private func sendResponse(
        status: String,
        headers: [String: String],
        body: Data,
        overrideContentLength: Int? = nil,
        to fd: Int32
    ) {
        let contentLen = overrideContentLength ?? body.count
        var resp = "HTTP/1.1 \(status)\r\n"
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(contentLen)"
        allHeaders["Server"] = "tuxdisk-webdav/1.0"
        for (k, v) in allHeaders {
            resp += "\(k): \(v)\r\n"
        }
        resp += "\r\n"
        guard sendRaw(resp, to: fd) else { return }
        if !body.isEmpty {
            _ = sendData(body, to: fd)
        }
    }

    @discardableResult
    private func sendRaw(_ string: String, to fd: Int32) -> Bool {
        sendData(Data(string.utf8), to: fd)
    }

    @discardableResult
    private func sendData(_ data: Data, to fd: Int32) -> Bool {
        var success = true
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    success = false
                    return
                }
                offset += n
            }
        }
        return success
    }
}

/// Mounts the embedded WebDAV server into macOS Finder via `/sbin/mount_webdav`
public final class FinderMounter: @unchecked Sendable {
    public let mountPointURL: URL
    public let volumeLabel: String
    public let webdavURLString: String
    public private(set) var isMountedOnHost: Bool = false
    private let lock = NSLock()

    public init(volumeLabel: String, webdavURLString: String, customMountPoint: String? = nil) {
        let safeLabel = Self.sanitizeVolumeLabel(volumeLabel)
        self.volumeLabel = safeLabel
        self.webdavURLString = webdavURLString

        if let custom = customMountPoint, !custom.isEmpty {
            self.mountPointURL = URL(fileURLWithPath: (custom as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            self.mountPointURL = Self.defaultMountDirectory(for: safeLabel)
        }
    }

    public static func sanitizeVolumeLabel(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
        let str = String(String.UnicodeScalarView(filtered))
        return str.isEmpty ? "TuxDisk" : str
    }

    public static func defaultMountDirectory(for label: String) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty, sudoUser != "root" {
            let userVolumes = URL(fileURLWithPath: "/Users/\(sudoUser)/Volumes")
            return userVolumes.appendingPathComponent(label)
        }
        let homeVolumes = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Volumes")
        return homeVolumes.appendingPathComponent(label)
    }

    public func mountAndOpenInFinder(openWindow: Bool = true) throws {
        let fm = FileManager.default
        let parentDir = mountPointURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        // Ensure stale mount at same directory is unmounted first
        _ = runProcess(executable: "/sbin/umount", arguments: ["-f", mountPointURL.path])
        try fm.createDirectory(at: mountPointURL, withIntermediateDirectories: true)
        fixOwnershipForSudoUser(at: parentDir)
        fixOwnershipForSudoUser(at: mountPointURL)

        let env = ProcessInfo.processInfo.environment
        var mountStatus: Int32 = -1

        if let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty, sudoUser != "root", geteuid() == 0 {
            mountStatus = runProcess(
                executable: "/usr/bin/sudo",
                arguments: ["-u", sudoUser, "/sbin/mount_webdav", "-S", "-v", volumeLabel, webdavURLString, mountPointURL.path]
            )
        }

        if mountStatus != 0 {
            mountStatus = runProcess(
                executable: "/sbin/mount_webdav",
                arguments: ["-S", "-v", volumeLabel, webdavURLString, mountPointURL.path]
            )
        }

        lock.lock()
        self.isMountedOnHost = (mountStatus == 0)
        lock.unlock()

        if openWindow {
            let targetToOpen = (mountStatus == 0) ? mountPointURL.path : webdavURLString
            if let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty, sudoUser != "root", geteuid() == 0 {
                _ = runProcess(executable: "/usr/bin/sudo", arguments: ["-u", sudoUser, "/usr/bin/open", targetToOpen])
            } else {
                _ = runProcess(executable: "/usr/bin/open", arguments: [targetToOpen])
            }
        }
    }

    public func isStillMounted() -> Bool {
        lock.lock()
        let mounted = isMountedOnHost
        lock.unlock()
        guard mounted else { return true }

        let fm = FileManager.default
        let parentPath = mountPointURL.deletingLastPathComponent().path
        guard let mountAttrs = try? fm.attributesOfItem(atPath: mountPointURL.path),
              let parentAttrs = try? fm.attributesOfItem(atPath: parentPath),
              let mountDev = mountAttrs[.systemNumber] as? NSNumber,
              let parentDev = parentAttrs[.systemNumber] as? NSNumber else {
            return false
        }
        return mountDev != parentDev
    }

    public func unmountAndCleanup() {
        lock.lock()
        let wasMounted = isMountedOnHost
        isMountedOnHost = false
        lock.unlock()

        if wasMounted {
            let status = runProcess(executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", mountPointURL.path])
            if status != 0 {
                _ = runProcess(executable: "/sbin/umount", arguments: ["-f", mountPointURL.path])
            }
        }
        try? FileManager.default.removeItem(at: mountPointURL)
    }

    private func fixOwnershipForSudoUser(at url: URL) {
        let env = ProcessInfo.processInfo.environment
        guard geteuid() == 0,
              let sudoUser = env["SUDO_USER"], !sudoUser.isEmpty,
              let pw = getpwnam(sudoUser) else {
            return
        }
        let uid = pw.pointee.pw_uid
        let gid = pw.pointee.pw_gid
        _ = Darwin.chown(url.path, uid, gid)
    }

    private func runProcess(executable: String, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }
}
