import Foundation
import CoreGraphics

/// How a masked (privacy-sensitive) region is rendered in the recording.
///
/// Mirrors the reference mobile SDK's occlusion types:
///
///  - ``overlay``  — the region is painted with a solid color box: no pixel
///                   of the source survives. The default, as in both
///                   reference trackers.
///  - ``blur``     — the underlying pixels are Gaussian-blurred. Hints at the
///                   shape/length of the content without revealing it.
///  - ``pixelate`` — the region is reduced to coarse mosaic blocks. Reads as
///                   "redacted" while preserving rough layout/colour, between
///                   blur and overlay in how much it reveals.
///
/// Set globally with ``Replay/setMaskStyle(_:)`` (applied to `addPrivacyView`,
/// `occludeAllTextFields`, `occludeAllTextView`, `applyOcclusion`, …), or per
/// region where the host supplies it (React Native / Flutter mask widgets,
/// ``Replay/occludeRectsOnNextFrame(_:style:)``). What the SDK masks on its
/// own (secure and password-type fields, password inputs inside web views)
/// and the whole-screen cover are always ``overlay``.
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
