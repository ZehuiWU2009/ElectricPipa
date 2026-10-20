import SwiftUI

/// Coordinates measured on the 978 × 1609 transparent instrument asset.
/// Drawing and hit testing both use the same aspect-fit rectangle. These are
/// visual landmarks, independent of the equal-tempered audio pitch table.
enum PipaGeometry {
    static let stringCount = 4
    static let positionCount = PipaTuning.positionCount
    static let referenceSize = CGSize(width: 978, height: 1609)
    static let stopRows: [CGFloat] = [
        280, 350, 410, 470, 524, 576, 627,
        670, 710, 750, 786, 821, 854, 885, 913, 940, 969,
        995, 1020, 1042, 1065, 1085, 1104, 1123, 1142,
        1159, 1175, 1190, 1205, 1218, 1232, 1246
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
    static func nutY(in rect: CGRect) -> CGFloat { point(x: 0, y: 280, in: rect).y }
    static func bridgeY(in rect: CGRect) -> CGFloat { point(x: 0, y: 1453, in: rect).y }
    static func positionY(_ position: Int, in rect: CGRect) -> CGFloat {
        point(x: 0, y: stopRows[min(max(position, 0), stopRows.count - 1)], in: rect).y
    }
    static func stringX(_ string: Int, atY y: CGFloat, in rect: CGRect) -> CGFloat {
        let t = min(max((y - nutY(in: rect)) / (bridgeY(in: rect) - nutY(in: rect)), 0), 1)
        let nutX = CGFloat(470 + string * 13)
        let bridgeX = CGFloat(445 + string * 30)
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
