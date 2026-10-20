import SwiftUI

@main
struct GeometryVerification {
    static func main() {
        precondition(PipaGeometry.stopRows.count == PipaTuning.positionCount)
        precondition(zip(PipaGeometry.stopRows, PipaGeometry.stopRows.dropFirst()).allSatisfy { $0 < $1 })
        let sizes: [CGSize] = [CGSize(width: 276, height: 340), CGSize(width: 358, height: 520),
                               CGSize(width: 700, height: 800), CGSize(width: 430, height: 240)]
        var checked = 0
        for size in sizes {
            let bounds = CGRect(origin: .zero, size: size)
            let rect = PipaGeometry.instrumentRect(in: bounds)
            precondition(rect.minX >= -0.001 && rect.minY >= -0.001)
            precondition(rect.maxX <= bounds.maxX + 0.001 && rect.maxY <= bounds.maxY + 0.001)
            precondition(abs(rect.width / rect.height - 978.0 / 1609.0) < 0.0001)
            for string in 0..<4 {
                for fret in 0..<PipaGeometry.positionCount {
                    let y = PipaGeometry.positionY(fret, in: rect)
                    let point = CGPoint(x: PipaGeometry.stringX(string, atY: y, in: rect), y: y)
                    let hit = PipaGeometry.nearest(location: point, in: rect)
                    precondition(hit?.string == string && hit?.fret == fret, "Incorrect hit at \(size), string \(string), fret \(fret)")
                    checked += 1
                }
            }
            precondition(PipaGeometry.nearest(location: CGPoint(x: rect.midX, y: rect.minY), in: rect) == nil)
            precondition(PipaGeometry.nearest(location: CGPoint(x: rect.minX, y: rect.midY), in: rect) == nil)
            let y = PipaGeometry.bridgeY(in: rect) - 2
            let open = PipaGeometry.nearest(location: CGPoint(x: PipaGeometry.stringX(2, atY: y, in: rect), y: y), in: rect)
            precondition(open?.string == 2 && open?.fret == 0)
        }
        print("Passed: \(checked) string/stop hit mappings, aspect ratio, outside rejection and open-string zone across four sizes.")
    }
}
