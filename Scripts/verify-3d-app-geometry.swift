/// Regression test for the geometry that ships in the app.
///
/// Unlike Scripts/verify-3d-geometry.swift, which carries its own copy of the
/// maths, this compiles App/Pipa3DGeometry.swift directly and checks the real
/// hit path: 4 sizes x 21 angle pairs x 3 view transforms x 32 stops x 4
/// strings, plus outside rejection, the open-string zone and a fully tilted,
/// panned and zoomed camera.
///
/// Build and run from the project root:
///   xcrun swiftc -O -parse-as-library ///       App/Pipa3DGeometry.swift Scripts/verify-3d-app-geometry.swift ///       -o /tmp/verify_shipping
///   /tmp/verify_shipping
///
import Foundation
import CoreGraphics

/// Verifies the geometry that actually ships in App/Pipa3DGeometry.swift,
/// not the standalone prototype in Scripts/verify-3d-geometry.swift.

@main
struct VerifyShippingGeometry {
    static func main() {
        let sizes: [(CGFloat, CGFloat)] = [
            (276, 340), (358, 520), (700, 800), (430, 240)
        ]
        let yaws = [-15.0, -10, -5, 0, 5, 10, 15].map { $0 * .pi / 180 }
        let pitches = [-10.0, 0, 10].map { $0 * .pi / 180 }
        let views: [(String, Double, Double, Double)] = [
            ("front", 1, 0, 0),
            ("pan/zoom", 1.15, 20, -15),
            ("zoom out", 0.85, -30, 25)
        ]

        var total = 0
        var hits = 0
        var maxRoundTrip = 0.0
        var worstView = ""

        for (w, h) in sizes {
            let rect = Pipa3DGeometry.instrumentRect(
                in: CGRect(x: 0, y: 0, width: w, height: h))
            for yaw in yaws {
                for pitch in pitches {
                    for (name, zoom, dx, dy) in views {
                        let camera = Pipa3DGeometry.camera(
                            for: rect, yaw: yaw, pitch: pitch, zoom: zoom,
                            panX: dx, panY: dy)
                        for string in 0..<Pipa3DGeometry.stringCount {
                            for fret in 0..<Pipa3DGeometry.positionCount {
                                let y = Pipa3DGeometry.stopRows[fret]
                                let x = Pipa3DGeometry.stringPixelX(string, atY: y)
                                let target = Pipa3DGeometry.local(
                                    xPixel: x, yPixel: y,
                                    z: Pipa3DGeometry.stringHeight)
                                let screen = camera.project(target)
                                if let hit = Pipa3DGeometry.hit(screen: screen,
                                                                 camera: camera),
                                   hit.string == string, hit.fret == fret {
                                    hits += 1
                                }
                                if let back = camera.unproject(
                                    screen, planeZ: Pipa3DGeometry.stringHeight) {
                                    let (bx, by) = Pipa3DGeometry.pixel(back)
                                    let error = max(abs(bx - x), abs(by - y))
                                    if error > maxRoundTrip {
                                        maxRoundTrip = error
                                        worstView = name
                                    }
                                }
                                total += 1
                            }
                        }
                    }
                }
            }
        }

        print("Shipping Pipa3DGeometry: \(hits) / \(total) hits "
              + String(format: "(%.2f%%)", 100.0 * Double(hits) / Double(total)))
        print(String(format: "Max 3D round-trip error: %.9f reference px (%@)",
                     maxRoundTrip, worstView))

        // Boundary rules, front camera.
        let rect = Pipa3DGeometry.instrumentRect(
            in: CGRect(x: 0, y: 0, width: 358, height: 520))
        let front = Pipa3DGeometry.camera(for: rect)
        let outside = Pipa3DGeometry.isOutsideInstrument(
            screen: front.project(Pipa3DGeometry.local(xPixel: 20, yPixel: 800)),
            camera: front)
        let openY = Pipa3DGeometry.bridgePixel - 2
        let open = Pipa3DGeometry.hit(
            screen: front.project(Pipa3DGeometry.local(
                xPixel: Pipa3DGeometry.stringPixelX(2, atY: openY),
                yPixel: openY)),
            camera: front)
        print("Outside-string rejection: \(outside ? "OK" : "FAIL")")
        print("Open-string zone: \(open?.fret == 0 ? "OK" : "FAIL")")

        // Fresh notes stay at their own stop when the camera moves.
        var moved = 0
        let tilted = Pipa3DGeometry.camera(for: rect, yaw: 15 * .pi / 180,
                                           pitch: 10 * .pi / 180, zoom: 1.15,
                                           panX: 20, panY: -15)
        for string in 0..<Pipa3DGeometry.stringCount {
            for fret in 0..<Pipa3DGeometry.positionCount {
                let y = Pipa3DGeometry.stopRows[fret]
                let x = Pipa3DGeometry.stringPixelX(string, atY: y)
                let screen = tilted.project(Pipa3DGeometry.local(
                    xPixel: x, yPixel: y, z: Pipa3DGeometry.stringHeight))
                if let hit = Pipa3DGeometry.hit(screen: screen, camera: tilted),
                   hit.string == string, hit.fret == fret { moved += 1 }
            }
        }
        print("Tilted + panned + zoomed view: \(moved) / 128 hits")

        let passed = hits == total && maxRoundTrip < 1e-6
            && outside && open?.fret == 0 && moved == 128
        print("Shipping geometry verdict: \(passed ? "PASS" : "FAIL")")
        if !passed { exit(1) }
    }
}
