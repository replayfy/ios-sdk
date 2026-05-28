import Foundation

/// djb2 string hash, 32-bit unsigned, hex-encoded.
///
/// Used to compute a stable per-widget id from
/// `route + uiClass + uiValue` so heatmaps + funnels can aggregate
/// taps on the same logical button across millions of sessions
/// without storing the full triple per row.
///
/// Matches the algorithm in the Android SDK + the docs in
/// `replay-web-sdk/docs/native-snapshot-format.md`. Same hash on
/// iOS, Android, web SDK side keeps tap → snapshot-node linking
/// deterministic.
enum UiIdHasher {

    /// Build a stable id: `<route>:<djb2hex>`. Route is the prefix so
    /// the dashboard can group-by-screen without a join. Hash
    /// collapses on `uiClass#uiValue` keyed by route.
    static func uiId(route: String, uiClass: String, uiValue: String) -> String {
        let normalized = uiValue
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        let input = "\(route)#\(uiClass)#\(normalized)"
        return "\(route):\(djb2Hex(input))"
    }

    private static func djb2Hex(_ input: String) -> String {
        // djb2 — Daniel J. Bernstein's hash. Public-domain, fast,
        // low collision rate on short strings, no allocations.
        var hash: UInt64 = 5381
        for scalar in input.unicodeScalars {
            // ((hash << 5) + hash) == hash * 33
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        // Mask to 32-bit unsigned so cross-platform parity is exact —
        // Android + web SDK both use 32-bit. Without the mask, a long
        // input here would diverge.
        return String(hash & 0xFFFFFFFF, radix: 16)
    }
}
