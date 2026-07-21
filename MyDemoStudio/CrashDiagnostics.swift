import Foundation
import AppKit

/// Records why the app died.
///
/// An uncaught Objective-C exception calls `abort()`, and the resulting crash report
/// contains only "abort() called" — the exception's name, reason and stack are gone by
/// then. AppKit raises exactly this kind of exception from layout (an unsatisfiable
/// window layout while dragging a split divider, say), so without this the most likely
/// crash in a SwiftUI/AppKit app is also the least diagnosable one.
///
/// The report is written to `~/Library/Logs/MyDemoStudio/crash.log` *and* stderr.
enum CrashDiagnostics {

    static var logURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MyDemoStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("crash.log")
    }

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashDiagnostics.record(
                title: "Uncaught \(exception.name.rawValue)",
                detail: exception.reason ?? "no reason given",
                stack: exception.callStackSymbols
            )
        }
    }

    /// Appends one entry, newest last. Kept deliberately simple: this runs while the
    /// process is already dying, so it avoids anything that could itself fail.
    static func record(title: String, detail: String, stack: [String]) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var text = "\n===== \(stamp) — \(title) =====\n\(detail)\n"
        for (index, frame) in stack.prefix(40).enumerated() {
            text += String(format: "%3d %@\n", index, frame)
        }

        FileHandle.standardError.write(Data(text.utf8))

        let url = logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
