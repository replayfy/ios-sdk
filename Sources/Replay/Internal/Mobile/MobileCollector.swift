import Foundation

/// Accumulates encoded binary messages and flushes them to /v1/mobile/i
/// on a 5-second cadence (or when the buffer crosses ~80% of the
/// 500 KB batch cap). Each flush is prefixed with a `batchMeta`
/// carrying the monotonic message index, then gzipped.
final class MobileCollector {
    private let transport: MobileUploading
    private let lock = NSLock()
    private var waiting: [Data] = []
    private var nextIndex: UInt64 = 0
    private var timer: Timer?

    private let maxBatchBytes = 500_000
    private let flushInterval: TimeInterval = 5
    /// Batches one drain may send. Bounds a drain whose queue refills as fast
    /// as it uploads, so it (and a background task waiting on it) still ends.
    private let maxDrainRounds = 20

    // Send state, guarded by `lock`. One request is in flight at a time, so a
    // failed batch put back at the front of the queue keeps message order.
    private var sending = false
    private var roundsLeft = 0
    /// Session end: the batch that empties the queue goes to /late.
    private var lateRequested = false
    private var sendWaiters: [() -> Void] = []

    init(transport: MobileUploading) {
        self.transport = transport
    }

    func start() {
        DispatchQueue.main.async {
            self.timer = Timer.scheduledTimer(withTimeInterval: self.flushInterval, repeats: true) { [weak self] _ in
                self?.flush()
            }
        }
    }

    /// Session end: send everything queued, the last batch via /late (the
    /// server's end-of-session signal). The send callbacks hold `self`, so the
    /// drain finishes after ReplayCore drops its reference.
    func stop() {
        timer?.invalidate(); timer = nil
        request(drain: true, late: true, completion: nil)
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

    /// Send one batch (at most `maxBatchBytes`). A no-op while a send is in
    /// flight: the 5 s timer or the next size trigger picks the queue up.
    func flush() {
        request(drain: false, late: false, completion: nil)
    }

    /// Send EVERY queued batch, one at a time, until the queue is empty, a send
    /// fails (that batch goes back to the front of the queue), or
    /// `maxDrainRounds` is hit. `flush()` sends a single batch, which on
    /// backgrounding left the rest of the queue for a later timer tick the
    /// suspended app never reached. `completion` runs once the drain settles.
    func drain(completion: (() -> Void)? = nil) {
        request(drain: true, late: false, completion: completion)
    }

    private func request(drain: Bool, late: Bool, completion: (() -> Void)?) {
        lock.lock()
        if drain { roundsLeft = maxDrainRounds }
        if late { lateRequested = true }
        if let completion { sendWaiters.append(completion) }
        if sending {
            // The send in flight continues into the wider request.
            lock.unlock()
            return
        }
        sending = true
        if !drain { roundsLeft = 1 }
        lock.unlock()
        sendNext()
    }

    private func sendNext() {
        lock.lock()
        guard roundsLeft > 0, !waiting.isEmpty else {
            finishSendingLocked()
            return
        }
        roundsLeft -= 1
        var batch: [Data] = []
        var size = 0
        // Always take at least one message: one larger than the cap would
        // otherwise never leave the head of the queue, and every send would be
        // an empty batch.
        while let first = waiting.first, batch.isEmpty || size + first.count <= maxBatchBytes {
            batch.append(first); waiting.removeFirst(); size += first.count
        }
        let late = lateRequested && waiting.isEmpty
        let startIndex = nextIndex
        nextIndex += UInt64(batch.count)
        lock.unlock()

        var content = MobileWire.batchMeta(firstIndex: startIndex, timestamp: nowMs())
        for m in batch { content.append(m) }

        if late {
            // Fire-and-forget, as before: the session is over.
            transport.sendLateMessages(content) { _ in
                self.lock.lock()
                self.finishSendingLocked()
            }
            return
        }
        guard let gz = MobileGzip.compress(content) else {
            sendNext()
            return
        }
        transport.sendMessages(gz) { success in
            if success {
                self.sendNext()
                return
            }
            // Re-queue on failure (front of line, preserve order) and stop.
            self.lock.lock()
            self.waiting.insert(contentsOf: batch, at: 0)
            self.finishSendingLocked()
        }
    }

    /// Ends the send loop and runs its waiters. Call with `lock` held;
    /// releases it.
    private func finishSendingLocked() {
        let waiters = sendWaiters
        sendWaiters.removeAll()
        sending = false
        roundsLeft = 0
        lateRequested = false
        lock.unlock()
        waiters.forEach { $0() }
    }

    /// Messages waiting to send. For tests.
    var waitingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return waiting.count
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
