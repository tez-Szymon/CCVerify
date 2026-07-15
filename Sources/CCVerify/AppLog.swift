import Foundation

enum AppPaths {
    static let appSupport: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CCVerify", isDirectory: true)
    static let reviews: URL = appSupport.appendingPathComponent("reviews", isDirectory: true)
    static let stateFile: URL = appSupport.appendingPathComponent("state.json")
}

/// Tiny append-only log at ~/Library/Application Support/CCVerify/ccverify.log
/// so poller activity and failures are inspectable outside the UI.
enum AppLog {
    private static let queue = DispatchQueue(label: "ccverify.log")
    private static let fileURL = AppPaths.appSupport.appendingPathComponent("ccverify.log")

    static func log(_ message: String) {
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 5_000_000 {
                try? fm.removeItem(at: fileURL)
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) \(message)\n"
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }
}
