import Foundation
import Darwin

/// Captures console-style output from the host iOS app.
///
/// On iOS three paths produce "console output":
///
///   1. `print(…)` / `Swift.print` — writes to STDOUT (FD 1).
///   2. `NSLog(…)` — writes to STDERR (FD 2) AND to ASL/oslog.
///   3. `os_log(…)` / `Logger` (iOS 14+) — goes through the
///      structured oslog facility, NOT through STDOUT/STDERR.
///
/// Strategy: `dup2`-redirect FD 1 + FD 2 into a `Pipe`, kick off a
/// background `DispatchSource.makeReadSource` that reads bytes,
/// splits on newlines, and emits a [ConsoleEventData] per line. We
/// fan out to BOTH the original FD (so Xcode console / shell tail
/// still see the output) AND our pipe.
///
/// `os_log` content is NOT captured by this approach — that's the
/// system's structured-log channel, separate from stdio. Customers
/// using `Logger` directly need to bridge explicitly via
/// `Replay.log(level:message:stack:)`, same wiring pattern as
/// Android's Timber adapter.
///
/// Mirrors the Android SDK's `ConsoleCapture.kt` so the dashboard's
/// Console panel sees the same event shape from both platforms.
///
/// Lifecycle: [start] hooks FD 1+2; [stop] restores the originals
/// (best-effort — dup2 errors during teardown are logged + ignored).
/// Idempotent — `start`-after-`start` is a no-op.
final class ConsoleCapture {

    private let emit: (ConsoleEventData) -> Void
    private let lock = NSLock()

    private var running: Bool = false
    private var savedStdoutFD: Int32 = -1
    private var savedStderrFD: Int32 = -1
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?

    /// Per-FD line buffer. STDOUT + STDERR are separate streams; a
    /// partial line on one shouldn't be flushed when the other
    /// finishes a line.
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()

    /// Dedicated serial queue for both read sources so the buffer
    /// mutations don't race.
    private let readerQueue = DispatchQueue(
        label: "com.replayfy.ios.console",
        qos: .utility
    )

    init(emit: @escaping (ConsoleEventData) -> Void) {
        self.emit = emit
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        if running { return }
        running = true

        savedStdoutFD = Darwin.dup(STDOUT_FILENO)
        savedStderrFD = Darwin.dup(STDERR_FILENO)

        // STDOUT pipe
        let outPipe = Pipe()
        if Darwin.dup2(outPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 {
            stdoutPipe = outPipe
            stdoutSource = installReader(
                fd: outPipe.fileHandleForReading.fileDescriptor,
                level: "log",
                bufferOwner: { [weak self] in self?.stdoutBuffer ?? Data() },
                appender: { [weak self] data in self?.stdoutBuffer.append(data) },
                flusher: { [weak self] line in self?.flushLine(level: "log", line: line) },
                mirrorFD: savedStdoutFD
            )
        }

        // STDERR pipe
        let errPipe = Pipe()
        if Darwin.dup2(errPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0 {
            stderrPipe = errPipe
            stderrSource = installReader(
                fd: errPipe.fileHandleForReading.fileDescriptor,
                level: "error",
                bufferOwner: { [weak self] in self?.stderrBuffer ?? Data() },
                appender: { [weak self] data in self?.stderrBuffer.append(data) },
                flusher: { [weak self] line in self?.flushLine(level: "error", line: line) },
                mirrorFD: savedStderrFD
            )
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        if !running { return }
        running = false

        stdoutSource?.cancel()
        stderrSource?.cancel()
        stdoutSource = nil
        stderrSource = nil

        // Restore original FDs. Best-effort — if dup2 fails the
        // process keeps running with our pipe FDs which we then
        // close; that's still safe.
        if savedStdoutFD >= 0 { _ = Darwin.dup2(savedStdoutFD, STDOUT_FILENO); Darwin.close(savedStdoutFD); savedStdoutFD = -1 }
        if savedStderrFD >= 0 { _ = Darwin.dup2(savedStderrFD, STDERR_FILENO); Darwin.close(savedStderrFD); savedStderrFD = -1 }

        try? stdoutPipe?.fileHandleForReading.close()
        try? stdoutPipe?.fileHandleForWriting.close()
        try? stderrPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForWriting.close()
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Explicit emit path — called by [Replay.log] for customer-side
    /// loggers that don't write through STDOUT/STDERR (`Logger`,
    /// `os_log`, third-party loggers).
    func emitExplicit(level: String, message: String, stack: String?) {
        guard running, !message.isEmpty else { return }
        emit(ConsoleEventData(
            level: level,
            message: message,
            args: [],
            stack: stack
        ))
    }

    // MARK: - Internal

    /// Wire a [DispatchSourceRead] on [fd] that:
    ///   1. Reads available bytes.
    ///   2. Mirrors them to [mirrorFD] so the original console
    ///      output (Xcode / `log stream`) still works.
    ///   3. Appends to the per-stream buffer + flushes on newline.
    private func installReader(
        fd: Int32,
        level: String,
        bufferOwner: @escaping () -> Data,
        appender: @escaping (Data) -> Void,
        flusher: @escaping (String) -> Void,
        mirrorFD: Int32
    ) -> DispatchSourceRead {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readerQueue)
        source.setEventHandler { [weak self] in
            guard self != nil else { return }
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { return }
            let chunk = Data(bytes: buf, count: n)
            // Mirror to the original FD so Xcode + log stream keep
            // working. Best-effort — a failed write doesn't matter
            // (Xcode might not be connected during prod runs).
            if mirrorFD >= 0 {
                chunk.withUnsafeBytes { ptr in
                    _ = Darwin.write(mirrorFD, ptr.baseAddress, chunk.count)
                }
            }
            appender(chunk)
            // Drain complete lines from the buffer.
            var working = bufferOwner()
            while let nlRange = working.firstIndex(of: 0x0A) {
                let line = working.subdata(in: 0 ..< nlRange)
                if let str = String(data: line, encoding: .utf8),
                   !str.isEmpty,
                   !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    flusher(str)
                }
                working.removeSubrange(0 ... nlRange)
            }
            // Replace buffer (appender's pass-by-reference of `Data`
            // would copy; this re-syncs the trimmed buffer).
            if level == "log" {
                self?.stdoutBuffer = working
            } else {
                self?.stderrBuffer = working
            }
        }
        source.setCancelHandler { /* no-op; close handled in stop() */ }
        source.resume()
        return source
    }

    private func flushLine(level: String, line: String) {
        // Strip the NSLog timestamp prefix (e.g. "2026-05-29
        // 14:55:12.345 ReplayExample[123:456] foo") so the event
        // payload is just the message. Mirror what dashboards
        // typically display.
        let cleaned = stripNSLogPrefix(line)
        emit(ConsoleEventData(
            level: level,
            message: cleaned,
            args: [],
            stack: nil
        ))
    }

    /// NSLog prepends `YYYY-MM-DD HH:MM:SS.mmm AppName[PID:TID] `
    /// to every line. We trim it for cleaner dashboard rendering.
    /// `print()` / Swift `Swift.print` don't add this prefix — line
    /// passes through unchanged in that case.
    private func stripNSLogPrefix(_ line: String) -> String {
        // Regex would be elegant but adds Foundation regex import +
        // perf overhead on every line. Simple scan: skip up to and
        // including the first "] " sequence preceded by an NSLog-
        // style bracket.
        if let bracketRange = line.range(of: "] ") {
            // Sanity check: the prefix should start with a digit
            // (year) AND contain a colon (HH:MM:SS); otherwise this
            // is a legit log message with "] " in it.
            let prefix = line[..<bracketRange.lowerBound]
            if prefix.first?.isNumber == true && prefix.contains(":") {
                return String(line[bracketRange.upperBound...])
            }
        }
        return line
    }
}
