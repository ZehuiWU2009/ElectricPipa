import SwiftUI

/// Coordinates measured on the 506 × 1557 transparent instrument asset.
/// Drawing and hit testing both use the same aspect-fit rectangle. These are
/// visual landmarks, independent of the equal-tempered audio pitch table.
///
/// The asset used to be a 978 × 1609 canvas with wide transparent margins on
/// both sides — the instrument itself only occupied 502 of those 978 pixels.
/// Fitting the whole canvas therefore shrank the instrument to half the width
/// it could have taken. The margins are cropped away now, and every coordinate
/// below is measured on the cropped canvas: old canvas minus the (236, 12)
/// crop origin.
enum PipaGeometry {
    static let stringCount = 4
    static let positionCount = PipaTuning.positionCount
    static let referenceSize = CGSize(width: 506, height: 1557)
    static let stopRows: [CGFloat] = [
        268, 338, 398, 458, 512, 564, 615,
        658, 698, 738, 774, 809, 842, 873, 901, 928, 957,
        983, 1008, 1030, 1053, 1073, 1092, 1111, 1130,
        1147, 1163, 1178, 1193, 1206, 1220, 1234
    ]

    static func instrumentRect(in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / referenceSize.width, bounds.height / referenceSize.height)
        let size = CGSize(width: referenceSize.width * scale, height: referenceSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func point(x: CGFloat, y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x / referenceSize.width * rect.width,
                y: rect.minY + y / referenceSize.height * rect.height)
    }
    static func nutY(in rect: CGRect) -> CGFloat { point(x: 0, y: 268, in: rect).y }
    static func bridgeY(in rect: CGRect) -> CGFloat { point(x: 0, y: 1441, in: rect).y }
    static func positionY(_ position: Int, in rect: CGRect) -> CGFloat {
        point(x: 0, y: stopRows[min(max(position, 0), stopRows.count - 1)], in: rect).y
    }
    static func stringX(_ string: Int, atY y: CGFloat, in rect: CGRect) -> CGFloat {
        let t = min(max((y - nutY(in: rect)) / (bridgeY(in: rect) - nutY(in: rect)), 0), 1)
        let nutX = CGFloat(234 + string * 13)
        let bridgeX = CGFloat(209 + string * 30)
        return point(x: nutX + (bridgeX - nutX) * t, y: 0, in: rect).x
    }
    static func nearest(location: CGPoint, in rect: CGRect) -> (string: Int, fret: Int)? {
        guard rect.width > 0, rect.height > 0,
              location.y >= nutY(in: rect) - 8,
              location.y <= bridgeY(in: rect) + 8 else { return nil }
        let left = stringX(0, atY: location.y, in: rect)
        let right = stringX(3, atY: location.y, in: rect)
        guard location.x >= left - 14, location.x <= right + 14 else { return nil }
        let string = (0..<4).min { abs(stringX($0, atY: location.y, in: rect) - location.x) < abs(stringX($1, atY: location.y, in: rect) - location.x) } ?? 0
        // Below the last fret is the open-string plucking area.
        if location.y > positionY(31, in: rect) + 12 { return (string, 0) }
        let fret = (0..<positionCount).min { abs(positionY($0, in: rect) - location.y) < abs(positionY($1, in: rect) - location.y) } ?? 0
        return (string, fret)
    }
    static func pluckPosition(_ location: CGPoint, in rect: CGRect) -> Double {
        let fraction = (location.y - nutY(in: rect)) / (bridgeY(in: rect) - nutY(in: rect))
        return Double(min(max(fraction, 0.15), 0.95))
    }
}
