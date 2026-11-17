import Foundation
import CoreGraphics

/// The analytic 3D truth of the instrument.
///
/// The shipped photographic board resolves every touch with 2D pixel
/// constants in PipaGeometry. A rotatable camera makes those constants
/// meaningless: the same stop can land anywhere on screen. This module lifts
/// the same musical layout into instrument space, where it no longer depends
/// on the view at all.
///
/// Coordinates are reference pixels on the 506 x 1557 asset, centred on the
/// middle of the strings:
///
///   u = x - 247, v = -(y - 854.5), w = height above the soundboard
///
/// The four strings and 32 stops are generated from PipaTuning's equal
/// tempered ladder, never reconstructed from pixels. A future 3DGS asset only
/// replaces the renderer; this geometry and the hit test stay as they are.
///
/// Only Foundation and CoreGraphics are used so this file can be typechecked
/// on its own, without SwiftUI macros.

struct Pipa3DPoint {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Pipa3DPoint(x: 0, y: 0, z: 0)

    static func + (a: Pipa3DPoint, b: Pipa3DPoint) -> Pipa3DPoint {
        Pipa3DPoint(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }
    static func * (v: Pipa3DPoint, s: Double) -> Pipa3DPoint {
        Pipa3DPoint(x: v.x * s, y: v.y * s, z: v.z * s)
    }
    func dot(_ o: Pipa3DPoint) -> Double { x * o.x + y * o.y + z * o.z }
}

/// A weak-perspective camera looking at the soundboard. The instrument is
/// rotated while the camera stays fixed, which keeps the ray/plane
/// intersection in a single frame.
struct Pipa3DCamera {
    var yaw: Double = 0
    var pitch: Double = 0
    var zoom: Double = 1
    var panX: Double = 0
    var panY: Double = 0
    /// Reference pixels. A long lens keeps the projection close to the
    /// original flat layout at small angles.
    var distance: Double = 4671
    var centreX: Double = 0
    var centreY: Double = 0
    var scale: Double = 1

    static let maxYaw: Double = 20 * .pi / 180
    static let maxPitch: Double = 14 * .pi / 180
    static let minZoom: Double = 0.85
    static let maxZoom: Double = 1.6

    func rotate(_ l: Pipa3DPoint) -> Pipa3DPoint {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let y1 = l.y * cp - l.z * sp
        let z1 = l.y * sp + l.z * cp
        return Pipa3DPoint(x: l.x * cy + z1 * sy, y: y1, z: -l.x * sy + z1 * cy)
    }

    func unrotate(_ c: Pipa3DPoint) -> Pipa3DPoint {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let x1 = c.x * cy - c.z * sy
        let z1 = c.x * sy + c.z * cy
        return Pipa3DPoint(x: x1, y: c.y * cp + z1 * sp, z: -c.y * sp + z1 * cp)
    }

    /// The rotated soundboard plane passes through the local origin.
    var planeNormal: Pipa3DPoint { rotate(Pipa3DPoint(x: 0, y: 0, z: 1)) }

    func project(_ l: Pipa3DPoint) -> CGPoint {
        let c = rotate(l)
        let depth = distance - c.z
        let factor = distance / max(depth, 1)
        let k = scale * zoom
        return CGPoint(x: centreX + panX + c.x * factor * k,
                       y: centreY + panY - c.y * factor * k)
    }

    /// Cast a ray from a screen point and intersect a plane parallel to the
    /// soundboard at the given height. Returns instrument-local coordinates.
    ///
    /// The strings are drawn at `stringHeight`, so hit testing must use that
    /// same plane. Intersecting the bare soundboard instead introduces a
    /// perspective parallax of about 1.5 reference pixels at the edges.
    func unproject(_ screen: CGPoint, planeZ: Double = 0) -> Pipa3DPoint? {
        let k = scale * zoom
        guard k > 0 else { return nil }
        let r = (Double(screen.x) - centreX - panX) / (k * distance)
        let s = -(Double(screen.y) - centreY - panY) / (k * distance)
        let direction = Pipa3DPoint(x: r, y: s, z: -1)
        let n = planeNormal
        let denominator = n.dot(direction)
        guard abs(denominator) > 1e-12 else { return nil }
        let eye = Pipa3DPoint(x: 0, y: 0, z: distance)
        let planePoint = rotate(Pipa3DPoint(x: 0, y: 0, z: planeZ))
        let t = (n.dot(planePoint) - n.dot(eye)) / denominator
        guard t > 0 else { return nil }
        return unrotate(eye + direction * t)
    }
}

enum Pipa3DGeometry {
    static let referenceWidth: Double = 506
    static let referenceHeight: Double = 1557
    static let nutPixel: Double = 268
    static let bridgePixel: Double = 1441
    static let stringCount = 4
    static let positionCount = 32
    /// Thickness of the body in reference pixels, about 38 mm at real scale.
    static let bodyThickness: Double = 62
    /// Strings and fret bars sit just above the soundboard.
    static let stringHeight: Double = 5
    static let fretHeight: Double = 2

    static let stopRows: [Double] = [
        268, 338, 398, 458, 512, 564, 615,
        658, 698, 738, 774, 809, 842, 873, 901, 928, 957,
        983, 1008, 1030, 1053, 1073, 1092, 1111, 1130,
        1147, 1163, 1178, 1193, 1206, 1220, 1234
    ]

    static var centrePixelY: Double { (nutPixel + bridgePixel) / 2 }

    /// Stops that carry an on-screen note name. Labelling all 32 at once
    /// crowds the high-fret region, so only the octave-ish landmarks are
    /// shown, plus the current selection in the view layer.
    static let labelledStops: [Int] = [0, 6, 12, 18, 24, 30]

    /// The same aspect-fit rectangle as the photographic board.
    static func instrumentRect(in bounds: CGRect) -> CGRect {
        let scale = min(Double(bounds.width) / referenceWidth,
                        Double(bounds.height) / referenceHeight)
        let w = referenceWidth * scale
        let h = referenceHeight * scale
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2,
                      width: w, height: h)
    }

    static func camera(for rect: CGRect, yaw: Double = 0, pitch: Double = 0,
                       zoom: Double = 1, panX: Double = 0,
                       panY: Double = 0) -> Pipa3DCamera {
        Pipa3DCamera(
            yaw: yaw, pitch: pitch, zoom: zoom, panX: panX, panY: panY,
            centreX: Double(rect.minX) + 247 / referenceWidth * Double(rect.width),
            centreY: Double(rect.minY) + centrePixelY / referenceHeight
                * Double(rect.height),
            scale: Double(rect.height) / referenceHeight)
    }

    static func local(xPixel: Double, yPixel: Double,
                      z: Double = 0) -> Pipa3DPoint {
        Pipa3DPoint(x: xPixel - 247,
                    y: -(yPixel - centrePixelY),
                    z: z)
    }

    static func pixel(_ l: Pipa3DPoint) -> (x: Double, y: Double) {
        (247 + l.x, centrePixelY - l.y)
    }

    static func stringPixelX(_ string: Int, atY y: Double) -> Double {
        let t = min(max((y - nutPixel) / (bridgePixel - nutPixel), 0), 1)
        let nutX = 234 + Double(string) * 13
        let bridgeX = 209 + Double(string) * 30
        return nutX + (bridgeX - nutX) * t
    }

    /// Endpoints of one string as 3D points, from the nut to the bridge.
    static func stringLine(_ string: Int) -> (Pipa3DPoint, Pipa3DPoint) {
        (local(xPixel: stringPixelX(string, atY: nutPixel),
               yPixel: nutPixel, z: stringHeight),
         local(xPixel: stringPixelX(string, atY: bridgePixel),
               yPixel: bridgePixel, z: stringHeight))
    }

    /// One fret bar across the four strings, as 3D endpoints.
    static func fretLine(_ fret: Int) -> (Pipa3DPoint, Pipa3DPoint) {
        let y = stopRows[min(max(fret, 0), positionCount - 1)]
        let left = stringPixelX(0, atY: y) - 12
        let right = stringPixelX(3, atY: y) + 12
        return (local(xPixel: left, yPixel: y, z: fretHeight),
                local(xPixel: right, yPixel: y, z: fretHeight))
    }

    /// Rectangle covering the strip between the last fret and the bridge, the
    /// place an open string is sounded.
    static func tailQuad() -> [Pipa3DPoint] {
        let top = tailZoneTop
        let bottom = bridgePixel - 18
        let left = stringPixelX(0, atY: (top + bottom) / 2) - 20
        let right = stringPixelX(3, atY: (top + bottom) / 2) + 20
        return [local(xPixel: left, yPixel: top, z: fretHeight),
                local(xPixel: right, yPixel: top, z: fretHeight),
                local(xPixel: right, yPixel: bottom, z: fretHeight),
                local(xPixel: left, yPixel: bottom, z: fretHeight)]
    }

    /// The strip between the last fret and the bridge. This is the only place a
    /// real right hand strikes, and it is the only physically honest home for
    /// the open string: above the nut there is no speaking length at all.
    static let tailZoneTop: Double = 1246

    /// Hit test in instrument space, independent of any camera transform.
    /// Rules mirror PipaGeometry.nearest, including the open-string strip.
    static func hitInInstrumentSpace(x: Double, y: Double) -> (string: Int, fret: Int)? {
        guard y >= nutPixel - 8, y <= bridgePixel + 8 else { return nil }
        let xs = (0..<stringCount).map { stringPixelX($0, atY: y) }
        guard x >= xs[0] - 14, x <= xs[3] + 14 else { return nil }
        var bestString = 0
        for s in 1..<stringCount where abs(xs[s] - x) < abs(xs[bestString] - x) {
            bestString = s
        }
        if y > stopRows[positionCount - 1] + 12 { return (bestString, 0) }
        var bestFret = 0
        for n in 1..<positionCount
            where abs(stopRows[n] - y) < abs(stopRows[bestFret] - y) {
            bestFret = n
        }
        return (bestString, bestFret)
    }

    /// Runtime hit test: ray-cast the touch, then read the analytic geometry.
    /// No semantic field is queried here.
    static func hit(screen: CGPoint, camera: Pipa3DCamera) -> (string: Int, fret: Int)? {
        guard let l = camera.unproject(screen, planeZ: stringHeight) else { return nil }
        let (x, y) = pixel(l)
        return hitInInstrumentSpace(x: x, y: y)
    }

    /// Continuous pluck position along the string, clamped as in the 2D board.
    ///
    /// Inside the open-string strip the answer is the neutral 0.5, which
    /// PipaSynth maps onto the measured spot for that string. The hand is
    /// already where the fit was taken, and interpolating along y there would
    /// slide the stroke to 0.9 of the string, close to the node pattern of the
    /// middle and audibly softer than the string was measured to sound.
    static func pluckPosition(screen: CGPoint, camera: Pipa3DCamera) -> Double {
        guard let l = camera.unproject(screen, planeZ: stringHeight) else { return 0.5 }
        let (_, y) = pixel(l)
        if y >= tailZoneTop || y < nutPixel { return 0.5 }
        let fraction = (y - nutPixel) / (bridgePixel - nutPixel)
        return min(max(fraction, 0.15), 0.95)
    }

    /// True when a touch begins outside the playable string area. Those
    /// drags rotate the camera instead of plucking.
    static func isOutsideInstrument(screen: CGPoint,
                                    camera: Pipa3DCamera) -> Bool {
        hit(screen: screen, camera: camera) == nil
    }

    // MARK: - Procedural body outline

    /// Half width of the Pipa body at a given reference y. The shape is a
    /// narrow head and neck opening into a pear-shaped resonator. These are
    /// visual landmarks only; no geometry here affects the hit test.
    static func bodyHalfWidth(atY y: Double) -> Double {
        let keys: [(Double, Double)] = [
            (0, 20), (40, 30), (90, 34), (160, 40), (268, 50),
            (420, 60), (620, 92), (820, 150), (1000, 205),
            (1160, 231), (1300, 230), (1441, 205), (1510, 152), (1557, 78)
        ]
        if y <= keys[0].0 { return keys[0].1 }
        if y >= keys[keys.count - 1].0 { return keys[keys.count - 1].1 }
        for i in 0..<(keys.count - 1) {
            let a = keys[i], b = keys[i + 1]
            if y >= a.0 && y <= b.0 {
                let t = (y - a.0) / (b.0 - a.0)
                let smooth = t * t * (3 - 2 * t)
                return a.1 + (b.1 - a.1) * smooth
            }
        }
        return keys[keys.count - 1].1
    }

    /// Sampled cross sections of the body, used to draw the soundboard and
    /// the side walls. Each pair shares one reference y.
    static func bodySections(count: Int = 40) -> [(left: CGPoint, right: CGPoint)] {
        (0...count).map { step in
            let y = Double(step) / Double(count) * referenceHeight
            let w = bodyHalfWidth(atY: y)
            return (CGPoint(x: 247 - w, y: y), CGPoint(x: 247 + w, y: y))
        }
    }

    /// Closed projected outline of the body at a given depth. Drawing the
    /// back outline first and the front one on top leaves a visible rim that
    /// reads as the thickness of the instrument.
    static func outline(camera: Pipa3DCamera, z: Double = 0) -> [CGPoint] {
        let sections = bodySections()
        let right = sections.map {
            camera.project(local(xPixel: Double($0.right.x),
                                 yPixel: Double($0.right.y), z: z))
        }
        let left = sections.reversed().map {
            camera.project(local(xPixel: Double($0.left.x),
                                 yPixel: Double($0.left.y), z: z))
        }
        return right + left
    }
}
