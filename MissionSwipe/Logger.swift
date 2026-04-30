import Foundation

enum Logger {
    private static let debugLoggingKey = "EnableDebugLogging"

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard UserDefaults.standard.bool(forKey: debugLoggingKey) else {
            return
        }

        log(level: .debug, message())
    }

    static func info(_ message: @autoclosure () -> String) {
        log(level: .info, message())
    }

    static func warning(_ message: @autoclosure () -> String) {
        log(level: .warning, message())
    }

    static func error(_ message: @autoclosure () -> String) {
        log(level: .error, message())
    }

    private static func log(level: Level, _ message: String) {
        print("[MissionSwipe] [\(timestamp())] [\(level.rawValue)] \(message)")
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
