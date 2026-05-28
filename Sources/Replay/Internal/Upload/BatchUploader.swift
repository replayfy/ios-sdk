import Foundation

/// Outbound batch pipeline. Tries the live HTTP path first; on
/// failure, persists the serialized JSON to ``QueueStorage`` so
/// the next foreground (via ``LifecycleObserver``) can drain it.
///
/// iOS has no WorkManager-style background scheduler we can rely
/// on without extra Info.plist permissions, so v1 settles for
/// "drain on every foreground" semantics. Customers in the field
/// almost always re-open their app within hours; the queue catches
/// the rest.
///
/// Mirrors Android's `BatchUploader.kt`.
final class BatchUploader {

    private let config: ReplayConfig
    private let sender: BatchSender
    private let storage: QueueStorage

    init(config: ReplayConfig, sender: BatchSender, storage: QueueStorage = QueueStorage()) {
        self.config = config
        self.sender = sender
        self.storage = storage
    }

    /// Send the envelope. Returns true on live success, false when
    /// we fell back to queueing (or if even queueing failed).
    @discardableResult
    func upload(_ envelope: ReplayBatchEnvelope) async -> Bool {
        let ok = await sender.send(envelope)
        if ok { return true }

        // Live send failed → serialize once + persist.
        let json: Data
        do {
            json = try sender.serialize(envelope: envelope, identity: sender.identity)
        } catch {
            ReplayLog.warn("serialize for queue failed: \(error.localizedDescription)")
            return false
        }
        return storage.enqueue(sessionId: envelope.sessionId, json: json)
    }

    /// Drain the on-disk queue. Called on every foreground via the
    /// lifecycle observer + once at start() to pick up any batches
    /// left over from a previous process lifetime.
    ///
    /// Iterates oldest-first; bails after the FIRST failure in a
    /// run because the next file likely hits the same network
    /// condition. The next foreground will try again.
    func drain() async {
        let files = storage.listOldestFirst()
        guard !files.isEmpty else { return }

        ReplayLog.verbose("draining \(files.count) queued batches")
        for file in files {
            let json: Data
            do {
                json = try Data(contentsOf: file)
            } catch {
                // Corrupt or unreadable file — delete so we don't
                // get stuck retrying. Lost batch is acceptable.
                ReplayLog.warn("queued file unreadable, dropping: \(file.lastPathComponent)")
                storage.delete(file)
                continue
            }
            let ok = await sender.sendJson(
                json,
                sdkName: BuildInfo.sdkName,
                sdkVersion: BuildInfo.sdkVersion
            )
            if ok {
                storage.delete(file)
            } else {
                // Same network condition that killed this one will
                // likely kill the rest — stop and let next
                // foreground retry.
                break
            }
        }
    }

    /// Wipe the on-disk queue. Used on opt-out / GDPR-forget.
    func clearQueue() {
        storage.clear()
    }

    /// Count of currently-queued files — useful for diagnostics
    /// + the future `Replay.pendingUploads` API.
    var queuedCount: Int {
        storage.size
    }
}
