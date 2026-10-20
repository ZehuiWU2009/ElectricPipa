import SwiftUI

/// Static geometry of the Pipa panel: the instrument outline, the hardware and
/// the thirty-two stop positions on each of the four strings.
///
/// The layout follows the real instrument, measured from the owner's own
/// photographs. The head and the pegbox take the top fifth of the board, so
/// the 山口 (nut) sits well below the top edge and the soundboard swells out
/// from a slim neck to a wide lower bout whose widest point is low down. The
/// bottom closes in one broad, shallow curve — the spoon shape of the real
/// instrument. The four strings run in a shallow fan, narrow where they
/// leave the nut and a little wider where they cross the 覆手, and every
/// string crosses the same frets, so nothing can drift out of place.
///
/// Stop position n sits where the sounding length of the string is 2^(-n/12)
/// of the open length, which is exactly where the six xiang and the
/// twenty-five frets of a real Pipa are placed.
enum PipaGeometry {

    // MARK: Vertical landmarks, as fractions of the board height

    /// 山口, the nut, where the strings start. On the real instrument the
    /// carved head and the four pegs take the top fifth of the body, so the
    /// nut sits at about a quarter of the way down, not at the top edge.
    static let nutFraction: CGFloat = 0.228
    /// 覆手, the bridge, where the strings end.
    static let bridgeFraction: CGFloat = 0.905

    static let stringCount = 4
    static let positionCount = PipaTuning.positionCount

    // MARK: Horizontal reference

    /// Reference length for all horizontal measurements. Horizontal fractions
    /// in this file are fractions of this unit, not of the board width, so the
    /// instrument keeps its true proportions on any screen: the widest point
    /// of the body is 0.59 units across, and the unit shrinks on narrow
    /// screens so the body never overflows the panel.
    static func unit(in rect: CGRect) -> CGFloat {
        min(rect.width / 0.62, rect.height)
    }

    // MARK: The instrument outline

    /// Anchors of the half-spoon outline: (y as a fraction of board height,
    /// half-width as a fraction of unit), measured off the real instrument.
    /// The top entries describe the head and the pegbox and the middle entries
    /// the slim neck and the shoulder where the body swells. The last entry
    /// past `bellyCentreY` is kept even though the interpolation stops there:
    /// it is what makes the tangent at the widest point horizontal, so the
    /// Hermite part and the elliptical part join without a kink.
    static let outlineAnchors: [(y: CGFloat, halfWidth: CGFloat)] = [
        (0.010, 0.048), (0.045, 0.060), (0.090, 0.060), (0.130, 0.052),
        (0.170, 0.046), (0.200, 0.047), (0.228, 0.053), (0.263, 0.055),
        (0.302, 0.046), (0.342, 0.070), (0.381, 0.071), (0.421, 0.086),
        (0.460, 0.104), (0.499, 0.127), (0.539, 0.150), (0.578, 0.175),
        (0.618, 0.201), (0.657, 0.228), (0.696, 0.255), (0.736, 0.275),
        (0.775, 0.290), (0.814, 0.296), (0.850, 0.290),
    ]

    // MARK: The lower bout

    /// The bottom of the body is one exact ellipse, not more spline: the real
    /// instrument closes in a broad round curve and the ellipse is the only
    /// simple curve whose tangent at its lowest point is truly horizontal. A
    /// spline can be made to pass through the same points, but its slope
    /// saturates at a finite value there, and mirroring it leaves a visible
    /// point at the bottom instead of a smooth curve.
    ///
    /// Its centre line sits at `bellyCentreY`, which is also the widest point
    /// of the body, and it reaches half-width zero at `bellyBottomY`.
    static let bellyCentreY: CGFloat = 0.814
    static let bellyHalfWidth: CGFloat = 0.296
    static let bellyBottomY: CGFloat = 0.985
    /// Quarter height of that ellipse, the distance from the centre line down
    /// to the bottom edge.
    static let bellyRise: CGFloat = bellyBottomY - bellyCentreY

    /// Half-width of the elliptical lower bout at a height fraction `fy`.
    static func bellyHalfWidth(atY fy: CGFloat) -> CGFloat {
        let t = (fy - bellyCentreY) / bellyRise
        if t >= 1 { return 0 }
        return bellyHalfWidth * sqrt(max(0, 1 - t * t))
    }

    /// Half-width of the body at a height fraction `fy`: cubic Hermite
    /// interpolation through the outline anchors down to the widest point,
    /// then the elliptical lower bout.
    ///
    /// The tangents are taken across the real neighbour distances, so the
    /// curve stays smooth even where the anchors bunch up near the bottom —
    /// a uniform Catmull-Rom basis would kink exactly there. At the junction
    /// both sides are horizontal, so the two parts meet flat.
    static func bodyHalfWidth(atY fy: CGFloat, in rect: CGRect) -> CGFloat {
        if fy >= bellyBottomY { return 0 }
        if fy >= bellyCentreY { return bellyHalfWidth(atY: fy) }
        let a = outlineAnchors
        if fy <= a[0].y { return a[0].halfWidth }
        var i = 0
        while i < a.count - 2 && fy >= a[i + 1].y { i += 1 }
        let p1 = a[i]
        let p2 = a[i + 1]
        let p0 = i > 0 ? a[i - 1] : p1
        let p3 = i + 2 < a.count ? a[i + 2] : p2
        let h = p2.y - p1.y
        let m1 = (p2.halfWidth - p0.halfWidth) / (p2.y - p0.y) * h
        let m2 = (p3.halfWidth - p1.halfWidth) / (p3.y - p1.y) * h
        let t = (fy - p1.y) / h
        let t2 = t * t
        let t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p1.halfWidth
            + (t3 - 2 * t2 + t) * m1
            + (-2 * t3 + 3 * t2) * p2.halfWidth
            + (t3 - t2) * m2
    }

    /// The soundboard outline, neck and head included, sampled from the
    /// half-width function down the right side and mirrored up the left.
    ///
    /// The upper part is sampled evenly in y. The elliptical bottom is
    /// sampled evenly in *angle* instead, which is what keeps the curve
    /// smooth where it turns horizontal: sampled evenly in y, the last chord
    /// before the bottom still leans a few degrees and mirroring puts a
    /// crease right at the lowest point.
    static func bodyPath(in rect: CGRect) -> Path {
        let u = unit(in: rect)
        let steps = 320
        let bellySteps = 96
        var points: [CGPoint] = []
        points.reserveCapacity(2 * (steps + bellySteps) + 2)
        func push(side: CGFloat, _ fy: CGFloat) {
            let x = rect.midX + side * bodyHalfWidth(atY: fy, in: rect) * u
            points.append(CGPoint(x: x, y: rect.minY + fy * rect.height))
        }
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            push(side: 1, 0.010 + (bellyCentreY - 0.010) * t)
        }
        for i in 1...bellySteps {
            let angle = (CGFloat(i) / CGFloat(bellySteps)) * .pi / 2
            push(side: 1, bellyCentreY + bellyRise * sin(angle))
        }
        for i in stride(from: bellySteps - 1, through: 1, by: -1) {
            let angle = (CGFloat(i) / CGFloat(bellySteps)) * .pi / 2
            push(side: -1, bellyCentreY + bellyRise * sin(angle))
        }
        for i in stride(from: steps, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            push(side: -1, 0.010 + (bellyCentreY - 0.010) * t)
        }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    // MARK: The four strings

    /// Half-spread of the four strings, as a fraction of unit. The strings
    /// leave the 山口 close together and open out a little towards the 覆手,
    /// exactly as on the real instrument: 缠弦 sets the left edge and the
    /// other three keep the same order and the same spacing all the way
    /// down, so no string can drift away from the frets.
    static let nutHalfSpread: CGFloat = 0.036
    static let bridgeHalfSpread: CGFloat = 0.053

    /// x of one string at a given height: the strings form a straight, shallow
    /// fan from the nut to the bridge. String 0 (缠弦) is the leftmost,
    /// string 3 (子弦) the rightmost.
    static func stringX(_ string: Int, atY y: CGFloat, in rect: CGRect) -> CGFloat {
        let nut = nutY(in: rect)
        let bridge = bridgeY(in: rect)
        let t = min(1.0, max(0.0, (y - nut) / (bridge - nut)))
        let half = (nutHalfSpread + (bridgeHalfSpread - nutHalfSpread) * t) * unit(in: rect)
        let u = CGFloat(string) / CGFloat(stringCount - 1)
        return rect.midX + (u * 2 - 1) * half
    }

    /// y of one stop position on a string. Position 0 sits at the nut, the
    /// open string; each step above it moves toward the bridge.
    static func positionY(_ position: Int, in rect: CGRect) -> CGFloat {
        let nut = nutY(in: rect)
        let length = bridgeY(in: rect) - nut
        return nut + length * (1.0 - lengthFraction(position))
    }

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

    /// Positions 1 to 6 are the xiang on the neck; 7 and above are the frets
    /// on the soundboard.
    static func isXiang(_ position: Int) -> Bool {
        position >= 1 && position <= PipaTuning.xiangCount
    }

    /// Half-length of one stop bar, as a fraction of unit.
    ///
    /// Measured off the real instrument: the six xiang span the slim neck
    /// and overhang it a little, and the twenty-five frets form a ladder of
    /// nearly constant length that starts wide at the top of the fingerboard
    /// and tapers towards its lower end. Because the soundboard widens as the
    /// frets descend, the frets cover less and less of the body — which is
    /// why the low ones stop well short of the binding.
    static func stopBarHalfWidth(_ position: Int) -> CGFloat {
        if isXiang(position) { return 0.105 }
        let fretNumber = position - PipaTuning.xiangCount   // 品1 = 1
        let total = positionCount - PipaTuning.xiangCount   // 25 品
        let t = CGFloat(fretNumber - 1) / CGFloat(total - 1)
        return 0.127 - 0.069 * t
    }

    // MARK: Hardware shapes

    /// 覆手, the bridge the strings rest on near the bottom of the board. Wide
    /// enough to seat the full string fan.
    static func bridgePath(in rect: CGRect) -> Path {
        let u = unit(in: rect)
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * u, y: rect.minY + fy * rect.height)
        }
        var path = Path()
        path.move(to: p(-0.070, bridgeFraction - 0.010))
        path.addLine(to: p(0.070, bridgeFraction - 0.010))
        path.addLine(to: p(0.086, bridgeFraction + 0.026))
        path.addLine(to: p(-0.086, bridgeFraction + 0.026))
        path.closeSubpath()
        return path
    }

    /// Fixed wood grain, so the texture is deterministic across runs. Each
    /// entry is start, control and end of one quadratic curve.
    static func grainPaths(in rect: CGRect) -> [Path] {
        let u = unit(in: rect)
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * u, y: rect.minY + fy * rect.height)
        }
        let strokes: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (-0.200, 0.260, -0.080, 0.500, -0.150, 0.800),
            ( 0.040, 0.250,  0.190, 0.480,  0.080, 0.740),
            (-0.030, 0.640, -0.190, 0.740, -0.060, 0.910),
            ( 0.180, 0.380,  0.240, 0.600,  0.110, 0.860),
            (-0.250, 0.420, -0.270, 0.660, -0.210, 0.850),
            ( 0.060, 0.840,  0.150, 0.900,  0.050, 0.960),
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
        let u = unit(in: rect)
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + fx * u, y: rect.minY + fy * rect.height)
        }
        return [p(-0.055, 0.120), p(-0.055, 0.180),
                p(0.055, 0.120), p(0.055, 0.180)]
    }

    // MARK: Hit testing

    /// Nearest stop position to a point in board coordinates, or nil when the
    /// point is too far from any string to count as a touch on it. The string
    /// x is measured at the touch height, since the strings fan out towards
    /// the bridge.
    static func nearest(location: CGPoint, in rect: CGRect) -> (string: Int, fret: Int)? {
        let u = unit(in: rect)
        var bestString = -1
        var bestDX = CGFloat.infinity
        for string in 0..<stringCount {
            let x = stringX(string, atY: location.y, in: rect)
            let distance = abs(location.x - x)
            if distance < bestDX {
                bestDX = distance
                bestString = string
            }
        }
        guard bestString >= 0, bestDX < u * 0.040 else { return nil }
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
