import Foundation
import Compression

/// gzip (RFC 1952) encoder for the mobile engine.
///
/// Compression.framework's `COMPRESSION_ZLIB` emits raw DEFLATE; we
/// wrap it in the 10-byte gzip header + CRC32 + ISIZE trailer so the
/// backend's `gunzip` (which requires the `1f 8b` magic) accepts it.
enum MobileGzip {
    static func compress(_ body: Data) -> Data? {
        if body.isEmpty { return nil }
        let destSize = max(64, body.count + 64)
        var dest = [UInt8](repeating: 0, count: destSize)
        let srcSize = body.count
        let written = body.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Int in
            guard let srcPtr = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dest.withUnsafeMutableBufferPointer { destPtr in
                guard let destBase = destPtr.baseAddress else { return 0 }
                return compression_encode_buffer(destBase, destSize, srcPtr, srcSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }

        var out = Data(capacity: 18 + written)
        out.append(contentsOf: [
            0x1f, 0x8b, // magic
            0x08,       // CM = deflate
            0x00,       // FLG
            0x00, 0x00, 0x00, 0x00, // MTIME
            0x00,       // XFL
            0xff,       // OS = unknown
        ])
        out.append(contentsOf: dest.prefix(written))
        let crc = crc32(body)
        out.append(UInt8(crc & 0xff))
        out.append(UInt8((crc >> 8) & 0xff))
        out.append(UInt8((crc >> 16) & 0xff))
        out.append(UInt8((crc >> 24) & 0xff))
        let isize = UInt32(body.count & 0xffff_ffff)
        out.append(UInt8(isize & 0xff))
        out.append(UInt8((isize >> 8) & 0xff))
        out.append(UInt8((isize >> 16) & 0xff))
        out.append(UInt8((isize >> 24) & 0xff))
        return out
    }

    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
        return crc ^ 0xffff_ffff
    }
}
