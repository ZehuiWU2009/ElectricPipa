import Foundation

/// Criterion 4 prototype: can a rotatable 3D camera still reproduce the
/// existing 512 (string, stop) hit mappings?
///
/// This is a standalone command-line prototype. It does not touch
/// App/PipaGeometry.swift, FretboardView.swift or any DSP code, and it needs
/// no 3D asset. Foundation only, so SwiftUI macros cannot be blocked by the
/// sandbox.
///
/// The 2D constants below are copied from App/PipaGeometry.swift and
/// Core/PipaTuning.swift. They are lifted to 3D once:
///
///   x = transverse, y = nut to bridge, z = soundboard normal (z = 0)
///   1173 reference pixels span the 720 mm vibrating string length
///   four string lines interpolate from the nut to the bridge
///   32 stop planes sit at the equal-tempered stop rows
///
/// For every (string, stop) the prototype projects the 3D target through a
/// perspective camera at a given yaw/pitch, casts a ray back from the screen
/// point, intersects the soundboard plane, transforms the hit back into
/// instrument coordinates, and reads (string, stop) from analytic geometry.
/// The same projected screen point is also fed to the ORIGINAL 2D lookup as a
/// control. Two view groups are exercised: rotation alone (yaw +/-15, pitch
/// +/-10) and view transforms (drag and pinch). With a long lens, small yaw
/// barely changes the projection and the 2D lookup survives; dragging the
/// model or zooming breaks it completely. The ray-cast path must not.
///
/// Build and run (-parse-as-library is required because the file uses @main
/// alongside top-level constants, same as Scripts/verify-ui-geometry.swift):
///   xcrun swiftc -O -parse-as-library \
///       Scripts/verify-3d-geometry.swift -o /tmp/verify3d
///   /tmp/verify3d
///   python3 Scripts/export_fret_anchors.py --self-test \
///       --out /tmp/fret_anchors.json
///   /tmp/verify3d --anchors /tmp/fret_anchors.json
///
/// - Tag: Pipa

// MARK: - Small vector helpers

struct Vec3 {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Vec3(x: 0, y: 0, z: 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(x: a.x + b.x, y: a.y + b.y, z: a.z + b.z)
    }
    static func - (a: Vec3, b: Vec3) -> Vec3 {
        Vec3(x: a.x - b.x, y: a.y - b.y, z: a.z - b.z)
    }
    static func * (v: Vec3, s: Double) -> Vec3 {
        Vec3(x: v.x * s, y: v.y * s, z: v.z * s)
    }
    func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
}

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(v, lo), hi)
}

// MARK: - Instrument constants (from the shipped 2D geometry)

let referenceWidth = 506.0
let referenceHeight = 1557.0
let nutPixel = 268.0
let bridgePixel = 1441.0
let positionCount = 32
let stringCount = 4
let stringLengthMM = 720.0
let pixelsPerMM = (bridgePixel - nutPixel) / stringLengthMM

let stopRows: [Double] = [
    268, 338, 398, 458, 512, 564, 615,
    658, 698, 738, 774, 809, 842, 873, 901, 928, 957,
    983, 1008, 1030, 1053, 1073, 1092, 1111, 1130,
    1147, 1163, 1178, 1193, 1206, 1220, 1234
]

/// Equal-tempered stop law, same as export_fret_anchors.py.
func qLaw(_ n: Int) -> Double { 1.0 - pow(2.0, -Double(n) / 12.0) }

/// x of string s at a given reference y, in reference pixels.
func stringPixelX(_ s: Int, atY y: Double) -> Double {
    let t = clamp((y - nutPixel) / (bridgePixel - nutPixel), 0, 1)
    let nutX = 234.0 + Double(s) * 13.0
    let bridgeX = 209.0 + Double(s) * 30.0
    return nutX + (bridgeX - nutX) * t
}

// MARK: - Aspect-fit rectangle, identical to PipaGeometry.instrumentRect

struct Rect {
    var minX, minY, width, height: Double
    var midX: Double { minX + width / 2 }
    var midY: Double { minY + height / 2 }
    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
}

func instrumentRect(in bounds: Rect) -> Rect {
    let scale = min(bounds.width / referenceWidth, bounds.height / referenceHeight)
    let w = referenceWidth * scale
    let h = referenceHeight * scale
    return Rect(minX: bounds.midX - w / 2, minY: bounds.midY - h / 2,
                width: w, height: h)
}

// MARK: - The shipped 2D lookup (control group)

/// Reference-pixel hit test, matching PipaGeometry.nearest exactly.
/// Tolerances live in instrument space, so they do not change with the camera.
func hitInInstrumentSpace(x: Double, y: Double) -> (Int, Int)? {
    guard y >= nutPixel - 8, y <= bridgePixel + 8 else { return nil }
    let xs = (0..<stringCount).map { stringPixelX($0, atY: y) }
    guard x >= xs[0] - 14, x <= xs[3] + 14 else { return nil }
    var bestString = 0
    for s in 1..<stringCount where abs(xs[s] - x) < abs(xs[bestString] - x) {
        bestString = s
    }
    if y > stopRows[positionCount - 1] + 12 { return (bestString, 0) }
    var bestStop = 0
    for n in 1..<positionCount
        where abs(stopRows[n] - y) < abs(stopRows[bestStop] - y) {
        bestStop = n
    }
    return (bestString, bestStop)
}

/// The original screen-space 2D lookup, tolerances in screen points.
func hit2D(screenX: Double, screenY: Double, in rect: Rect) -> (Int, Int)? {
    let scale = rect.height / referenceHeight
    func pointX(_ px: Double) -> Double { rect.minX + px / referenceWidth * rect.width }
    func pointY(_ py: Double) -> Double { rect.minY + py / referenceHeight * rect.height }
    let nutY = pointY(nutPixel)
    let bridgeY = pointY(bridgePixel)
    func positionY(_ n: Int) -> Double { pointY(stopRows[n]) }
    func stringX(_ s: Int, atY y: Double) -> Double {
        let t = clamp((y - nutY) / (bridgeY - nutY), 0, 1)
        let nutX = 234.0 + Double(s) * 13.0
        let bridgeX = 209.0 + Double(s) * 30.0
        return pointX(nutX + (bridgeX - nutX) * t)
    }
    guard rect.width > 0, rect.height > 0,
          screenY >= nutY - 8, screenY <= bridgeY + 8, scale > 0 else { return nil }
    let xs = (0..<stringCount).map { stringX($0, atY: screenY) }
    guard screenX >= xs[0] - 14, screenX <= xs[3] + 14 else { return nil }
    var bestString = 0
    for s in 1..<stringCount where abs(xs[s] - screenX) < abs(xs[bestString] - screenX) {
        bestString = s
    }
    if screenY > positionY(positionCount - 1) + 12 { return (bestString, 0) }
    var bestStop = 0
    for n in 1..<positionCount
        where abs(positionY(n) - screenY) < abs(positionY(bestStop) - screenY) {
        bestStop = n
    }
    return (bestString, bestStop)
}

// MARK: - Perspective camera with yaw / pitch on the instrument

struct Camera {
    /// Rotation applied to the instrument, camera fixed at (0, 0, distance).
    var yaw: Double
    var pitch: Double
    /// In reference pixels. A long lens keeps distortion modest but non-zero.
    var distance: Double = 4671.0
    /// Screen centre and scale, derived from the aspect-fit rectangle.
    var centreX: Double
    var centreY: Double
    var scale: Double
    /// View transforms a 3D viewer always has: dragging and pinching the
    /// model. The shipped 2D lookup knows nothing about either.
    var panX: Double
    var panY: Double
    var zoom: Double

    init(yaw: Double, pitch: Double, rect: Rect,
         panX: Double = 0, panY: Double = 0, zoom: Double = 1,
         distance: Double = 4671.0) {
        self.yaw = yaw
        self.pitch = pitch
        self.panX = panX
        self.panY = panY
        self.zoom = zoom
        self.distance = distance
        // Instrument origin is the middle of the strings at the middle of the
        // vibrating length: (x = 247 px, y = 854.5 px) in reference space.
        self.centreX = rect.minX + 247.0 / referenceWidth * rect.width
        self.centreY = rect.minY + (nutPixel + bridgePixel) / 2.0
            / referenceHeight * rect.height
        self.scale = rect.height / referenceHeight
    }

    /// Instrument-local (u, v, w): u = x - 247 px, v = -(y - 854.5 px),
    /// w = z, all in reference pixels. v points up on screen.
    func rotate(_ l: Vec3) -> Vec3 {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        // Rx(pitch) then Ry(yaw)
        let y1 = l.y * cp - l.z * sp
        let z1 = l.y * sp + l.z * cp
        return Vec3(x: l.x * cy + z1 * sy, y: y1,
                    z: -l.x * sy + z1 * cy)
    }

    func unrotate(_ c: Vec3) -> Vec3 {
        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        // inverse Ry
        let x1 = c.x * cy - c.z * sy
        let z1 = c.x * sy + c.z * cy
        // inverse Rx
        return Vec3(x: x1, y: c.y * cp + z1 * sp, z: -c.y * sp + z1 * cp)
    }

    /// Normal of the rotated soundboard plane (the plane passes through 0).
    var planeNormal: Vec3 { rotate(Vec3(x: 0, y: 0, z: 1)) }

    func project(_ l: Vec3) -> (Double, Double) {
        let c = rotate(l)
        let depth = distance - c.z
        let factor = distance / depth
        let k = scale * zoom
        return (centreX + panX + c.x * factor * k,
                centreY + panY - c.y * factor * k)
    }

    /// Cast a ray from the screen point, intersect the soundboard plane,
    /// return the hit in instrument-local coordinates.
    func unproject(screenX: Double, screenY: Double) -> Vec3? {
        let k = scale * zoom
        let r = (screenX - centreX - panX) / (k * distance)
        let s = -(screenY - centreY - panY) / (k * distance)
        let direction = Vec3(x: r, y: s, z: -1)
        let n = planeNormal
        let denominator = n.dot(direction)
        guard abs(denominator) > 1e-12 else { return nil }
        let eye = Vec3(x: 0, y: 0, z: distance)
        let t = -(n.dot(eye)) / denominator
        guard t > 0 else { return nil }
        let hit = eye + direction * t
        return unrotate(hit)
    }
}

func localPoint(xPixel: Double, yPixel: Double) -> Vec3 {
    Vec3(x: xPixel - 247.0,
         y: -((yPixel - (nutPixel + bridgePixel) / 2.0)),
         z: 0)
}

func instrumentPixel(from local: Vec3) -> (Double, Double) {
    (247.0 + local.x, (nutPixel + bridgePixel) / 2.0 - local.y)
}

/// Read (string, stop) from the analytic 3D geometry via the ray-cast hit.
func hit3D(screenX: Double, screenY: Double, camera: Camera) -> (Int, Int)? {
    guard let local = camera.unproject(screenX: screenX, screenY: screenY) else {
        return nil
    }
    let (x, y) = instrumentPixel(from: local)
    return hitInInstrumentSpace(x: x, y: y)
}

/// Finger jitter test. Perfect geometry does not guarantee a usable
/// instrument: the tightest high stops are only a couple of screen points
/// apart on the narrow layouts, so a few points of touch noise can move the
/// ray-cast hit onto a neighbouring stop.
func jitterAccuracy(jitter: Double) -> (all: Double, low: Double, high: Double) {
    var state: UInt64 = 0x9e3779b97f4a7c15
    func noise() -> Double {
        state ^= state &<< 13
        state ^= state >> 7
        state ^= state &<< 17
        return Double(state % 200_001) / 100_000.5 - 1.0
    }
    var allHit = 0, allTotal = 0
    var lowHit = 0, lowTotal = 0
    var highHit = 0, highTotal = 0
    for (w, h) in screenSizes {
        let bounds = Rect(minX: 0, minY: 0, width: w, height: h)
        let rect = instrumentRect(in: bounds)
        let camera = Camera(yaw: 0, pitch: 0, rect: rect)
        for s in 0..<stringCount {
            for n in 0..<positionCount {
                let yPixel = stopRows[n]
                let xPixel = stringPixelX(s, atY: yPixel)
                let p = camera.project(localPoint(xPixel: xPixel, yPixel: yPixel))
                let hit = hit3D(screenX: p.0 + noise() * jitter,
                                screenY: p.1 + noise() * jitter,
                                camera: camera)
                var ok = false
                if let h = hit, h.0 == s, h.1 == n { ok = true }
                allTotal += 1
                if ok { allHit += 1 }
                if n >= 24 {
                    highTotal += 1
                    if ok { highHit += 1 }
                } else {
                    lowTotal += 1
                    if ok { lowHit += 1 }
                }
            }
        }
    }
    return (Double(allHit) / Double(allTotal),
            Double(lowHit) / Double(lowTotal),
            Double(highHit) / Double(highTotal))
}

// MARK: - Optional offline asset from export_fret_anchors.py

/// Validates that the JSON produced by the offline calibration can drive the
/// 32 stops. Only the q values and the fitted deviations are consumed here;
/// mapping the reconstruction frame onto the camera frame needs the scene
/// camera poses and is a later step.
struct AnchorsReport {
    var loaded: Bool
    var fretCount: Int
    var stringCount: Int
    var maxDeviationMM: Double?
    var note: String
}

func loadAnchors(_ path: String) -> AnchorsReport {
    guard let data = FileManager.default.contents(atPath: path),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let frets = json["frets"] as? [[String: Any]],
          let strings = json["strings"] as? [[String: Any]] else {
        return AnchorsReport(loaded: false, fretCount: 0, stringCount: 0,
                             maxDeviationMM: nil, note: "could not parse " + path)
    }
    let deviations = frets.compactMap { $0["deviationMM"] as? Double }
    let qs = frets.compactMap { $0["q"] as? Double }
    var maxQError = 0.0
    for (i, q) in qs.enumerated() where i < positionCount {
        maxQError = max(maxQError, abs(q - qLaw(i)))
    }
    let synthetic = (json["synthetic"] as? Bool) ?? false
    let note = String(format: "q matches the equal-tempered law within %.6f; "
                        + "%d of %d stops observed%@",
                      maxQError, deviations.count, positionCount,
                      synthetic ? "; SYNTHETIC, wiring check only" : "")
    return AnchorsReport(loaded: true, fretCount: frets.count,
                         stringCount: strings.count,
                         maxDeviationMM: deviations.max(), note: note)
}

// MARK: - Verification

let screenSizes: [(Double, Double)] = [
    (276, 340), (358, 520), (700, 800), (430, 240)
]
let yaws = [-15.0, -10.0, -5.0, 0.0, 5.0, 10.0, 15.0]
let pitches = [-10.0, 0.0, 10.0]

struct AngleResult {
    var yaw, pitch: Double
    var group: String
    var label: String
    var rayHits, tableHits, total: Int
    var maxRoundTripErrorPx: Double
    var minHighStopGapPx: Double
    var maxScreenShiftPx: Double
}

func runView(yaw: Double, pitch: Double, group: String, label: String,
             panX: Double = 0, panY: Double = 0, zoom: Double = 1,
             distance: Double = 4671.0) -> AngleResult {
    let yawRad = yaw * .pi / 180
    let pitchRad = pitch * .pi / 180
    var rayHits = 0
    var tableHits = 0
    var total = 0
    var maxRoundTrip = 0.0
    var minGap = Double.greatestFiniteMagnitude
    var maxShift = 0.0

    for (w, h) in screenSizes {
        let bounds = Rect(minX: 0, minY: 0, width: w, height: h)
        let rect = instrumentRect(in: bounds)
        let camera = Camera(yaw: yawRad, pitch: pitchRad, rect: rect,
                            panX: panX, panY: panY, zoom: zoom,
                            distance: distance)

        for s in 0..<stringCount {
            for n in 0..<positionCount {
                let yPixel = stopRows[n]
                let xPixel = stringPixelX(s, atY: yPixel)
                let local = localPoint(xPixel: xPixel, yPixel: yPixel)
                let (sx, sy) = camera.project(local)

                // Round-trip check: the ray-cast hit must recover the 3D point.
                if let back = camera.unproject(screenX: sx, screenY: sy) {
                    let (bx, by) = instrumentPixel(from: back)
                    maxRoundTrip = max(maxRoundTrip,
                                       max(abs(bx - xPixel), abs(by - yPixel)))
                }

                if let hit = hit3D(screenX: sx, screenY: sy, camera: camera),
                   hit.0 == s, hit.1 == n {
                    rayHits += 1
                }
                if let hit = hit2D(screenX: sx, screenY: sy, in: rect),
                   hit.0 == s, hit.1 == n {
                    tableHits += 1
                }
                total += 1
            }
        }

        // Physical crowding: screen gap between the two tightest high stops.
        for n in 24..<(positionCount - 1) {
            let y0 = stopRows[n], y1 = stopRows[n + 1]
            let x0 = stringPixelX(1, atY: y0)
            let x1 = stringPixelX(1, atY: y1)
            let p0 = camera.project(localPoint(xPixel: x0, yPixel: y0))
            let p1 = camera.project(localPoint(xPixel: x1, yPixel: y1))
            minGap = min(minGap, abs(p1.1 - p0.1))
        }

        // How far the projected instrument drifts from the flat 2D layout.
        for n in 0..<positionCount {
            let yPixel = stopRows[n]
            let xPixel = stringPixelX(3, atY: yPixel)
            let p = camera.project(localPoint(xPixel: xPixel, yPixel: yPixel))
            let flatX = rect.minX + xPixel / referenceWidth * rect.width
            let flatY = rect.minY + yPixel / referenceHeight * rect.height
            maxShift = max(maxShift, max(abs(p.0 - flatX), abs(p.1 - flatY)))
        }
    }
    return AngleResult(yaw: yaw, pitch: pitch, group: group, label: label,
                       rayHits: rayHits, tableHits: tableHits, total: total,
                       maxRoundTripErrorPx: maxRoundTrip,
                       minHighStopGapPx: minGap,
                       maxScreenShiftPx: maxShift)
}

@main
struct Verify3DGeometry {
    static func main() {
        precondition(stopRows.count == positionCount)
        precondition(zip(stopRows, stopRows.dropFirst()).allSatisfy { $0 < $1 })

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--anchors"),
           index + 1 < arguments.count {
            let report = loadAnchors(arguments[index + 1])
            print("Offline asset: \(report.loaded ? "parsed" : "FAILED"), "
                  + "\(report.fretCount) frets, \(report.stringCount) strings")
            if let dev = report.maxDeviationMM {
                print(String(format: "  max centroid deviation %.3f mm", dev))
            }
            print("  " + report.note)
            print("")
        }

        var results: [AngleResult] = []
        // Group A: rotation only, long lens, no pan or zoom. This is the
        // conservative case where the shipped 2D lookup degrades least.
        for yaw in yaws {
            for pitch in pitches {
                results.append(runView(
                    yaw: yaw, pitch: pitch, group: "rotation",
                    label: String(format: "yaw %+3.0f pitch %+3.0f", yaw, pitch)))
            }
        }
        // Group B: dragging and pinching the model, which every 3D viewer
        // has. The 2D lookup is given the original aspect-fit rect and has
        // no way to follow these transforms.
        let transforms: [(Double, Double, Double)] = [
            (20, -15, 1.0), (-30, 25, 1.0), (0, 0, 1.15),
            (0, 0, 0.85), (18, 12, 1.15), (-22, -18, 0.9)
        ]
        for (dx, dy, z) in transforms {
            for (yaw, pitch) in [(0.0, 0.0), (10.0, 10.0)] {
                results.append(runView(
                    yaw: yaw, pitch: pitch, group: "panzoom",
                    label: String(format: "pan(%+3.0f,%+3.0f) zoom %.2f "
                                  + "yaw %+2.0f pitch %+2.0f",
                                  dx, dy, z, yaw, pitch),
                    panX: dx, panY: dy, zoom: z))
            }
        }

        func summary(_ group: String) -> (Int, Int, Int) {
            let subset = results.filter { $0.group == group }
            return (subset.reduce(0) { $0 + $1.rayHits },
                    subset.reduce(0) { $0 + $1.tableHits },
                    subset.reduce(0) { $0 + $1.total })
        }

        let total = results.reduce(0) { $0 + $1.total }
        let ray = results.reduce(0) { $0 + $1.rayHits }
        let table = results.reduce(0) { $0 + $1.tableHits }
        let mappings = positionCount * stringCount * screenSizes.count
        print(String(format: "%d hit tests = %d mappings x %d views "
                      + "(4 screen sizes each)", total, mappings, results.count))
        print(String(format: "  ray-cast + analytic geometry : %d / %d (%.2f%%)",
                     ray, total, 100.0 * Double(ray) / Double(total)))
        print(String(format: "  original 2D pixel lookup    : %d / %d (%.2f%%)",
                     table, total, 100.0 * Double(table) / Double(total)))
        for group in ["rotation", "panzoom"] {
            let (r, t, n) = summary(group)
            print(String(format: "  %@ group: ray %.2f%%, 2D table %.2f%% (%d hits)",
                         group, 100.0 * Double(r) / Double(n),
                         100.0 * Double(t) / Double(n), n))
        }
        print("")

        print("Rotation only, pitch = 0:")
        for r in results.filter({ $0.group == "rotation" && $0.pitch == 0 }) {
            print(String(format: "  yaw %+5.0f deg | ray %5.1f%% | 2D table %5.1f%% "
                          + "| min high-stop gap %5.2f pt | max shift %6.1f pt",
                         r.yaw,
                         100.0 * Double(r.rayHits) / Double(r.total),
                         100.0 * Double(r.tableHits) / Double(r.total),
                         r.minHighStopGapPx, r.maxScreenShiftPx))
        }
        print("")
        print("Rotation only, yaw = 0:")
        for r in results.filter({ $0.group == "rotation" && $0.yaw == 0 }) {
            print(String(format: "  pitch %+5.0f deg | ray %5.1f%% | 2D table %5.1f%% "
                          + "| min high-stop gap %5.2f pt",
                         r.pitch,
                         100.0 * Double(r.rayHits) / Double(r.total),
                         100.0 * Double(r.tableHits) / Double(r.total),
                         r.minHighStopGapPx))
        }
        print("")
        print("Pan / zoom views:")
        for r in results.filter({ $0.group == "panzoom" }) {
            print(String(format: "  %@ | ray %5.1f%% | 2D table %5.1f%%",
                         r.label,
                         100.0 * Double(r.rayHits) / Double(r.total),
                         100.0 * Double(r.tableHits) / Double(r.total)))
        }

        let flat = results.first { $0.group == "rotation"
            && $0.yaw == 0 && $0.pitch == 0 }!
        let maxRoundTrip = results.map { $0.maxRoundTripErrorPx }.max() ?? 0
        print("")
        print(String(format: "Front camera: ray %.2f%%, 2D table %.2f%%",
                     100.0 * Double(flat.rayHits) / Double(flat.total),
                     100.0 * Double(flat.tableHits) / Double(flat.total)))
        print(String(format: "Max 3D round-trip error over all views: %.9f reference px",
                     maxRoundTrip))
        print(String(format: "Tightest high-stop screen gap (smallest of 4 sizes): "
                      + "%.2f pt at front, %.2f pt across all views",
                     flat.minHighStopGapPx,
                     results.map { $0.minHighStopGapPx }.min() ?? 0))

        // Outside rejection and open-string zone, front camera.
        let bounds = Rect(minX: 0, minY: 0, width: 358, height: 520)
        let rect = instrumentRect(in: bounds)
        let front = Camera(yaw: 0, pitch: 0, rect: rect)
        let topOutside = cameraPair(front, xPixel: 247, yPixel: 100)
        let leftOutside = cameraPair(front, xPixel: 20, yPixel: 800)
        let openZone = cameraPair(front, xPixel: stringPixelX(2, atY: 1439),
                                  yPixel: 1439)
        print("")
        print("Outside rejection (front): \(topOutside == nil ? "OK" : "FAIL"), "
              + "\(leftOutside == nil ? "OK" : "FAIL")")
        print("Open-string zone: \(openZone?.1 == 0 ? "OK" : "FAIL")")

        print("")
        print("Finger jitter, front camera, 4 screen sizes:")
        for jitter in [0.0, 1.0, 2.0, 3.0, 5.0] {
            let r = jitterAccuracy(jitter: jitter)
            print(String(format: "  +/-%.0f pt | all %5.1f%% | stops 0-23 %5.1f%% "
                          + "| stops 24-31 %5.1f%%",
                         jitter, r.all * 100, r.low * 100, r.high * 100))
        }

        let threshold = 0.99
        let (pzRay, _, pzTotal) = summary("panzoom")
        let passed = Double(ray) / Double(total) >= threshold
            && flat.rayHits == flat.total
            && pzRay == pzTotal
            && maxRoundTrip < 1e-6
        print("")
        print("Criterion 4 (>= 99% top-1 across all views): "
              + (passed ? "PASS" : "FAIL"))
        print("(The 2D lookup degradation above is expected and is the reason "
              + "the runtime must not use screen-space constants.)")
        if !passed { exit(1) }
    }

    /// Project an instrument-space point through the front camera and read
    /// the ray-cast hit. Used for the boundary-rule checks.
    static func cameraPair(_ camera: Camera, xPixel: Double,
                           yPixel: Double) -> (Int, Int)? {
        let p = camera.project(localPoint(xPixel: xPixel, yPixel: yPixel))
        return hit3D(screenX: p.0, screenY: p.1, camera: camera)
    }
}
