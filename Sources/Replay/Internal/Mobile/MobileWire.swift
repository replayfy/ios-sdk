import Foundation

/// Binary wire encoder for the mobile message protocol.
///
/// Encoding (must match the backend decoder byte-for-byte):
///   - uint   → LEB128 varint (low 7 bits per byte, MSB = continuation)
///   - int    → zigzag, then varint
///   - string → varint(utf8 byte length) followed by the UTF-8 bytes
///   - bool   → single byte (1 = true)
///
/// Each message on the wire is:
///   [varint type][varint timestamp][varint length][fields…]
/// where `length` is the byte size of the encoded fields body.
enum MobileMsgType: UInt64 {
    case metadata = 92
    case event = 93
    case userID = 94
    case userAnonymousID = 95
    case screenChanges = 96
    case crash = 97
    case viewComponent = 98
    case click = 100
    case input = 101
    case performance = 102
    case log = 103
    case internalError = 104
    case networkCall = 105
    case swipe = 106
    case batchMeta = 107
    case graphQL = 109
}

extension Data {
    mutating func writeUInt(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            append(UInt8((v & 0x7f)) | 0x80)
            v >>= 7
        }
        append(UInt8(v))
    }

    mutating func writeInt(_ value: Int64) {
        let uv = (UInt64(bitPattern: value) << 1) ^ UInt64(bitPattern: value >> 63)
        writeUInt(uv)
    }

    mutating func writeString(_ s: String) {
        let bytes = Data(s.utf8)
        writeUInt(UInt64(bytes.count))
        append(bytes)
    }

    mutating func writeBool(_ b: Bool) {
        append(b ? 1 : 0)
    }
}

/// Builds one complete framed message from a type, timestamp, and an
/// already-encoded fields body.
enum MobileWire {
    static func message(_ type: MobileMsgType, timestamp: UInt64, body: Data) -> Data {
        var out = Data()
        out.writeUInt(type.rawValue)
        out.writeUInt(timestamp)
        out.writeUInt(UInt64(body.count))
        out.append(body)
        return out
    }

    // ── Per-type encoders ────────────────────────────────────────────
    static func batchMeta(firstIndex: UInt64, timestamp: UInt64) -> Data {
        var b = Data(); b.writeUInt(firstIndex)
        return message(.batchMeta, timestamp: timestamp, body: b)
    }

    static func click(label: String, x: UInt64, y: UInt64, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(label); b.writeUInt(x); b.writeUInt(y)
        return message(.click, timestamp: timestamp, body: b)
    }

    static func swipe(label: String, x: UInt64, y: UInt64, direction: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(label); b.writeUInt(x); b.writeUInt(y); b.writeString(direction)
        return message(.swipe, timestamp: timestamp, body: b)
    }

    static func input(value: String, masked: Bool, label: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(value); b.writeBool(masked); b.writeString(label)
        return message(.input, timestamp: timestamp, body: b)
    }

    static func performance(name: String, value: UInt64, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(name); b.writeUInt(value)
        return message(.performance, timestamp: timestamp, body: b)
    }

    static func log(severity: String, content: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(severity); b.writeString(content)
        return message(.log, timestamp: timestamp, body: b)
    }

    static func networkCall(type: String, method: String, url: String, request: String, response: String, status: UInt64, duration: UInt64, timestamp: UInt64) -> Data {
        var b = Data()
        b.writeString(type); b.writeString(method); b.writeString(url)
        b.writeString(request); b.writeString(response); b.writeUInt(status); b.writeUInt(duration)
        return message(.networkCall, timestamp: timestamp, body: b)
    }

    static func crash(name: String, reason: String, stacktrace: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(name); b.writeString(reason); b.writeString(stacktrace)
        return message(.crash, timestamp: timestamp, body: b)
    }

    static func viewComponent(screenName: String, viewName: String, visible: Bool, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(screenName); b.writeString(viewName); b.writeBool(visible)
        return message(.viewComponent, timestamp: timestamp, body: b)
    }

    static func screenChanges(x: UInt64, y: UInt64, width: UInt64, height: UInt64, timestamp: UInt64) -> Data {
        var b = Data(); b.writeUInt(x); b.writeUInt(y); b.writeUInt(width); b.writeUInt(height)
        return message(.screenChanges, timestamp: timestamp, body: b)
    }

    static func event(name: String, payload: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(name); b.writeString(payload)
        return message(.event, timestamp: timestamp, body: b)
    }

    static func metadata(key: String, value: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(key); b.writeString(value)
        return message(.metadata, timestamp: timestamp, body: b)
    }

    static func userID(_ id: String, timestamp: UInt64) -> Data {
        var b = Data(); b.writeString(id)
        return message(.userID, timestamp: timestamp, body: b)
    }
}
