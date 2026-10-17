import Foundation

public enum ConsoleStyle {
    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let boldCyan = "\u{001B}[1;36m"
    public static let boldGreen = "\u{001B}[1;32m"
    public static let boldYellow = "\u{001B}[1;33m"
    public static let boldRed = "\u{001B}[1;31m"
    public static let boldWhite = "\u{001B}[1;37m"

    public static func info(_ message: String) {
        FileHandle.standardError.write(Data("\(boldCyan)==>\(reset) \(message)\n".utf8))
    }

    public static func success(_ message: String) {
        FileHandle.standardError.write(Data("\(boldGreen)✓\(reset) \(message)\n".utf8))
    }

    public static func warn(_ message: String) {
        FileHandle.standardError.write(Data("\(boldYellow)⚠\(reset) \(message)\n".utf8))
    }

    public static func error(_ message: String) {
        FileHandle.standardError.write(Data("\(boldRed)✗ Error:\(reset) \(message)\n".utf8))
    }

    /// Parses human-readable byte sizes such as "512M", "2G", "1.5GB", "800MiB"
    public static func parseByteSize(_ input: String) -> Int64? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }

        let suffixes: [(String, Double)] = [
            ("TIB", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("TB", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("T", 1024.0 * 1024.0 * 1024.0 * 1024.0),
            ("GIB", 1024.0 * 1024.0 * 1024.0),
            ("GB", 1024.0 * 1024.0 * 1024.0),
            ("G", 1024.0 * 1024.0 * 1024.0),
            ("MIB", 1024.0 * 1024.0),
            ("MB", 1024.0 * 1024.0),
            ("M", 1024.0 * 1024.0),
            ("KIB", 1024.0),
            ("KB", 1024.0),
            ("K", 1024.0),
            ("B", 1.0)
        ]

        for (suffix, multiplier) in suffixes {
            if trimmed.hasSuffix(suffix) {
                let numPart = String(trimmed.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
                if let val = Double(numPart), val > 0 {
                    return Int64(val * multiplier)
                }
                return nil
            }
        }

        // Default to MB if bare number, or bytes if large
        if let val = Int64(trimmed), val > 0 {
            return val < 1024 * 1024 ? val * 1024 * 1024 : val
        }
        return nil
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
