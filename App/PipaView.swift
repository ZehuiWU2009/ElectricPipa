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
    /// `stringVib` is the decaying envelope (1 → 0), `stringSwing` the fast
    /// oscillation phase (0 → 1, repeated), `stringDir` the initial swing side.
    @State private var stringVib: [CGFloat] = [0, 0, 0, 0]
    @State private var stringSwing: [CGFloat] = [0, 0, 0, 0]
    @State private var stringDir: [Double] = [1, 1, 1, 1]

    var body: some View {
        VStack(spacing: 12) {
            header
            PipaBoardView(selection: $selection, litCell: $litCell,
                          stringVib: $stringVib, stringSwing: $stringSwing, stringDir: $stringDir) { string, fret, position in
                play(string: string, fret: fret, position: position)
            } onStrum: { ascending in
                strumAndAnimate(ascending: ascending)
            }
            techniqueButtons
            sliders
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
            techniqueButton("拂弦 ↗") { strumAndAnimate(ascending: true) }
            techniqueButton("扫弦 ↘") { strumAndAnimate(ascending: false) }
            techniqueButton("轮指") { wheelAndAnimate() }
            techniqueButton("弹挑") { tanTiaoAndAnimate() }
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

    private func labelledSlider<T>(_ title: String, value: Binding<T>, range: ClosedRange<T>,
                               format: @escaping (T) -> String) -> some View
        where T: BinaryFloatingPoint, T.Stride: BinaryFloatingPoint {
        HStack {
            Text(title).font(.subheadline).foregroundColor(.white.opacity(0.8)).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).accentColor(.orange)
            Text(format(value.wrappedValue)).font(.caption).foregroundColor(.white.opacity(0.6)).frame(width: 44)
        }
    }

    /// Trigger one pluck from the main thread and light the matching position
    /// for the animation. The excitation point follows the finger position on
    /// the string.
    private func play(string: Int, fret: Int, position: Double) {
        audio.pluck(string: string, fret: fret, velocity: 0.85, position: position)
        selection = (string, fret)
        litCell = (string, fret)
        kick(string: string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if litCell?.string == string, litCell?.fret == fret { litCell = nil }
        }
    }

    /// Set a string swinging. The envelope decays from 1 to 0 over `duration`,
    /// while a fast oscillation phase repeats, so the string looks like it was
    /// plucked and is ringing out. `dir` is the initial swing side.
    private func kick(string: Int, dir: Double = 1, duration: Double = 0.45) {
        guard string >= 0, string < stringVib.count else { return }
        stringDir[string] = dir
        stringVib[string] = 1          // snap to full amplitude, no animation
        stringSwing[string] = 0
        let swings = max(2, Int(duration / 0.20))
        withAnimation(.easeOut(duration: duration)) { stringVib[string] = 0 }
        withAnimation(.linear(duration: 0.10).repeatCount(swings, autoreverses: true)) {
            stringSwing[string] = 1
        }
    }

    /// Strum across the four strings, with the animation following the audio
    /// order and spacing so the strings light up in sequence.
    private func strumAndAnimate(ascending: Bool) {
        audio.strum(ascending: ascending)
        let order = ascending ? [0, 1, 2, 3] : [3, 2, 1, 0]
        let dir = ascending ? 1.0 : -1.0
        for (index, s) in order.enumerated() {
            let offset = 0.022 * Double(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                kick(string: s, dir: dir, duration: 0.4)
            }
        }
    }

    /// Wheel (轮指): a single string kept ringing for the tremolo duration.
    private func wheelAndAnimate() {
        audio.tremolo(string: selection.string, fret: selection.fret, rate: 9, duration: 1.8)
        kick(string: selection.string, dir: 1, duration: 1.8)
    }

    /// Tan-Tiao (弹挑): one string struck outward then inward, quick and
    /// reversed, so the string visibly snaps back and forth.
    private func tanTiaoAndAnimate() {
        audio.tanTiao(string: selection.string, fret: selection.fret)
        kick(string: selection.string, dir: 1, duration: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.085) {
            kick(string: selection.string, dir: -1, duration: 0.35)
        }
    }
}

struct PipaView_Previews: PreviewProvider {
    static var previews: some View {
        PipaView().environmentObject(AudioEngine())
    }
}
