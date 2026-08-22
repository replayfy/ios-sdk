import Foundation

/// Accumulates encoded binary messages and flushes them to /v1/mobile/i
/// on a 5-second cadence (or when the buffer crosses ~80% of the
/// 500 KB batch cap). Each flush is prefixed with a `batchMeta`
/// carrying the monotonic message index, then gzipped.
final class MobileCollector {
    private let transport: MobileTransport
    private let lock = NSLock()
    private var waiting: [Data] = []
    private var nextIndex: UInt64 = 0
    private var timer: Timer?

    private let maxBatchBytes = 500_000
    private let flushInterval: TimeInterval = 5

    init(transport: MobileTransport) {
        self.transport = transport
    }

    func start() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        flush(late: true)
    }

    /// Drop everything buffered WITHOUT sending — the cancelSession counterpart
    /// to stop() (which flushes). Stops the flush timer so nothing else leaves.
    func discard() {
        timer?.invalidate(); timer = nil
        lock.lock(); waiting.removeAll(); lock.unlock()
    }

    /// Append a single already-encoded message.
    func add(_ message: Data) {
        lock.lock()
        if waiting.count < 10_000 { waiting.append(message) }
        let total = waiting.reduce(0) { $0 + $1.count }
        lock.unlock()
        if total > Int(Double(maxBatchBytes) * 0.8) { flush() }
    }

    func flush(late: Bool = false) {
        lock.lock()
        guard !waiting.isEmpty else { lock.unlock(); return }
        var batch: [Data] = []
        var size = 0
        while let first = waiting.first, size + first.count <= maxBatchBytes {
            batch.append(first); waiting.removeFirst(); size += first.count
        }
        let startIndex = nextIndex
        nextIndex += UInt64(batch.count)
        lock.unlock()

        var content = MobileWire.batchMeta(firstIndex: startIndex, timestamp: nowMs())
        for m in batch { content.append(m) }

        if late {
            transport.sendLateMessages(content) { _ in }
            return
        }
        guard let gz = MobileGzip.compress(content) else { return }
        transport.sendMessages(gz) { [weak self] success in
            if !success {
                // Re-queue on failure (front of line, preserve order).
                self?.lock.lock()
                self?.waiting.insert(contentsOf: batch, at: 0)
                self?.lock.unlock()
            }
        }
    }

    /// Synchronous flush — used by the crash handler so the crash reaches
    /// the server before the process dies. Sends via the un-gzipped /late
    /// path and blocks the caller (up to 3s) on a semaphore.
    func flushBlocking() {
        lock.lock()
        guard !waiting.isEmpty else { lock.unlock(); return }
        let batch = waiting
        waiting.removeAll()
        let startIndex = nextIndex
        nextIndex += UInt64(batch.count)
        lock.unlock()

        var content = MobileWire.batchMeta(firstIndex: startIndex, timestamp: nowMs())
        for m in batch { content.append(m) }
        let sem = DispatchSemaphore(value: 0)
        transport.sendLateMessages(content) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }
}

func nowMs() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1000) }
