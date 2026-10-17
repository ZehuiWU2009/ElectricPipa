import SwiftUI

/// Main screen of the electric Pipa: string names on the left, a scrollable
/// position board on the right, and a row of technique buttons plus timbre
/// sliders below.
struct PipaView: View {
    @EnvironmentObject private var audio: AudioEngine

    /// Currently selected string and position; tremolo and damping act on it.
    @State private var selection: (string: Int, fret: Int) = (3, 7)
    /// The cell just plucked, used for the highlight animation.
    @State private var litCell: (string: Int, fret: Int)? = nil

    private let stringNames = ["缠弦", "老弦", "中弦", "子弦"]

    var body: some View {
        VStack(spacing: 14) {
            header
            FretboardView(selection: $selection, litCell: $litCell, onPluck: play)
            Divider().overlay(Color.white.opacity(0.15))
            techniqueButtons
            Divider().overlay(Color.white.opacity(0.15))
            sliders
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .background(Color(.sRGB, red: 0.07, green: 0.07, blue: 0.09, opacity: 1).ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("电子琵琶")
                    .font(.title2.bold())
                    .foregroundColor(.white)
                Text("Electric Pipa · 物理建模合成器")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(audio.isRunning ? Color.green : Color.gray)
                    .frame(width: 9, height: 9)
                Text(audio.isRunning ? "音频已启动" : "轻触指板开始")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var techniqueButtons: some View {
        HStack(spacing: 10) {
            techniqueButton("拂弦 ↗") { audio.strum(ascending: true) }
            techniqueButton("扫弦 ↘") { audio.strum(ascending: false) }
            techniqueButton("轮指") { audio.tremolo(string: selection.string, fret: selection.fret, rate: 9, duration: 1.8) }
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
                )
        }
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

    /// Trigger one pluck from the main thread and light the matching cell for
    /// the animation.
    private func play(string: Int, fret: Int) {
        audio.pluck(string: string, fret: fret)
        selection = (string, fret)
        litCell = (string, fret)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if litCell?.string == string, litCell?.fret == fret { litCell = nil }
        }
    }
}

struct PipaView_Previews: PreviewProvider {
    static var previews: some View {
        PipaView().environmentObject(AudioEngine())
    }
}
