import SwiftUI

/// The island's silhouette: concave shoulders that melt into the top edge of
/// the display, straight sides, rounded bottom.
///
/// The rect includes the shoulders: the top edge runs its full width and the
/// body is inset by `shoulder` on each side. Folded, that puts the shoulders
/// inside the camera's own width, so the island sits in the cutout instead of
/// outlining a rounder one around it.
///
/// Both radii follow the height being drawn rather than being two constants
/// switched at open and close. The outline's width and height move on springs
/// of their own, and corners taken from the height stay true circles at every
/// frame of that, instead of stretching between two settings.
struct NotchShape: Shape {
    /// Widest the shoulders get: reached at about 74 pt of height.
    static let maxShoulder: CGFloat = 14
    /// Roundest the bottom gets: reached at about 82 pt of height.
    static let maxBottomRadius: CGFloat = 28

    static func shoulder(forHeight height: CGFloat) -> CGFloat {
        min(maxShoulder, 0.19 * height)
    }

    static func bottomRadius(forHeight height: CGFloat) -> CGFloat {
        min(maxBottomRadius, 0.34 * height)
    }

    /// Handle length of a cubic Bézier that traces a quarter circle.
    private static let kappa: CGFloat = 0.552_284_75

    func path(in rect: CGRect) -> Path {
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let tr = max(0, min(Self.shoulder(forHeight: rect.height), rect.width / 2))
        let br = max(0, min(Self.bottomRadius(forHeight: rect.height), rect.height / 2, (rect.width - 2 * tr) / 2))
        let left = rect.minX + tr
        let right = rect.maxX - tr
        let k = Self.kappa

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        // Right shoulder, concave: from the top edge down into the body wall.
        path.addCurve(
            to: CGPoint(x: right, y: rect.minY + tr),
            control1: CGPoint(x: rect.maxX - k * tr, y: rect.minY),
            control2: CGPoint(x: right, y: rect.minY + tr - k * tr)
        )
        path.addLine(to: CGPoint(x: right, y: rect.maxY - br))
        path.addCurve(
            to: CGPoint(x: right - br, y: rect.maxY),
            control1: CGPoint(x: right, y: rect.maxY - br + k * br),
            control2: CGPoint(x: right - br + k * br, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: left + br, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: left, y: rect.maxY - br),
            control1: CGPoint(x: left + br - k * br, y: rect.maxY),
            control2: CGPoint(x: left, y: rect.maxY - br + k * br)
        )
        path.addLine(to: CGPoint(x: left, y: rect.minY + tr))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control1: CGPoint(x: left, y: rect.minY + tr - k * tr),
            control2: CGPoint(x: rect.minX + k * tr, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}
