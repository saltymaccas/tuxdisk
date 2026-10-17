import Foundation
import Darwin

public final class TerminalManager: @unchecked Sendable {
    public static let shared = TerminalManager()

    private var originalTermios = termios()
    private var isRawMode = false
    private let lock = NSLock()

    private init() {}

    public func enableRawMode() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRawMode, isatty(STDIN_FILENO) != 0 else { return }
        guard tcgetattr(STDIN_FILENO, &originalTermios) == 0 else { return }

        var raw = originalTermios
        cfmakeraw(&raw)
        if tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 {
            isRawMode = true
        }
    }

    public func restore() {
        lock.lock()
        defer { lock.unlock() }

        guard isRawMode else { return }
        var orig = originalTermios
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &orig)
        isRawMode = false
    }

    public static func currentWindowSize() -> (cols: Int, rows: Int) {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0, ws.ws_row > 0 {
            return (Int(ws.ws_col), Int(ws.ws_row))
        }
        return (100, 30)
    }
}
