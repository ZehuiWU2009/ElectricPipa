import SwiftUI

/// Live vibration of one string, owned by the parent and shared here.
///
/// Instead of animating array entries with `withAnimation`, the board reads
/// `start` (when the string was last struck) and derives the amplitude from the
/// live clock inside a `TimelineView`, so the vibration is always visible and
/// never depends on animation transaction timing.
struct StringVib {
    var start: Date? = nil     // nil = silent
    var dur: Double = 0.45     // decay time in seconds
    var dir: Double = 1        // initial swing side
    var freq: Double = 9       // oscillation frequency in Hz
    var fret: Int = 0          // where the glow should sit
}

/// A fruit-ninja style curved blade arcing across the four strings, used by
/// sao (扫弦) and fu (拂弦).
///
/// The blade follows the player's first touch: it passes through four
/// consecutive stop positions — one per string, each one semitone (one fret)
/// higher than the last — so the sweep starts at the exact 品 the finger landed
/// on and rises up the neck as it crosses to the last string. Sao arcs from the
/// Chan string (缠弦, leftmost) to the Zi string (子弦, rightmost); fu arcs the
/// other way. The board resolves each stop position to real coordinates.
struct SlashState {
    /// The four (string, fret) points the blade must pass through, in the order
    /// the strings are struck.
    var points: [(string: Int, fret: Int)] = []
    var start: Date = .distantPast

    /// The blade travels along the arc, holds a beat, then fades.
    static let travel: Double = 0.20
    static let hold: Double = 0.06
    static let fade: Double = 0.24
    static var totalDuration: Double { travel + hold + fade }
}

/// A one-shot signal asking the board to throw a particle burst at a fret.
struct BurstSignal: Equatable {
    var token: Int = 0
    var string: Int = 0
    var fret: Int = 0
}

/// One glowing particle.
private struct Spark: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let birth: Date
    let life: Double
    let angle: Double
    let color: Color
}

/// The instrument panel: a vector-drawn Pipa you actually touch.
///
/// The board is a half-pear soundboard with wood grain, four strings running
/// from the nut to the bridge, six xiang on the neck and twenty-five frets on
/// the soundboard, every stop position placed where the sounding length of the
/// string is 2^(-n/12) of the open length, exactly as on the real instrument.
///
/// Touch the board anywhere near a string and the nearest stop position
/// sounds, so the finger lands where the note is rather than on a grid cell.
/// Drag sideways across the strings to strum.
///
/// The four strings carry a live vibration animation driven by `vib`, and the
/// strokes add two more layers: a fruit-ninja blade slicing horizontally
/// across the strings on sao/fu, and glowing particles plus a fret halo on
/// wheel and tan-tiao. The string and effect layers are clipped to the
/// instrument silhouette, so nothing can ever be drawn off the body.
struct PipaBoardView: View {
    @EnvironmentObject private var audio: AudioEngine

    @Binding var selection: (string: Int, fret: Int)
    @Binding var litCell: (string: Int, fret: Int)?

    /// Vibration state for each string, owned by the parent and shared here.
    @Binding var vib: [StringVib]
    /// Slash blade state (read only while it is alive).
    @Binding var slash: SlashState?
    /// Particle burst trigger.
    @Binding var burst: BurstSignal

    /// Called with the string, the stop position and the excitation point
    /// along the string, so the pluck position follows the finger.
    let onPluck: (Int, Int, Double) -> Void
    /// Called when the user sweeps across the strings. The Bool is the sweep
    /// direction (true = left to right, i.e. 扫弦 / sao); the optional tuple is
    /// the first stop position the finger landed on, which sets the height of
    /// the sweep arc.
    let onStrum: (Bool, (string: Int, fret: Int)?) -> Void

    /// The stop position currently under the finger, highlighted while
    /// pressing and before the sound is committed.
    @State private var pressing: (string: Int, fret: Int)? = nil
    /// The first stop position touched in this gesture, used as the sweep's
    /// starting height.
    @State private var firstTouch: (string: Int, fret: Int)? = nil
    /// Live particle pool.
    @State private var sparks: [Spark] = []

    /// String gauges: the Chan string is thickest, the Zi string thinnest.
    private let stringWidth: [CGFloat] = [2.6, 2.1, 1.6, 1.1]
    /// How far the mid-point of a string swings at full amplitude. Kept
    /// below half the distance between two strings so the vibrating strings
    /// never cross each other.
    private let swingAmplitude: CGFloat = 8

    /// Palette matched to the real instrument in the owner's photos: a pale
    /// paulownia soundboard, dark rosewood binding, ivory frets, dark xiang
    /// and pegs, and a cream bridge.
    private let boardLight = Color(red: 0.93, green: 0.90, blue: 0.82)
    private let boardMid = Color(red: 0.89, green: 0.85, blue: 0.74)
    private let boardDeep = Color(red: 0.84, green: 0.79, blue: 0.66)
    private let bindingDark = Color(red: 0.30, green: 0.12, blue: 0.08)
    private let bindingEdge = Color(red: 0.18, green: 0.07, blue: 0.04)
    private let rosewood = Color(red: 0.33, green: 0.14, blue: 0.09)
    private let rosewoodDeep = Color(red: 0.22, green: 0.09, blue: 0.05)
    private let xiangColor = Color(red: 0.26, green: 0.11, blue: 0.07)
    private let fretIvory = Color(red: 0.87, green: 0.82, blue: 0.66)
    private let fretIvoryEdge = Color(red: 0.62, green: 0.54, blue: 0.38)
    private let boneColor = Color(red: 0.94, green: 0.92, blue: 0.84)
    private let stringLight = Color(red: 0.94, green: 0.94, blue: 0.96)
    private let stringDark = Color(red: 0.60, green: 0.60, blue: 0.65)

    var body: some View {
        GeometryReader { geo in
            let rect = geo.frame(in: .local)
            ZStack {
                soundboard(in: rect)
                hardware(in: rect)
                strings(in: rect)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .clipShape(PipaGeometry.bodyPath(in: rect))
                effects(in: rect)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .clipShape(PipaGeometry.bodyPath(in: rect))
                stopPositions(in: rect)
            }
            .onChange(of: burst.token) { _, _ in
                guard burst.token > 0 else { return }
                spawnSparks(in: rect)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let hit = PipaGeometry.nearest(location: value.location, in: rect)
                        if pressing == nil {
                            // First contact of this gesture: remember it so the
                            // sweep arc starts at the player's chosen height.
                            firstTouch = hit
                        }
                        pressing = hit
                    }
                    .onEnded { value in
                        let translation = value.translation
                        let starter = firstTouch
                        pressing = nil
                        firstTouch = nil
                        if abs(translation.width) < 14, abs(translation.height) < 14 {
                            // A tap: sound the nearest stop position and use
                            // the touch point as the excitation point.
                            if let hit = PipaGeometry.nearest(location: value.location, in: rect) {
                                onPluck(hit.string, hit.fret,
                                        PipaGeometry.pluckPosition(value.location, in: rect))
                            }
                        } else if abs(translation.width) > abs(translation.height) {
                            onStrum(translation.width > 0, starter)
                        }
                    }
            )
        }
    }

    // MARK: - The soundboard

    private func soundboard(in rect: CGRect) -> some View {
        let body = PipaGeometry.bodyPath(in: rect)
        let grain = PipaGeometry.grainPaths(in: rect)
        return ZStack {
            // Pale paulownia face, warm cream as in the photos.
            body.fill(
                LinearGradient(colors: [boardLight, boardMid, boardDeep],
                               startPoint: .top, endPoint: .bottom)
            )
            // Sheen across the arched face
            body.fill(
                LinearGradient(colors: [.clear, Color.white.opacity(0.16), .clear],
                               startPoint: .leading, endPoint: .trailing)
            )
            // Pale vertical grain, clipped to the board
            ForEach(0..<grain.count, id: \.self) { index in
                grain[index]
                    .stroke(Color(red: 0.66, green: 0.58, blue: 0.42).opacity(0.28), lineWidth: 1.0)
            }
            .clipShape(body)
            // Dark rosewood binding around the face, with a deeper outer edge
            body.stroke(bindingDark, lineWidth: 5)
            body.stroke(bindingEdge, lineWidth: 1.5)
        }
    }

    // MARK: - Nut, xiang, frets, bridge, pegs

    private func hardware(in rect: CGRect) -> some View {
        let nutY = PipaGeometry.nutY(in: rect)
        let bridgeY = PipaGeometry.bridgeY(in: rect)
        let u = PipaGeometry.unit(in: rect)
        return ZStack {
            // 琴头: the dark head plate above the nut, crowned with the carved
            // ivory flower seen on the real instrument.
            headPlate(in: rect)
            // 山口: a dark rosewood bar spanning the string fan at the nut.
            fretLine(x1: PipaGeometry.stringX(0, atY: nutY, in: rect) - u * 0.013,
                     y: nutY,
                     x2: PipaGeometry.stringX(PipaGeometry.stringCount - 1, atY: nutY, in: rect) + u * 0.013,
                     width: 4.5, color: rosewoodDeep)
            // 相 on the neck: dark rosewood, spanning the slim neck and
            // overhanging it a little. 品 on the soundboard: ivory bamboo
            // bars of the measured length, which start wide at the top of the
            // fingerboard and taper towards its lower end, so the low frets
            // stop well short of the binding.
            ForEach(1..<PipaGeometry.positionCount, id: \.self) { position in
                let xiang = PipaGeometry.isXiang(position)
                let y = PipaGeometry.positionY(position, in: rect)
                let half = PipaGeometry.stopBarHalfWidth(position) * u
                if xiang {
                    fretLine(x1: rect.midX - half, y: y,
                             x2: rect.midX + half,
                             width: 5.5, color: xiangColor)
                } else {
                    fretLine(x1: rect.midX - half, y: y + 1.2,
                             x2: rect.midX + half,
                             width: 1.2, color: fretIvoryEdge.opacity(0.45))
                    fretLine(x1: rect.midX - half, y: y,
                             x2: rect.midX + half,
                             width: 3.4, color: fretIvory)
                }
            }
            // 覆手: cream wood with the two dark string-holes of the real bridge.
            PipaGeometry.bridgePath(in: rect)
                .fill(LinearGradient(colors: [fretIvory, Color(red: 0.78, green: 0.71, blue: 0.52)],
                                     startPoint: .top, endPoint: .bottom))
            PipaGeometry.bridgePath(in: rect)
                .stroke(Color(red: 0.45, green: 0.36, blue: 0.22), lineWidth: 1)
            Circle()
                .fill(rosewoodDeep)
                .frame(width: 4, height: 4)
                .position(x: rect.midX - u * 0.035, y: bridgeY + rect.height * 0.006)
            Circle()
                .fill(rosewoodDeep)
                .frame(width: 4, height: 4)
                .position(x: rect.midX + u * 0.035, y: bridgeY + rect.height * 0.006)
            // 轸子: dark rosewood pegs sticking out of the head, each tipped
            // with bone as in the photos.
            let pegs = PipaGeometry.pegPoints(in: rect)
            ForEach(0..<pegs.count, id: \.self) { index in
                pegView(at: pegs[index], in: rect)
            }
        }
    }

    /// The head plate and its carved ivory flower.
    private func headPlate(in rect: CGRect) -> some View {
        let u = PipaGeometry.unit(in: rect)
        let flowerR = u * 0.058
        let flowerCenter = CGPoint(x: rect.midX, y: rect.minY + 0.085 * rect.height)
        return ZStack {
            // Dark plate behind the pegbox
            RoundedRectangle(cornerRadius: u * 0.026)
                .fill(LinearGradient(colors: [rosewood, rosewoodDeep],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: u * 0.136, height: rect.height * 0.130)
                .position(x: rect.midX, y: rect.minY + 0.090 * rect.height)
            // Carved flower: a bone disc with six petals and a centre bud
            Circle()
                .fill(boneColor)
                .frame(width: flowerR * 2, height: flowerR * 2)
                .position(flowerCenter)
                .shadow(color: .black.opacity(0.35), radius: 2)
            ForEach(0..<6, id: \.self) { petal in
                let angle = Double(petal) / 6.0 * 2 * .pi
                Circle()
                    .fill(Color(red: 0.86, green: 0.82, blue: 0.70))
                    .frame(width: flowerR * 1.05, height: flowerR * 1.05)
                    .position(x: flowerCenter.x + CGFloat(cos(angle)) * flowerR * 0.62,
                              y: flowerCenter.y + CGFloat(sin(angle)) * flowerR * 0.62)
                    .blendMode(.multiply)
            }
            Circle()
                .fill(Color(red: 0.80, green: 0.74, blue: 0.58))
                .frame(width: flowerR * 0.8, height: flowerR * 0.8)
                .position(flowerCenter)
                .blendMode(.multiply)
        }
    }

    /// One tuning peg: a tapered rosewood rod running outward from the head,
    /// ending in a small bone tip.
    private func pegView(at peg: CGPoint, in rect: CGRect) -> some View {
        let u = PipaGeometry.unit(in: rect)
        let length = u * 0.115
        let isLeft = peg.x < rect.midX
        let innerX = isLeft ? rect.midX + u * 0.048 : rect.midX - u * 0.048
        let outerX = isLeft ? innerX - length : innerX + length
        return ZStack {
            Capsule()
                .fill(LinearGradient(colors: [rosewood, rosewoodDeep],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: abs(outerX - innerX), height: 7.5)
                .position(x: (innerX + outerX) / 2, y: peg.y)
            // Spiral ridges, hinted with two darker bands
            ForEach(1...2, id: \.self) { band in
                Capsule()
                    .fill(rosewoodDeep.opacity(0.7))
                    .frame(width: 3, height: 7.5)
                    .position(x: innerX + (outerX - innerX) * CGFloat(band) / 3.0,
                              y: peg.y)
            }
            // Bone tip
            Circle()
                .fill(boneColor)
                .frame(width: 5.5, height: 5.5)
                .position(x: outerX, y: peg.y)
        }
    }

    private func fretLine(x1: CGFloat, y: CGFloat, x2: CGFloat,
                          width: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x2, y: y))
        }
        .stroke(color, lineWidth: width)
    }

    // MARK: - The four strings

    /// Amplitude (1 → 0) and oscillation phase for a string at a given time.
    /// Kept as a plain function so the timing math is never written inside a
    /// @ViewBuilder closure (which would reject a bare assignment).
    private func vibration(at now: Date, _ v: StringVib) -> (value: Double, phase: Double) {
        var value: Double = 0
        var phase: Double = 0
        if let start = v.start {
            let elapsed = now.timeIntervalSince(start)
            if elapsed >= 0, elapsed < v.dur {
                value = 1 - elapsed / v.dur
                phase = elapsed * v.freq
            }
        }
        return (value, phase)
    }

    /// Vibrating strings, redrawn every frame from the live clock so the
    /// motion is always smooth and visible. The strings converge like the
    /// real ones — closer at the 山口, wider at the 覆手 — and both ends are
    /// pinned by the mode envelope, so each string always lands exactly on
    /// its nut notch and its bridge seat.
    private func strings(in rect: CGRect) -> some View {
        let nutY = PipaGeometry.nutY(in: rect)
        let bridgeY = PipaGeometry.bridgeY(in: rect)
        return TimelineView(.animation) { ctx in
            let now = ctx.date
            ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
                let amp = Double(swingAmplitude)
                let v = vib[string]
                let res = vibration(at: now, v)
                let vibValue = res.value
                let phase = res.phase
                let dir = v.dir
                Path { path in
                    let segments = 26
                    for i in 0...segments {
                        let t = Double(i) / Double(segments)
                        let y = nutY + (bridgeY - nutY) * CGFloat(t)
                        let x = PipaGeometry.stringX(string, atY: y, in: rect)
                        // Fixed ends, largest swing at the middle of the string.
                        let envelope = sin(.pi * t)
                        let osc = sin(2 * .pi * phase)
                        let displacement = vibValue * dir * amp * envelope * osc
                        let px = x + CGFloat(displacement)
                        if i == 0 {
                            path.move(to: CGPoint(x: px, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: px, y: y))
                        }
                    }
                }
                .stroke(LinearGradient(colors: [stringLight, stringDark],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: stringWidth[string])
            }
        }
    }

    // MARK: - Effects (slash, fret glow, particles)

    private func effects(in rect: CGRect) -> some View {
        return TimelineView(.animation) { ctx in
            let now = ctx.date
            ZStack {
                fretGlow(now: now, in: rect)
                if let s = slash, now.timeIntervalSince(s.start) < SlashState.totalDuration {
                    slashLayer(s, now: now, in: rect)
                }
                particlesLayer(now: now, in: rect)
            }
        }
    }

    /// Soft halo on the fret of every string that is currently ringing.
    private func fretGlow(now: Date, in rect: CGRect) -> some View {
        ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
            let v = vib[string]
            let value = vibration(at: now, v).value
            if value > 0.01 {
                let point = CGPoint(x: PipaGeometry.stringX(string, atY: PipaGeometry.positionY(v.fret, in: rect), in: rect),
                                    y: PipaGeometry.positionY(v.fret, in: rect))
                Circle()
                    .fill(RadialGradient(colors: [Color.orange.opacity(0.85 * value),
                                                  Color.orange.opacity(0)],
                                        center: .center, startRadius: 1, endRadius: 30))
                    .frame(width: 60, height: 60)
                    .position(point)
                    .blur(radius: 3)
            }
        }
    }

    /// A fruit-ninja blade arcing smoothly through the four stop positions of
    /// the sweep. The blade leaves a glowing trail, a bright tip and a white
    /// flash where it crosses each string. The trail is a Catmull-Rom curve, so
    /// it bows into an arc instead of a stiff straight line.
    private func slashLayer(_ s: SlashState, now: Date, in rect: CGRect) -> some View {
        let pts = s.points.map {
            let y = PipaGeometry.positionY($0.fret, in: rect)
            return CGPoint(x: PipaGeometry.stringX($0.string, atY: y, in: rect),
                           y: y)
        }
        let samples = pts.count >= 2 ? catmullRomSamples(pts, perSeg: 18) : []
        let elapsed = now.timeIntervalSince(s.start)
        let p = min(1.0, max(0.0, elapsed / SlashState.travel))
        let tip = slashTip(samples, fraction: p)
        let trail = slashTrailPath(samples, fraction: p)
        let over = elapsed - SlashState.travel - SlashState.hold
        let fade = over <= 0 ? 1.0 : max(0.0, 1.0 - over / SlashState.fade)
        return ZStack {
            // Soft outer glow of the trail (warm, so it reads on pale wood)
            trail.stroke(Color.orange.opacity(0.30), lineWidth: 18).blur(radius: 9)
            // Mid glow
            trail.stroke(Color.orange.opacity(0.80), lineWidth: 7).blur(radius: 2.5)
                .shadow(color: .orange, radius: 6)
            // Bright core
            trail.stroke(Color.white.opacity(0.95), lineWidth: 3)
            // Blade tip
            Circle().fill(Color.white).frame(width: 9, height: 9).position(tip).blur(radius: 0.8)
            // A flash where the edge crosses each stop position
            ForEach(0..<pts.count, id: \.self) { idx in
                let u = Double(idx) / Double(pts.count - 1)
                let age = elapsed - u * SlashState.travel
                if age >= 0, age < 0.16 {
                    let e = age / 0.16
                    Circle()
                        .fill(RadialGradient(colors: [Color.white.opacity(0.9 * (1 - e)),
                                                      Color.clear],
                                             center: .center, startRadius: 1, endRadius: 24))
                        .frame(width: 50, height: 50)
                        .position(pts[idx])
                }
            }
        }
        .opacity(fade)
        .allowsHitTesting(false)
    }

    /// Catmull-Rom samples through the given control points — a smooth arc that
    /// passes exactly through every point.
    private func catmullRomSamples(_ pts: [CGPoint], perSeg: Int) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        let ext = [pts[0]] + pts + [pts.last!]
        var out: [CGPoint] = []
        for i in 1..<ext.count - 2 {
            let p0 = ext[i - 1], p1 = ext[i], p2 = ext[i + 1], p3 = ext[i + 2]
            for s in 0..<perSeg {
                let t = Double(s) / Double(perSeg)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t
                    + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                    + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t
                    + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                    + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)
                out.append(CGPoint(x: x, y: y))
            }
        }
        out.append(pts.last!)
        return out
    }

    /// Point at a fraction (0…1) along the sampled curve.
    private func slashTip(_ samples: [CGPoint], fraction: CGFloat) -> CGPoint {
        guard samples.count > 1 else { return samples.first ?? .zero }
        let total = Double(samples.count - 1)
        let pos = min(1.0, max(0.0, fraction)) * total
        let full = Int(floor(pos))
        let frac = pos - Double(full)
        if full >= samples.count - 1 { return samples.last! }
        let a = samples[full], b = samples[full + 1]
        return CGPoint(x: a.x + (b.x - a.x) * CGFloat(frac),
                       y: a.y + (b.y - a.y) * CGFloat(frac))
    }

    /// The glowing trail of the blade: the curve from the first point up to the
    /// current tip.
    private func slashTrailPath(_ samples: [CGPoint], fraction: CGFloat) -> Path {
        var path = Path()
        guard samples.count > 1 else {
            if let f = samples.first { path.move(to: f) }
            return path
        }
        let total = Double(samples.count - 1)
        let pos = min(1.0, max(0.0, fraction)) * total
        let full = Int(floor(pos))
        path.move(to: samples[0])
        if full >= 1 {
            for i in 1...full { path.addLine(to: samples[i]) }
        }
        if full < samples.count - 1 {
            let frac = CGFloat(pos - Double(full))
            let a = samples[full], b = samples[full + 1]
            path.addLine(to: CGPoint(x: a.x + (b.x - a.x) * frac,
                                     y: a.y + (b.y - a.y) * frac))
        }
        return path
    }

    /// Glowing particles thrown by wheel and tan-tiao bursts.
    private func particlesLayer(now: Date, in rect: CGRect) -> some View {
        ForEach(sparks) { spark in
            let age = now.timeIntervalSince(spark.birth)
            if age < spark.life {
                let k = age / spark.life
                let dist = CGFloat(k) * 30
                let px = spark.x + CGFloat(cos(spark.angle)) * dist
                let py = spark.y + CGFloat(sin(spark.angle)) * dist - CGFloat(k) * 10
                let r = CGFloat((1 - k) * 3 + 1)
                Circle()
                    .fill(spark.color.opacity(1 - k))
                    .frame(width: r * 2, height: r * 2)
                    .position(x: px, y: py)
                    .blur(radius: 1.2)
            }
        }
    }

    private func spawnSparks(in rect: CGRect) {
        let y = PipaGeometry.positionY(burst.fret, in: rect)
        let point = CGPoint(x: PipaGeometry.stringX(burst.string, atY: y, in: rect),
                            y: y)
        for i in 0..<14 {
            let a = Double(i) / 14.0 * 2 * .pi + Double.random(in: -0.35...0.35)
            sparks.append(Spark(x: point.x, y: point.y, birth: Date(), life: 0.6,
                                angle: a, color: .orange))
        }
        if sparks.count > 320 { sparks.removeFirst(sparks.count - 320) }
    }

    // MARK: - Stop positions

    private func stopPositions(in rect: CGRect) -> some View {
        ForEach(0..<PipaGeometry.stringCount, id: \.self) { string in
            ForEach(0..<PipaGeometry.positionCount, id: \.self) { fret in
                let y = PipaGeometry.positionY(fret, in: rect)
                let point = CGPoint(x: PipaGeometry.stringX(string, atY: y, in: rect),
                                    y: y)
                let isSelected = selection.string == string && selection.fret == fret
                let isLit = litCell?.string == string && litCell?.fret == fret
                let isPressing = pressing?.string == string && pressing?.fret == fret
                // Dark wood dots, visible on the pale soundboard.
                Circle()
                    .fill(isLit ? Color.orange
                                : Color(red: 0.32, green: 0.16, blue: 0.08)
                                      .opacity(isPressing ? 0.95 : isSelected ? 0.75 : 0.45))
                    .frame(width: isLit || isPressing ? 9 : 5,
                           height: isLit || isPressing ? 9 : 5)
                    .overlay(
                        Circle()
                            .stroke(Color.orange.opacity(isSelected ? 0.85 : 0), lineWidth: 1.2)
                    )
                    .shadow(color: isLit ? Color.orange.opacity(0.8) : .clear, radius: isLit ? 5 : 0)
                    .position(point)
                    .animation(.easeOut(duration: 0.18), value: isLit)
            }
        }
    }
}

struct PipaBoardView_Previews: PreviewProvider {
    static var previews: some View {
        PipaBoardView(selection: .constant((3, 7)), litCell: .constant(nil),
                      vib: .constant(Array(repeating: StringVib(), count: 4)),
                      slash: .constant(nil),
                      burst: .constant(BurstSignal())) { _, _, _ in }
            onStrum: { _, _ in }
            .environmentObject(AudioEngine())
            .preferredColorScheme(.dark)
    }
}
