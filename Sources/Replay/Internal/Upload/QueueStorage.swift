import Foundation

/// On-disk queue of failed/pending batches. Each file is one
/// pre-serialized JSON body ready to POST to /v1/replay/batch.
///
/// Lives under `Library/Application Support/replay-queue/`. Files
/// are named `<seq>-<sessionId>.json` so the drain pass can:
///   • drain in seq order (preserves session reconstruction sequence)
///   • identify which session a queued batch belongs to without
///     parsing the body
///
/// Capacity-bounded: when there are more than maxFiles queued, the
/// OLDEST get dropped. Better to lose the cold tail of an old
/// session than fill the user's disk.
///
/// All file IO is synchronous — designed for callers already on a
/// background queue. No async/await here keeps the surface small.
///
/// Mirrors Android's `QueueStorage.kt` exactly.
final class QueueStorage {

    private let dir: URL
    private var perProcessSeq: Int = Int(Date().timeIntervalSince1970 * 1000)
    private let seqLock = NSLock()

    /// Cap on queued files. 500 × ~50 KB ≈ 25 MB worst-case — keeps
    /// disk pressure bounded for a long offline streak.
    private let maxFiles = 500

    init() {
        // Application Support is the right home for SDK-internal
        // state that the user doesn't manage directly (not in
        // Documents — that shows up in iCloud + iTunes file
        // sharing). Falls back to caches if Application Support
        // isn't writable (rare on iOS).
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? (try? fm.url(for: .cachesDirectory,
                            in: .userDomainMask,
                            appropriateFor: nil,
                            create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.dir = base.appendingPathComponent("replay-queue", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Persist a serialized batch. `json` is the exact body
    /// BatchSender would have POSTed.
    ///
    /// Returns true on successful disk write; false on IO error
    /// (disk full, permission denied). Callers should NOT retry —
    /// failed enqueue means the batch is lost. Acceptable; we're
    /// not blocking the foreground path on retry loops.
    @discardableResult
    func enqueue(sessionId: String, json: Data) -> Bool {
        evictOldestIfFull()
        let seq = nextSeq()
        // Sanitize sessionId so the filename can't path-traverse
        // even with a malicious server-issued id.
        let safeSession = String(sessionId.prefix(40))
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
        let url = dir.appendingPathComponent("\(seq)-\(safeSession).json")
        let tmp = dir.appendingPathComponent("\(url.lastPathComponent).tmp")
        do {
            // Atomic write: write to .tmp first, rename to final.
            // A process kill mid-write can't leave a corrupt file
            // the drain pass would later try (and fail) to POST.
            try json.write(to: tmp, options: .atomic)
            try FileManager.default.moveItem(at: tmp, to: url)
            return true
        } catch {
            ReplayLog.warn("queue enqueue failed: \(error.localizedDescription)")
            return false
        }
    }

    /// List queued files oldest-first. Drain iterates this list,
    /// POSTs each, deletes on success.
    func listOldestFirst() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Delete a queued file after successful upload.
    @discardableResult
    func delete(_ url: URL) -> Bool {
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    var size: Int {
        listOldestFirst().count
    }

    /// Wipe everything. Used on opt-out / GDPR-forget.
    func clear() {
        for url in listOldestFirst() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func nextSeq() -> Int {
        seqLock.withLock {
            perProcessSeq += 1
            return perProcessSeq
        }
    }

    /// If we're at capacity, delete the oldest file to make room.
    /// O(n) sort; common case is "well under cap, never triggers".
    private func evictOldestIfFull() {
        let files = listOldestFirst()
        guard files.count >= maxFiles else { return }
        if let oldest = files.first {
            try? FileManager.default.removeItem(at: oldest)
        }
    }
}
