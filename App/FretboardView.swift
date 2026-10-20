import SwiftUI

struct StringVib {
    var start: Date? = nil
    var dur: Double = 0.45
    var dir: Double = 1
    var freq: Double = 9
    var fret: Int = 0
}
struct SlashState {
    var points: [(string: Int, fret: Int)] = []
    var start: Date = .distantPast
    static let totalDuration: Double = 0.5
}
struct BurstSignal: Equatable {
    var token: Int = 0
    var string: Int = 0
    var fret: Int = 0
}

/// The photographic instrument, animated strings and touch regions share one
/// fitted image rectangle, including its transparent margins.
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
                            if strength > 0 {
                                let y = PipaGeometry.positionY(state.fret, in: rect)
                                let x = PipaGeometry.stringX(string, atY: y, in: rect)
                                let circle = Path(ellipseIn: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
                                canvas.fill(circle, with: .color(PipaPalette.gold.opacity(strength * 0.3)))
                            }
                        }
                    }
                }
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
}
