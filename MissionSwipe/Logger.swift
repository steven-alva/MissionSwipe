import Foundation

enum Logger {
    private static let debugLoggingKey = "EnableDebugLogging"
    private static let logQueue = DispatchQueue(label: "io.github.stevenalva.MissionSwipe.Logger")
    private static let maxLogFileSize = 2 * 1024 * 1024

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
        let line = "[MissionSwipe] [\(timestamp())] [\(level.rawValue)] \(message)"
        print(line)
        appendToFile(line)
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func appendToFile(_ line: String) {
        logQueue.async {
            do {
                let fileManager = FileManager.default
                let logsDirectory = fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Logs", isDirectory: true)
                    .appendingPathComponent("MissionSwipe", isDirectory: true)
                let logFile = logsDirectory.appendingPathComponent("MissionSwipe.log")
                let rotatedLogFile = logsDirectory.appendingPathComponent("MissionSwipe.log.1")

                try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

                if let attributes = try? fileManager.attributesOfItem(atPath: logFile.path),
                   let fileSize = attributes[.size] as? NSNumber,
                   fileSize.intValue > maxLogFileSize {
                    try? fileManager.removeItem(at: rotatedLogFile)
                    try? fileManager.moveItem(at: logFile, to: rotatedLogFile)
                }

                if !fileManager.fileExists(atPath: logFile.path) {
                    fileManager.createFile(atPath: logFile.path, contents: nil)
                }

                let handle = try FileHandle(forWritingTo: logFile)
                try handle.seekToEnd()
                if let data = "\(line)\n".data(using: .utf8) {
                    try handle.write(contentsOf: data)
                }
                try handle.close()
            } catch {
                print("[MissionSwipe] [\(timestamp())] [ERROR] Failed to write log file: \(error)")
            }
        }
    }
}
