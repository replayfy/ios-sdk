import Foundation

extension Data {
    /// uint64 little-endian, matching the frames archive header.
    mutating func appendUInt64LE(_ v: UInt64) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    /// uint32 little-endian.
    mutating func appendUInt32LE(_ v: UInt32) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

/// Packs JPEG screenshots into the frames-archive format the backend
/// appends per session: a flat concatenation of
///   [uint64 LE timestamp][uint32 LE size][jpeg bytes]
/// gzip-compressed. One archive per upload batch.
enum MobileFrames {
    /// `frames` is an ordered list of (jpegData, epochMs). Returns the
    /// gzipped archive ready to POST to /v1/mobile/images, or nil when
    /// empty / compression fails.
    static func archive(_ frames: [(data: Data, ts: UInt64)]) -> Data? {
        if frames.isEmpty { return nil }
        var binary = Data()
        for (jpeg, ts) in frames {
            binary.appendUInt64LE(ts)
            binary.appendUInt32LE(UInt32(jpeg.count))
            binary.append(jpeg)
        }
        return MobileGzip.compress(binary)
    }
}
