import Foundation

struct ProcessResult {
    var exitCode: Int32
    var stdout: Data
    var stderr: Data
    var timedOut: Bool

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

enum ProcessRunner {
    /// Run a subprocess off the main thread. If `stdoutFile` is given, stdout
    /// streams straight to that file; if `onStdoutLine` is given, each stdout
    /// line is delivered to the callback as it arrives (streaming JSON parsing).
    /// ANTHROPIC_* env vars are stripped so claude always uses subscription auth.
    static func run(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        timeout: TimeInterval? = nil,
        stdoutFile: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: runSync(
                        executable, arguments, cwd: cwd, timeout: timeout,
                        stdoutFile: stdoutFile, onStdoutLine: onStdoutLine))
            }
        }
    }

    private static func runSync(
        _ executable: String,
        _ arguments: [String],
        cwd: String?,
        timeout: TimeInterval?,
        stdoutFile: URL?,
        onStdoutLine: (@Sendable (String) -> Void)?
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        let toolDirs = [
            (AppSettings.claudePath as NSString).deletingLastPathComponent,
            (AppSettings.ghPath as NSString).deletingLastPathComponent,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (toolDirs + existing).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
        process.environment = env

        var outputHandle: FileHandle?
        let outPipe = Pipe()
        let lineGroup = DispatchGroup()
        if let onStdoutLine {
            lineGroup.enter()
            var buffer = Data()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF: flush any trailing partial line, stop reading.
                    if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                        onStdoutLine(line)
                    }
                    handle.readabilityHandler = nil
                    lineGroup.leave()
                    return
                }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer.prefix(upTo: nl)
                    buffer.removeSubrange(...nl)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        onStdoutLine(line)
                    }
                }
            }
            process.standardOutput = outPipe
        } else if let stdoutFile {
            try? FileManager.default.createDirectory(
                at: stdoutFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: stdoutFile.path, contents: nil)
            outputHandle = try? FileHandle(forWritingTo: stdoutFile)
            process.standardOutput = outputHandle ?? FileHandle.nullDevice
        } else {
            process.standardOutput = outPipe
        }
        let errPipe = Pipe()
        process.standardError = errPipe

        var timedOut = false
        var watchdog: DispatchWorkItem?
        if let timeout {
            let item = DispatchWorkItem {
                timedOut = true
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            watchdog = item
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
        }

        do {
            try process.run()
        } catch {
            watchdog?.cancel()
            return ProcessResult(
                exitCode: -1, stdout: Data(),
                stderr: Data("could not launch \(executable): \(error.localizedDescription)".utf8),
                timedOut: false)
        }

        // Drain stderr on a separate thread so neither pipe can fill and deadlock.
        let group = DispatchGroup()
        var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        var outData = Data()
        if onStdoutLine != nil {
            lineGroup.wait() // all lines delivered (EOF reached)
        } else if stdoutFile == nil {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        process.waitUntilExit()
        group.wait()
        watchdog?.cancel()
        try? outputHandle?.close()

        return ProcessResult(
            exitCode: process.terminationStatus, stdout: outData, stderr: errData, timedOut: timedOut)
    }
}
