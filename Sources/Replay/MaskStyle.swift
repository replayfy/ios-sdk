import Foundation
import CoreGraphics

/// How a masked (privacy-sensitive) region is rendered in the recording.
///
/// Mirrors the reference mobile SDK's occlusion types. The previous single
/// hard-coded style (blur + diagonal stripes) is replaced by a choice:
///
///  - ``blur``     — the underlying pixels are Gaussian-blurred. Hints at the
///                   shape/length of the content without revealing it. Good
///                   default for a single field.
///  - ``overlay``  — the region is painted with a solid color box. Cleaner on
///                   a screen full of fields (no busy stripe texture), and the
///                   strongest guarantee — no pixel of the source survives.
///  - ``pixelate`` — the region is reduced to coarse mosaic blocks. Reads as
///                   "redacted" while preserving rough layout/colour, between
///                   blur and overlay in how much it reveals.
///
/// Set globally with ``Replay/setMaskStyle(_:)`` (the default applied to
/// `addPrivacyView`, `occludeAllTextFields`, secure fields, …), or per region
/// where the host supplies it (React Native / Flutter mask widgets,
/// ``Replay/occludeRectsOnNextFrame(_:style:)``).
@objc public enum ReplayMaskStyle: Int {
    case blur = 0
    case overlay = 1
    case pixelate = 2
}

/// A sensitive region plus how it should be rendered. Pairs a window-coord
/// rect with its ``ReplayMaskStyle`` as they flow from the privacy sources to
/// the screenshotter. Public so host SDKs (React Native / Flutter plugins,
/// separate modules) can build them for the engine's rect providers.
public struct MaskRect {
    public let rect: CGRect
    public let style: ReplayMaskStyle

    public init(rect: CGRect, style: ReplayMaskStyle) {
        self.rect = rect
        self.style = style
    }
}
