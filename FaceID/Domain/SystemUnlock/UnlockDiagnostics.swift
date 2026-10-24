//
//  UnlockDiagnostics.swift
//  Face ID
//
//  Append-only trace of the lock-screen unlock path, for the one class of bug that
//  cannot be reproduced on demand: "sometimes the face prompt never appears."
//
//  The trigger chain is event-driven and every step can fail *silently* — a guard
//  that returns early writes a status string nobody sees until they open Settings.
//  When a wake produces no prompt, the only way to tell "no event arrived" from
//  "an event arrived but a guard rejected it" is a record of what actually happened.
//
//  Deliberately plain text and capped: it is meant to be read, attached to a bug
//  report, or deleted — never parsed.
//

import Foundation

enum UnlockDiagnostics {

    /// `~/Library/Application Support/Face ID/diagnostics.log`
    static var logURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Face ID", isDirectory: true).appendingPathComponent("diagnostics.log")
    }

    /// Hard cap. Older content is dropped wholesale once exceeded — this is a trace
    /// of recent behaviour, not an archive.
    private static let maxBytes = 512 * 1024

    private static let queue = DispatchQueue(label: "faceid.diagnostics", qos: .utility)

    /// Records one line. Never throws; if the log can't be written the event is lost
    /// rather than taking the unlock path down with it.
    static func log(_ message: @autoclosure () -> String) {
        let line = "\(timestamp()) \(message())\n"
        queue.async {
            guard let url = logURL else { return }
            do {
                let directory = url.deletingLastPathComponent()
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? Int, size > maxBytes,
                   let handle = try? FileHandle(forWritingTo: url) {
                    try handle.truncate(atOffset: 0)
                    try handle.close()
                }
                let data = line.data(using: .utf8) ?? Data()
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                } else {
                    try data.write(to: url)
                }
            } catch {
                // Diagnostics must never be the reason a feature stops working.
            }
        }
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }

    /// Empties the log. Called from Settings' export button after a successful copy.
    static func clear() {
        queue.async {
            guard let url = logURL, FileManager.default.fileExists(atPath: url.path) else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
