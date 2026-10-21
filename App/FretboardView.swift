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

/// The photographic instrument, animated strings and touch regions share one
/// fitted image rectangle, including its transparent margins.
///
/// On top of the strings two effect layers run: a fruit-ninja blade slicing
/// across the strings on sao/fu, and glowing particles with a fret halo on
/// wheel and tan-tiao. Both resolve their stop positions through the same
/// `PipaGeometry` the board draws with, so every flash lands on the string it
/// belongs to.
struct PipaBoardView: View {
    @Binding var selection: (string: Int, fret: Int)
    @Binding var litCell: (string: Int, fret: Int)?
    @Binding var vib: [StringVib]
    @Binding var slash: SlashState?
    @Binding var burst: BurstSignal
    let onPluck: (Int, Int, Double) -> Void
    let onStrum: (Bool, (string: Int, fret: Int)?) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressing: (string: Int, fret: Int)?
    @State private var firstTouch: (string: Int, fret: Int)?
    /// Live particle pool.
    @State private var sparks: [Spark] = []

    var body: some View {
        GeometryReader { geo in
            let rect = PipaGeometry.instrumentRect(in: CGRect(origin: .zero, size: geo.size))
            ZStack(alignment: .topLeading) {
                Image("PipaInstrument")
                    .resizable()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .shadow(color: PipaPalette.ink.opacity(0.12), radius: 12, x: 3, y: 8)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                    Canvas { canvas, _ in
                        for string in 0..<4 {
                            let state = vib[string]
                            let elapsed = state.start.map { context.date.timeIntervalSince($0) } ?? 100
                            let strength = max(0, 1 - elapsed / max(state.dur, 0.01))
                            var path = Path()
                            for step in 0...48 {
                                let t = CGFloat(step) / 48
                                let y = PipaGeometry.nutY(in: rect) + t * (PipaGeometry.bridgeY(in: rect) - PipaGeometry.nutY(in: rect))
                                let sway = reduceMotion ? 0 : sin(elapsed * state.freq * 2 * .pi) * strength * state.dir * 2
                                let x = PipaGeometry.stringX(string, atY: y, in: rect) + CGFloat(sway) * sin(t * .pi)
                                if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
                                else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                            canvas.stroke(path, with: .color(Color(red: 0.42, green: 0.35, blue: 0.25).opacity(0.8)), lineWidth: CGFloat(4 - string) * 0.16 + 0.45)
                        }
                    }
                }
                effects(in: rect)
                let current = pressing ?? selection
                let y = PipaGeometry.positionY(current.fret, in: rect)
                let x = PipaGeometry.stringX(current.string, atY: y, in: rect)
                Circle().fill(PipaPalette.cinnabar)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    .position(x: x, y: y)
                    .allowsHitTesting(false)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onChange(of: burst.token) { _, _ in
                guard burst.token > 0 else { return }
                spawnSparks(in: rect)
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if firstTouch == nil {
                        firstTouch = PipaGeometry.nearest(location: value.startLocation, in: rect)
                    }
                    pressing = PipaGeometry.nearest(location: value.location, in: rect)
                }
                .onEnded { value in
                    let starter = firstTouch
                    firstTouch = nil
                    pressing = nil
                    if abs(value.translation.width) < 14, abs(value.translation.height) < 14 {
                        if let hit = PipaGeometry.nearest(location: value.location, in: rect) {
                            onPluck(hit.string, hit.fret, PipaGeometry.pluckPosition(value.location, in: rect))
                        }
                    } else if starter != nil, abs(value.translation.width) > abs(value.translation.height) {
                        onStrum(value.translation.width > 0, starter)
                    }
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("琵琶演奏区")
            .accessibilityHint("轻点演奏当前音位。使用音位面板可逐弦选择全部音位。")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onPluck(selection.string, selection.fret, 0.5) }
        }
    }

    // MARK: - Effects (slash, fret glow, particles)

    private func effects(in rect: CGRect) -> some View {
        TimelineView(.animation) { ctx in
            let now = ctx.date
            ZStack {
                fretGlow(now: now, in: rect)
                if let s = slash, now.timeIntervalSince(s.start) < SlashState.totalDuration {
                    slashLayer(s, now: now, in: rect)
                }
                sparksLayer(now: now)
            }
        }
        .allowsHitTesting(false)
    }

    /// Amplitude (1 → 0) and oscillation phase for a string at a given time.
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

    /// Soft halo on the fret of every string that is currently ringing.
    private func fretGlow(now: Date, in rect: CGRect) -> some View {
        ForEach(0..<4, id: \.self) { string in
            let v = vib[string]
            let value = vibration(at: now, v).value
            if value > 0.01 {
                let y = PipaGeometry.positionY(v.fret, in: rect)
                let point = CGPoint(x: PipaGeometry.stringX(string, atY: y, in: rect), y: y)
                Circle()
                    .fill(RadialGradient(colors: [PipaPalette.gold.opacity(0.85 * value),
                                                  PipaPalette.gold.opacity(0)],
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
            // Soft outer glow of the trail (warm, so it reads on dark wood)
            trail.stroke(PipaPalette.gold.opacity(0.30), lineWidth: 18).blur(radius: 9)
            // Mid glow
            trail.stroke(PipaPalette.gold.opacity(0.80), lineWidth: 7).blur(radius: 2.5)
                .shadow(color: PipaPalette.gold, radius: 6)
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
    private func sparksLayer(now: Date) -> some View {
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
                                angle: a, color: PipaPalette.gold))
        }
        if sparks.count > 320 { sparks.removeFirst(sparks.count - 320) }
    }
}
