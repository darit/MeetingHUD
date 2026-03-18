import Foundation

/// Simple crash reporter that writes exception info to ~/Library/Logs/MeetingHUD/.
/// macOS also generates standard crash reports in ~/Library/Logs/DiagnosticReports/.
enum CrashReporter {

    static let logDir: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MeetingHUD")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    static func install() {
        // Force logDir initialization
        _ = logDir

        NSSetUncaughtExceptionHandler(crashExceptionHandler)
        signal(SIGABRT, crashSignalHandler)
        signal(SIGSEGV, crashSignalHandler)
        signal(SIGBUS, crashSignalHandler)
        signal(SIGFPE, crashSignalHandler)
    }

    fileprivate static func writeReport(_ content: String) {
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let fileName = "crash_\(timestamp.replacingOccurrences(of: ":", with: "-")).log"
        let fileURL = logDir.appendingPathComponent(fileName)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)

        let latestURL = logDir.appendingPathComponent("latest_crash.log")
        try? FileManager.default.removeItem(at: latestURL)
        try? content.write(to: latestURL, atomically: true, encoding: .utf8)
    }
}

// Free functions for C callbacks

private func crashExceptionHandler(_ exception: NSException) {
    let report = """
    MeetingHUD Crash Report
    =======================
    Time: \(ISO8601DateFormatter().string(from: .now))
    Exception: \(exception.name.rawValue)
    Reason: \(exception.reason ?? "unknown")

    Call Stack:
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
    CrashReporter.writeReport(report)
}

private func crashSignalHandler(_ sig: Int32) {
    let signalName: String
    switch sig {
    case SIGABRT: signalName = "SIGABRT"
    case SIGSEGV: signalName = "SIGSEGV"
    case SIGBUS: signalName = "SIGBUS"
    case SIGFPE: signalName = "SIGFPE"
    default: signalName = "SIG\(sig)"
    }
    let report = """
    MeetingHUD Fatal Signal
    =======================
    Time: \(ISO8601DateFormatter().string(from: .now))
    Signal: \(signalName)

    Thread Backtrace:
    \(Thread.callStackSymbols.joined(separator: "\n"))
    """
    CrashReporter.writeReport(report)
}
