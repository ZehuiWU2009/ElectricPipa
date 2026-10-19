import SwiftUI

/// Static geometry of the Pipa panel: the instrument outline, the hardware and
/// the thirty-two stop positions on each of the four strings.
///
/// The layout follows the real instrument. The soundboard is a half-pear
/// silhouette; the strings run from the nut at the top to the bridge at the
/// bottom; and stop position n sits where the sounding length of the string is
/// 2^(-n/12) of the open length, which is exactly where the six xiang and the
/// twenty-five frets of a real Pipa are placed, every adjacent pair a semitone
/// apart in twelve-tone equal temperament.
enum PipaGeometry {

    // MARK: Vertical landmarks, as fractions of the board height

    /// 山口, the nut, where the strings start.
    static let nutFraction: CGFloat = 0.045
    /// 覆手, the bridge, where the strings end.
    static let bridgeFraction: CGFloat = 0.925

    // MARK: The four strings, as x fractions of the board width

    /// The Chan string, thickest and lowest, sits on the left; the Zi string,
    /// thinnest and highest, on the right.
    static let stringLeftFraction: CGFloat = 0.30
    static let stringRightFraction: CGFloat = 0.70

    static let stringCount = 4
    static let positionCount = PipaTuning.positionCount

    /// Sounding length of one string stopped at one position, as a fraction of
    /// the open length: one semitone per step.
    static func lengthFraction(_ position: Int) -> CGFloat {
        CGFloat(pow(2.0, -Double(position) / 12.0))
    }

    static func nutY(in rect: CGRect) -> CGFloat {
        rect.minY + rect.height * nutFraction
    }

    static func bridgeY(in rect: CGRect) -> CGFloat {
        rect.minY + rect.height * bridgeFraction
    }

    static func stringX(_ string: Int, in rect: CGRect) -> CGFloat {
        let span = stringRightFraction - stringLeftFraction
        let t = CGFloat(string) / CGFloat(stringCount - 1)
        return rect.minX + rect.width * (stringLeftFraction + span * t)
    }

    /// y of one stop position on a string. Position 0 sits at the nut, the
    /// open string; each step above it moves toward the bridge.
    static func positionY(_ position: Int, in rect: CGRect) -> CGFloat {
        let nut = nutY(in: rect)
        let length = bridgeY(in: rect) - nut
        return nut + length * (1.0 - lengthFraction(position))
    }

    /// Positions 1 to 6 are the xiang on the neck; 7 and above are the frets
    /// on the soundboard.
    static func isXiang(_ position: Int) -> Bool {
        position >= 1 && position <= PipaTuning.xiangCount
    }

    // MARK: Instrument outline

    /// The half-pear soundboard outline, neck included. All coordinates are
    /// fractions of the board rect, with x measured from the centre line.
    static func bodyPath(in rect: CGRect) -> Path {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * rect.width, y: rect.minY + fy * rect.height)
        }
        var path = Path()
        // Top of the neck
        path.move(to: p(-0.070, 0.015))
        path.addLine(to: p(0.070, 0.015))
        // Right neck into the shoulder
        path.addCurve(to: p(0.440, 0.400),
                      control1: p(0.100, 0.140),
                      control2: p(0.440, 0.280))
        // Shoulder out to the widest point
        path.addCurve(to: p(0.465, 0.600),
                      control1: p(0.440, 0.500),
                      control2: p(0.465, 0.500))
        // Widest point in to the hip
        path.addCurve(to: p(0.300, 0.850),
                      control1: p(0.465, 0.720),
                      control2: p(0.380, 0.850))
        // Hip round-off into the bottom tip
        path.addCurve(to: p(0.000, 0.985),
                      control1: p(0.240, 0.990),
                      control2: p(0.100, 0.995))
        // Mirror back up the left side
        path.addCurve(to: p(-0.300, 0.850),
                      control1: p(-0.100, 0.995),
                      control2: p(-0.240, 0.990))
        path.addCurve(to: p(-0.465, 0.600),
                      control1: p(-0.380, 0.850),
                      control2: p(-0.465, 0.720))
        path.addCurve(to: p(-0.440, 0.400),
                      control1: p(-0.465, 0.500),
                      control2: p(-0.465, 0.500))
        path.addCurve(to: p(-0.070, 0.015),
                      control1: p(-0.440, 0.280),
                      control2: p(-0.100, 0.140))
        path.closeSubpath()
        return path
    }

    /// 覆手, the bridge the strings rest on near the bottom of the board.
    static func bridgePath(in rect: CGRect) -> Path {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * rect.width, y: rect.minY + fy * rect.height)
        }
        var path = Path()
        path.move(to: p(-0.075, bridgeFraction - 0.012))
        path.addLine(to: p(0.075, bridgeFraction - 0.012))
        path.addLine(to: p(0.095, bridgeFraction + 0.028))
        path.addLine(to: p(-0.095, bridgeFraction + 0.028))
        path.closeSubpath()
        return path
    }

    /// Fixed wood grain, so the texture is deterministic across runs. Each
    /// entry is start, control and end of one quadratic curve.
    static func grainPaths(in rect: CGRect) -> [Path] {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * rect.width, y: rect.minY + fy * rect.height)
        }
        let strokes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.300, 0.180, -0.120, 0.450, -0.220, 0.780),
            ( 0.050, 0.160,  0.300, 0.420,  0.120, 0.720),
            (-0.050, 0.560, -0.300, 0.680, -0.100, 0.900),
            ( 0.280, 0.300,  0.400, 0.560,  0.300, 0.860),
            (-0.380, 0.340, -0.420, 0.620, -0.350, 0.840),
            ( 0.100, 0.790,  0.260, 0.860,  0.140, 0.950),
        ]
        return strokes.map { s in
            var path = Path()
            path.move(to: p(s.0, s.1))
            path.addQuadCurve(to: p(s.4, s.5), control: p(s.2, s.3))
            return path
        }
    }

    /// 轸子, the four tuning pegs sticking out of the head, two per side.
    static func pegPoints(in rect: CGRect) -> [CGPoint] {
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * rect.width, y: rect.minY + fy * rect.height)
        }
        return [p(-0.118, 0.038), p(-0.118, 0.098), p(0.118, 0.038), p(0.118, 0.098)]
    }

    // MARK: Hit testing

    /// Nearest stop position to a point in board coordinates, or nil when the
    /// point is too far from any string to count as a touch on it.
    static func nearest(location: CGPoint, in rect: CGRect) -> (string: Int, fret: Int)? {
        var bestString = -1
        var bestDX = CGFloat.infinity
        for string in 0..<stringCount {
            let distance = abs(location.x - stringX(string, in: rect))
            if distance < bestDX {
                bestDX = distance
                bestString = string
            }
        }
        guard bestString >= 0, bestDX < rect.width * 0.085 else { return nil }
        var bestFret = 0
        var bestDY = CGFloat.infinity
        for fret in 0..<positionCount {
            let distance = abs(location.y - positionY(fret, in: rect))
            if distance < bestDY {
                bestDY = distance
                bestFret = fret
            }
        }
        return (bestString, bestFret)
    }

    /// Where along the string a touch landed, 0 at the nut and 1 at the
    /// bridge, used as the excitation point of the pluck.
    static func pluckPosition(_ location: CGPoint, in rect: CGRect) -> Double {
        let nut = nutY(in: rect)
        let span = bridgeY(in: rect) - nut
        let t = (location.y - nut) / span
        return Double(min(max(t, 0.15), 0.95))
    }
}
