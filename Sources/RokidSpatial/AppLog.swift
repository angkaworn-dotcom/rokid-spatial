// Status history on disk, because the first display-trap freeze was
// undiagnosable after the fact: launching via `open` sends stderr nowhere and
// the unified log had nothing under this process name. One line per state
// change is cheap and makes the next incident reconstructible.

import Foundation

enum AppLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RokidSpatial.log")

    static func append(_ line: String) {
        let stamped = ISO8601DateFormatter().string(from: Date()) + " " + line + "\n"
        guard let data = stamped.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
