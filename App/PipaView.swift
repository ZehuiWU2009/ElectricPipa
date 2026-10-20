import SwiftUI

/// Main screen of the electric Pipa: the instrument panel in the middle, a
/// row of technique buttons and timbre sliders below.
struct PipaView: View {
    @EnvironmentObject private var audio: AudioEngine

    /// Currently selected string and position; tremolo and damping act on it.
    @State private var selection: (string: Int, fret: Int) = (3, 7)
    /// The position just plucked, used for the highlight animation.
    @State private var litCell: (string: Int, fret: Int)? = nil

    /// Live vibration state shared with the board, one entry per string.
    /// `start` is when the string was last struck; the board derives the
    /// amplitude from the live clock, so the motion is always visible.
    @State private var vib: [StringVib] = Array(repeating: StringVib(), count: PipaGeometry.stringCount)
    /// Strum slash (fruit-ninja style) state.
    @State private var slash: SlashState? = nil
    /// Particle burst trigger for wheel and tan-tiao.
    @State private var burst = BurstSignal()

    /// Speed controls for the stroke techniques.
    @State private var tanTiaoBPM: Double = 120          // metronome BPM for tan-tiao
    @State private var wheelRate: Double = 9             // plucks per second

    var body: some View {
        VStack(spacing: 12) {
            header
            PipaBoardView(selection: $selection, litCell: $litCell,
                          vib: $vib, slash: $slash, burst: $burst) { string, fret, position in
                play(string: string, fret: fret, position: position)
            } onStrum: { rightward, starter in
                strumAndAnimate(sao: rightward, start: starter)
            }
            techniqueButtons
            sliders
            speedSliders
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(
            LinearGradient(colors: [Color(red: 0.09, green: 0.08, blue: 0.10),
                                    Color(red: 0.05, green: 0.04, blue: 0.06)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("电子琵琶")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Electric Pipa · 物理建模合成器")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(currentNoteDescription)
                    .font(.subheadline.bold())
                    .foregroundColor(.orange)
                HStack(spacing: 6) {
                    Circle()
                        .fill(audio.isRunning ? Color.green : Color.gray)
                        .frame(width: 9, height: 9)
                    Text(audio.isRunning ? "音频已启动" : "轻触琴弦开始")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }

    /// "子弦 · 品12 · E5" for the current selection.
    private var currentNoteDescription: String {
        let midi = PipaTuning.midi(string: selection.string, fret: selection.fret)
        return "\(PipaTuning.stringNames[selection.string]) · \(PipaTuning.positionName(selection.fret)) · \(PipaTuning.noteName(midi))"
    }

    private var techniqueButtons: some View {
        HStack(spacing: 10) {
            techniqueButton("弹挑") { tanTiaoAndAnimate() }
            techniqueButton("轮指") { wheelAndAnimate() }
            techniqueButton("扫弦 →") { strumAndAnimate(sao: true) }
            techniqueButton("拂弦 ←") { strumAndAnimate(sao: false) }
            techniqueButton("止音") { audio.dampAll() }
        }
    }

    private func techniqueButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.sRGB, red: 0.20, green: 0.22, blue: 0.32, opacity: 1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var sliders: some View {
        VStack(spacing: 12) {
            labelledSlider("音色明暗", value: $audio.brightness, range: 0.15...1.0,
                           format: { "\(Int($0 * 100))%" })
            labelledSlider("音量", value: $audio.masterGain, range: 0.0...1.0,
                           format: { "\(Int($0 * 100))%" })
        }
    }

    /// Speed of the two repeated strokes, so tan-tiao and wheel feel adjustable.
    private var speedSliders: some View {
        VStack(spacing: 12) {
            labelledSlider("弹挑速度", value: $tanTiaoBPM, range: 40...480,
                           format: { "\(Int($0)) BPM" })
            labelledSlider("轮指速率", value: $wheelRate, range: 4.0...16.0,
                           format: { "\(Int($0)) / 秒" })
        }
    }

    private func labelledSlider<T>(_ title: String, value: Binding<T>, range: ClosedRange<T>,
                               format: @escaping (T) -> String) -> some View
        where T: BinaryFloatingPoint, T.Stride: BinaryFloatingPoint {
        HStack {
            Text(title).font(.subheadline).foregroundColor(.white.opacity(0.8)).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).accentColor(.orange)
            Text(format(value.wrappedValue)).font(.caption).foregroundColor(.white.opacity(0.6)).frame(width: 56)
        }
    }

    /// Trigger one pluck from the main thread and light the matching position
    /// for the animation. The excitation point follows the finger position on
    /// the string.
    private func play(string: Int, fret: Int, position: Double) {
        audio.pluck(string: string, fret: fret, velocity: 0.85, position: position)
        selection = (string, fret)
        litCell = (string, fret)
        kick(string: string, fret: fret)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if litCell?.string == string, litCell?.fret == fret { litCell = nil }
        }
    }

    /// Strike a string: stamp its vibration start, which the board reads from
    /// the live clock. No `withAnimation` is needed.
    private func kick(string: Int, fret: Int, dir: Double = 1, duration: Double = 0.45, freq: Double = 9) {
        guard string >= 0, string < vib.count else { return }
        vib[string].fret = fret
        vib[string].dir = dir
        vib[string].dur = duration
        vib[string].freq = freq
        vib[string].start = Date()
    }

    /// Sao (扫弦) and Fu (拂弦). Both sweep across all four strings and play
    /// the same four notes — one stop position per string, each a semitone
    /// higher than the last — and they start from the position the player
    /// chose: the one their finger landed on in this drag, or the note that
    /// is currently selected.
    ///
    /// Sao runs 缠弦→子弦, that is left to right and down the board, and the
    /// blade sweeps from the upper left to the lower right. Fu runs the other
    /// way: 子弦→缠弦, from the lower right up to the upper left, over the
    /// very same four notes. The audio and the curved blade follow the same
    /// order, so each string sounds and glows exactly where the blade crosses
    /// it.
    private func strumAndAnimate(sao: Bool, start: (string: Int, fret: Int)? = nil) {
        let maxFret = PipaGeometry.positionCount - 1
        let origin = start ?? selection
        let f0 = min(max(origin.fret, 0), maxFret)
        let order = sao ? [0, 1, 2, 3] : [3, 2, 1, 0]
        let dir = sao ? 1.0 : -1.0
        var points: [(string: Int, fret: Int)] = []
        for (index, str) in order.enumerated() {
            // The same four notes in both directions: string k sits at f0 + k,
            // so 扫 climbs from 缠弦 to 子弦 and 拂 falls back from 子弦 to
            // 缠弦 — which is what makes the blade run from the lower right
            // up to the upper left.
            let fret = min(f0 + str, maxFret)
            points.append((string: str, fret: fret))
            let offset = 0.022 * Double(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                audio.pluck(string: str, fret: fret, velocity: 0.85, position: 0.5)
                kick(string: str, fret: fret, dir: dir, duration: 0.4)
            }
        }
        let s = SlashState(points: points, start: Date())
        slash = s
        DispatchQueue.main.asyncAfter(deadline: .now() + SlashState.totalDuration) {
            if slash?.start == s.start { slash = nil }
        }
    }

    /// Wheel (轮指): a single string kept ringing for the tremolo duration,
    /// with a particle burst at its fret.
    private func wheelAndAnimate() {
        audio.tremolo(string: selection.string, fret: selection.fret, rate: wheelRate, duration: 1.8)
        kick(string: selection.string, fret: selection.fret, duration: 1.8, freq: 7)
        burst = BurstSignal(token: burst.token + 1, string: selection.string, fret: selection.fret)
    }

    /// Tan-Tiao (弹挑): the string is struck outward then inward, again and
    /// again for five seconds. One metronome beat is one full 弹+挑 pair —
    /// two strokes — so at 120 BPM the string takes 240 strokes (120 pairs)
    /// per minute, and each stroke lands 30 / BPM seconds after the previous
    /// one. Each stroke throws a particle burst at its fret.
    private func tanTiaoAndAnimate() {
        let stroke = 30.0 / tanTiaoBPM
        let duration = 5.0
        audio.tanTiao(string: selection.string, fret: selection.fret,
                      interval: stroke, duration: duration)
        let strokes = max(1, Int(duration / stroke))
        for i in 0..<strokes {
            let offset = stroke * Double(i)
            let dir = (i % 2 == 0) ? 1.0 : -1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                kick(string: selection.string, fret: selection.fret, dir: dir,
                     duration: min(stroke * 0.9, 0.5), freq: 8)
                burst = BurstSignal(token: burst.token + 1,
                                   string: selection.string, fret: selection.fret)
            }
        }
    }
}

struct PipaView_Previews: PreviewProvider {
    static var previews: some View {
        PipaView().environmentObject(AudioEngine())
    }
}
