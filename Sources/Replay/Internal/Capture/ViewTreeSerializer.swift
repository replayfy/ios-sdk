import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Walks a UIView hierarchy and produces the platform-neutral
/// ``NativeViewNode`` tree the dashboard player renders.
///
/// Lean output — every byte multiplied by tree size. Optimizations:
///   • Skip hidden / zero-alpha / zero-size nodes entirely
///   • Skip nodes outside the screen (off-screen UITableViewCells,
///     recycled UICollectionView cells, etc.)
///   • Omit `opacity` when 1.0, `backgroundColor` when transparent,
///     `children` when empty (handled by Encodable's nil-skip)
///   • Truncate text at 280 chars (same Twitter rule as the
///     ValueExtractor)
///
/// Image bytes are NOT captured here. Image nodes carry `imageRef
/// = nil` for now; the bitmap-capture follow-up commit populates
/// imageRef with the SHA-256 hash from the asset upload pipeline.
///
/// Mirrors the Android `ViewTreeSerializer.kt` so the dashboard
/// renderer treats output from both platforms identically.
enum ViewTreeSerializer {

    #if canImport(UIKit)
    /// Serialize the root view. Returns nil when the view isn't
    /// suitable (hidden, no size).
    static func serialize(_ root: UIView) -> NativeViewNode? {
        let scale = root.window?.screen.scale ?? UIScreen.main.scale
        let screenSize = root.window?.bounds.size ?? UIScreen.main.bounds.size
        return walk(root, idPath: "0", scale: scale, screenSize: screenSize)
    }

    /// Depth-first walk. `idPath` is the sibling-index path so taps
    /// can later resolve to nodes by id. `scale` is the screen's
    /// pixel ratio — bounds get multiplied by it so the wire JSON is
    /// in device pixels (matches Android, matches TapEventData).
    private static func walk(
        _ view: UIView,
        idPath: String,
        scale: CGFloat,
        screenSize: CGSize
    ) -> NativeViewNode? {
        if view.isHidden { return nil }
        if view.alpha < 0.01 { return nil }
        if view.bounds.width <= 0 || view.bounds.height <= 0 { return nil }

        // Compute absolute (window) bounds. Skip nodes entirely
        // outside the screen — common with off-screen list cells.
        let frameInWindow = view.convert(view.bounds, to: nil)
        if !frameInWindow.intersects(CGRect(origin: .zero, size: screenSize)) {
            return nil
        }

        let bounds = NativeNodeBounds(
            x: Int(frameInWindow.minX * scale),
            y: Int(frameInWindow.minY * scale),
            w: Int(frameInWindow.width * scale),
            h: Int(frameInWindow.height * scale),
        )

        let type = WidgetClassifier.classify(view)

        // Privacy check: if THIS view or any ancestor is in the
        // PrivacyRegistry, blank all human-readable content. We
        // still ship bounds + type + children so the player can
        // render the silhouette + privacy overlay correctly.
        // Combined check — same rationale as TapTracker. UIKit
        // marker → ancestor walk hit. SwiftUI marker → bounds-
        // intersection with the marker's screen frame.
        let occluded = PrivacyRegistry.shared.isSensitiveCombined(view)

        // Text content reuses the tap tracker's extractor so a tap on
        // a node and the node's snapshot entry carry the exact same
        // uiValue. Field placeholders extracted, contents never.
        // Occluded views ship without text — player paints a noise
        // pattern over them.
        let text: String? = {
            if occluded { return nil }
            if type == .text || type == .button || type == .field {
                let v = ValueExtractor.extract(view, type: type)
                return v.isEmpty ? nil : v
            }
            return nil
        }()

        let bgColor = extractBackgroundColor(view)
        let opacity: Double? = view.alpha < 1.0 ? Double(view.alpha) : nil

        let ariaLabel: String? = {
            if occluded { return nil }
            guard let label = view.accessibilityLabel, !label.isEmpty else { return nil }
            // Don't double-ship: if accessibilityLabel == text, the
            // dashboard already has it.
            if let text, label == text { return nil }
            return label
        }()

        // Recurse into subviews. UIView.subviews is back-to-front
        // render order — same as the wire format expects.
        let children: [NativeViewNode]? = {
            if view.subviews.isEmpty { return nil }
            var out: [NativeViewNode] = []
            out.reserveCapacity(view.subviews.count)
            for (i, child) in view.subviews.enumerated() {
                if let node = walk(child, idPath: "\(idPath)/\(i)", scale: scale, screenSize: screenSize) {
                    out.append(node)
                }
            }
            return out.isEmpty ? nil : out
        }()

        let className = NSStringFromClass(Swift.type(of: view))
            .components(separatedBy: ".").last ?? "View"

        return NativeViewNode(
            id: idPath,
            type: type.rawValue,
            className: className,
            bounds: bounds,
            text: text,
            imageRef: nil, // populated in the bitmap-capture follow-up
            backgroundColor: bgColor,
            opacity: opacity,
            // Ship `true` only when this view is itself sensitive
            // (the dashboard inherits occluded down the subtree
            // automatically via a parent's `occluded:true` mark).
            // Omitted when false to save bytes.
            occluded: occluded ? true : nil,
            ariaLabel: ariaLabel,
            children: children
        )
    }

    /// Extract a solid backgroundColor as ARGB hex if present.
    /// UIView.backgroundColor may be `UIColor.clear` (transparent —
    /// nothing to ship) or a dynamic color (resolves at render time
    /// to either light/dark variant); we resolve in the current
    /// trait collection for stable output.
    private static func extractBackgroundColor(_ view: UIView) -> String? {
        guard let color = view.backgroundColor else { return nil }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let resolved = color.resolvedColor(with: view.traitCollection)
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return nil
        }
        // Skip fully-transparent fills — nothing to render, saves bytes.
        if a == 0 { return nil }
        let ai = Int((a * 255).rounded()).clamped(0, 255)
        let ri = Int((r * 255).rounded()).clamped(0, 255)
        let gi = Int((g * 255).rounded()).clamped(0, 255)
        let bi = Int((b * 255).rounded()).clamped(0, 255)
        // ARGB hex (alpha first) — matches CSS rgba() ordering the
        // dashboard player uses.
        return String(format: "#%02x%02x%02x%02x", ai, ri, gi, bi)
    }
    #endif
}

private extension Int {
    func clamped(_ low: Int, _ high: Int) -> Int {
        return Swift.max(low, Swift.min(self, high))
    }
}
