import Foundation
import Compression

/// POSTs envelopes to `/v1/replay/batch` via URLSession.
///
/// Uses URLSession's async `data(for:)` API (iOS 15+). Synchronous
/// wrapper for the queue worker — they fire from background tasks
/// and don't have a structured-concurrency context.
///
/// Errors are best-effort logged via `os_log`. The persistent-queue
/// layer (future commit) will catch failed sends and stage them to
/// disk for retry by a background URLSession.
final class BatchSender {

    private let config: ReplayConfig
    private let session: URLSession

    /// Currently-known identity, attached to every outgoing batch.
    /// Lock around mutation so identify() can change it while a
    /// flush is mid-flight without tearing.
    private var _identity: IdentifyPayload?
    private let identityLock = NSLock()

    var identity: IdentifyPayload? {
        get { identityLock.withLock { _identity } }
        set { identityLock.withLock { _identity = newValue } }
    }

    init(config: ReplayConfig) {
        self.config = config
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        cfg.waitsForConnectivity = false
        // No HTTP cookies — replay batches are stateless POSTs.
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        self.session = URLSession(configuration: cfg)
    }

    /// Send the envelope. Returns true on HTTP 2xx, false otherwise.
    /// Async — caller awaits on a background Task.
    @discardableResult
    func send(_ envelope: ReplayBatchEnvelope) async -> Bool {
        let body: Data
        do {
            body = try serialize(envelope: envelope, identity: identity)
        } catch {
            ReplayLog.warn("serialize failed: \(error)")
            return false
        }
        return await sendJson(body, sdkName: envelope.sdk.name, sdkVersion: envelope.sdk.version)
    }

    /// Send a pre-serialized JSON body. Used by the on-disk queue
    /// worker that drains persisted batches without re-serializing.
    @discardableResult
    func sendJson(_ body: Data, sdkName: String, sdkVersion: String) async -> Bool {
        var request = URLRequest(url: makeUrl())
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(config.apiKey, forHTTPHeaderField: "x-replay-api-key")
        request.setValue("\(sdkName)/\(sdkVersion)", forHTTPHeaderField: "User-Agent")

        // gzip the body before sending. Typical event-mix batches
        // compress 5-10× — saves cellular bandwidth + reduces ingest
        // billable bytes. Express's `json()` middleware on the
        // backend auto-inflates when Content-Encoding: gzip is set
        // (inflate:true default), so zero backend change needed.
        // UXCam bundles minizip for the same purpose.
        //
        // Sub-256-byte bodies skip compression — gzip's 18-byte
        // header + trailer would inflate very small payloads.
        if body.count >= Self.gzipThresholdBytes,
           let compressed = gzip(body)
        {
            request.httpBody = compressed
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        } else {
            request.httpBody = body
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            ReplayLog.verbose("batch send failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Public for the queue layer — serialize without sending so the
    /// queue can persist the body before attempting the live POST.
    /// Identity captured at serialize-time, frozen in the bytes.
    func serialize(envelope: ReplayBatchEnvelope, identity: IdentifyPayload?) throws -> Data {
        let body = IngestRequest(
            envelope: envelope,
            identify: identity,
            fingerprint: nil
        )
        let encoder = JSONEncoder()
        // Match the web SDK's wire format — no pretty-printing in
        // production batches, ms timestamps as integers (the default
        // for Int64 fields).
        encoder.outputFormatting = []
        return try encoder.encode(body)
    }

    private func makeUrl() -> URL {
        let host = config.apiHost.trimmingCharacters(in: ["/"])
        // swiftlint:disable:next force_unwrapping
        return URL(string: "\(host)/v1/replay/batch")!
    }

    /// Below this size, gzip's 18-byte overhead (10-byte header +
    /// 8-byte trailer) outweighs the compression win — send raw.
    /// Most session_start-only batches still exceed this.
    fileprivate static let gzipThresholdBytes = 256

    /// gzip-encode `body` via the system Compression.framework
    /// (built into iOS 9+). Returns nil if compression fails — the
    /// caller falls through to sending raw bytes in that case so
    /// uploads never break because of a compressor hiccup.
    ///
    /// Compression.framework's COMPRESSION_ZLIB algorithm emits a
    /// raw deflate stream, NOT a gzip-framed stream. We wrap it
    /// manually with the 10-byte gzip header + 8-byte trailer
    /// (CRC32 + ISIZE) per RFC 1952. Same approach SwiftNIO's
    /// `extras-http1` uses; Apple's `NSData(compressed:)`
    /// equivalent doesn't add the gzip framing either.
    private func gzip(_ body: Data) -> Data? {
        // Allocate a destination scratch buffer sized to the input —
        // deflate output is always smaller for non-pathological JSON.
        // If a pathological case ever overflows, compression_encode
        // returns 0 and we fall through.
        let destSize = max(64, body.count)
        var dest = [UInt8](repeating: 0, count: destSize)
        // Capture sizes BEFORE entering withUnsafe* closures so we
        // don't trigger an exclusivity violation by reading
        // `dest.count` inside the same scope that holds the
        // mutable-buffer access. `srcSize` is similarly captured.
        let srcSize = body.count
        let written = body.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dest.withUnsafeMutableBufferPointer { destPtr in
                guard let destBase = destPtr.baseAddress else { return 0 }
                return compression_encode_buffer(
                    destBase, destSize,
                    srcPtr, srcSize,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }

        // Build the gzip-framed output: 10-byte header + raw deflate
        // bytes + CRC32 (LE) + ISIZE (LE, mod 2^32). Total overhead
        // is 18 bytes — accounted for in our gzipThresholdBytes
        // floor.
        var out = Data(capacity: 18 + written)
        // gzip header per RFC 1952 §2.3
        out.append(contentsOf: [
            0x1f, 0x8b,           // magic
            0x08,                 // CM=deflate
            0x00,                 // FLG=0 (no extras)
            0x00, 0x00, 0x00, 0x00, // MTIME=0
            0x00,                 // XFL=0
            0xff,                 // OS=255 (unknown)
        ])
        out.append(contentsOf: dest.prefix(written))
        // CRC32 (little-endian) of the ORIGINAL uncompressed bytes.
        let crc = crc32(body)
        out.append(UInt8(crc & 0xff))
        out.append(UInt8((crc >> 8) & 0xff))
        out.append(UInt8((crc >> 16) & 0xff))
        out.append(UInt8((crc >> 24) & 0xff))
        // ISIZE = original size mod 2^32, little-endian.
        let isize = UInt32(body.count & 0xffff_ffff)
        out.append(UInt8(isize & 0xff))
        out.append(UInt8((isize >> 8) & 0xff))
        out.append(UInt8((isize >> 16) & 0xff))
        out.append(UInt8((isize >> 24) & 0xff))
        return out
    }

    /// Standard CRC32 (IEEE 802.3 polynomial 0xEDB88320). We need
    /// our own because Foundation doesn't expose one — zlib has
    /// `crc32()` but linking it pulls in a transitive dep when
    /// Compression.framework is enough for everything else.
    /// Table-driven implementation; ~32 ns per byte on A-series CPUs.
    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xedb88320 & (UInt32(0) &- (crc & 1)))
            }
        }
        return crc ^ 0xffff_ffff
    }
}

// MARK: - Logging helper

/// Centralised logging. Routes through `os_log` so the host app's
/// console + Console.app both see the SDK's messages. Verbose is
/// off by default; flip via `Replay.setVerboseLogging(true)` (future).
enum ReplayLog {
    static func verbose(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[Replay] \(message())")
        #endif
    }

    static func warn(_ message: @autoclosure () -> String) {
        print("[Replay] ⚠️ \(message())")
    }

    static func info(_ message: @autoclosure () -> String) {
        print("[Replay] \(message())")
    }
}

// MARK: - NSLock convenience

extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
