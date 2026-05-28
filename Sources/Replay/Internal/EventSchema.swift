import Foundation

/// Swift mirrors of the backend's `@replay/replay-schema` types.
/// Hand-maintained rather than codegen'd — the SDK surface is small
/// enough that codegen tax > maintenance burden. When the schema
/// package changes, this file gets updated in the same PR.
///
/// JSON keys are camelCase to match the backend's NestJS deserializer.
/// `Codable` conformance gives us JSONEncoder serialization for free.

enum Platform {
    static let ios = "ios"
}

/// Top-level batch envelope POST'd to `/v1/replay/batch`.
struct ReplayBatchEnvelope: Encodable {
    let sessionId: String
    let segmentId: String
    let sequence: Int
    let sentAt: Int64
    let sdk: ReplaySdkDescriptor
    let page: ReplayPageContext
    let events: [ReplayEvent]
    let projectId: String?
}

struct ReplaySdkDescriptor: Encodable {
    let name: String
    let version: String
    let platform: String
}

/// "Page" is a misnomer on native — we reuse the field name for
/// parity with the web envelope so the backend doesn't have to fork
/// its deserializer. `url` is a `replay://app/{bundleId}` deep-link;
/// `userAgent` is built from device + OS + SDK info.
struct ReplayPageContext: Encodable {
    let url: String
    let userAgent: String
    let viewport: ViewportDimensions
    let title: String?
    let referrer: String?
    let timezone: String?
    let language: String?
}

struct ViewportDimensions: Encodable {
    let width: Int
    let height: Int
}

/// One event on the timeline. `data` is polymorphic — encoded as
/// whatever shape the specific event type carries (session_start,
/// custom, tap, native_snapshot, performance, etc.).
///
/// We use `AnyEncodable` to hold the payload because Swift's
/// strictly-typed Codable can't directly express "JSON-of-arbitrary-
/// shape". The wrapper does the dispatch at encode time.
struct ReplayEvent: Encodable {
    let id: String
    let ts: Int64
    let offsetMs: Int64
    let type: String
    let source: String
    let data: AnyEncodable

    init<T: Encodable>(
        id: String,
        ts: Int64,
        offsetMs: Int64,
        type: String,
        source: String,
        data: T
    ) {
        self.id = id
        self.ts = ts
        self.offsetMs = offsetMs
        self.type = type
        self.source = source
        self.data = AnyEncodable(data)
    }
}

// MARK: - Event data shapes

struct SessionStartEventData: Encodable {
    let href: String
    let path: String
    let referrer: String
}

struct SessionEndEventData: Encodable {
    /// "manual" | "background" | "process_kill"
    let reason: String
}

/// Custom event from `Replay.track`. `kind: "track"` so the backend's
/// existing classifier (web SDK does the same) buckets it correctly.
struct CustomEventData: Encodable {
    let kind: String
    let name: String
    let properties: [String: AnyEncodable]?
}

/// Identify payload — shipped out-of-band on the batch root, not as
/// a timeline event. Matches the web SDK's setIdentify pattern.
struct IdentifyPayload: Encodable {
    let distinctId: String
    let email: String?
    let name: String?
    let plan: String?
    let customProps: [String: AnyEncodable]?
}

/// Full request body to `/v1/replay/batch`.
struct IngestRequest: Encodable {
    let envelope: ReplayBatchEnvelope
    let identify: IdentifyPayload?
    let fingerprint: String?
}

// MARK: - Type-erased Encodable

/// Type-erased Encodable wrapper. Lets us put heterogeneous values
/// (Int, String, Bool, [Any], [String: Any], nested data classes)
/// behind a single Codable surface for JSONEncoder.
///
/// At encode time we walk the runtime type and pick the right
/// encoding. JSON arrays + dictionaries recurse; primitives encode
/// directly; anything else falls through to `String(describing:)`
/// so we never crash on a customer's exotic property value.
struct AnyEncodable: Encodable {
    let value: Any

    init(_ value: Any?) {
        self.value = value ?? NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let v as Bool:
            try container.encode(v)
        case let v as Int:
            try container.encode(v)
        case let v as Int64:
            try container.encode(v)
        case let v as Double:
            try container.encode(v)
        case let v as Float:
            try container.encode(v)
        case let v as String:
            try container.encode(v)
        case let v as [Any?]:
            try container.encode(v.map { AnyEncodable($0) })
        case let v as [String: Any?]:
            try container.encode(v.mapValues { AnyEncodable($0) })
        case let v as Encodable:
            // Re-encode via a wrapping container so the existing
            // Encoder's keyed/unkeyed state is preserved.
            try v.encode(to: encoder)
        default:
            // Last-ditch — never crash on a weird value (e.g. UIColor,
            // CGRect from a customer's track properties).
            try container.encode(String(describing: value))
        }
    }
}
