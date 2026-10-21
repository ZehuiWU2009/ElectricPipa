import SwiftUI

enum PipaPalette {
    static let paper = Color(red: 0.96, green: 0.94, blue: 0.88)
    static let ink = Color(red: 0.20, green: 0.23, blue: 0.21)
    static let muted = Color(red: 0.44, green: 0.43, blue: 0.37)
    static let cinnabar = Color(red: 0.65, green: 0.23, blue: 0.17)
    static let gold = Color(red: 0.67, green: 0.49, blue: 0.24)
}

struct PipaView: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var selection: (string: Int, fret: Int) = (3, 0)
    @State private var litCell: (string: Int, fret: Int)? = nil
    @State private var vib = Array(repeating: StringVib(), count: 4)
    @State private var slash: SlashState?
    @State private var burst = BurstSignal()
    @State private var tanTiaoBPM: Double = 120
    @State private var wheelRate: Double = 9
    @State private var showSettings = false
    @State private var showPositions = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height
            VStack(spacing: 0) {
                header
                if wide {
                    HStack(spacing: 24) {
                        instrument
                        VStack(spacing: 20) { noteReadout; controls }
                            .frame(width: min(340, geometry.size.width * 0.42))
                    }
                } else {
                    instrument
                    noteReadout.padding(.bottom, 16)
                    controls
                }
            }
            .padding(.horizontal, wide ? 28 : 22)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(background.ignoresSafeArea())
        .foregroundStyle(PipaPalette.ink)
        .tint(PipaPalette.cinnabar)
        .sheet(isPresented: $showSettings) { settings }
        .sheet(isPresented: $showPositions) { positionPanel }
    }

    private var background: some View {
        ZStack {
            PipaPalette.paper
            RadialGradient(colors: [.white.opacity(0.75), .clear], center: .center,
                           startRadius: 30, endRadius: 500)
            // Quiet ruled-paper texture: deterministic, independent of assets.
            Canvas { context, size in
                for row in stride(from: 0.0, to: size.height, by: 5) {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: row))
                    line.addLine(to: CGPoint(x: size.width, y: row))
                    context.stroke(line, with: .color(PipaPalette.gold.opacity(0.025)), lineWidth: 0.5)
                }
            }.accessibilityHidden(true)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("琵\n琶")
                .font(.system(size: 14, weight: .medium, design: .serif))
                .lineSpacing(1)
                .foregroundStyle(PipaPalette.paper)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .background(PipaPalette.cinnabar, in: RoundedRectangle(cornerRadius: 3))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("弦上清音").font(.system(size: 25, weight: .medium, design: .serif)).tracking(3)
                Text("电 子 琵 琶  /  ELECTRIC PIPA")
                    .font(.system(size: 9, weight: .medium)).tracking(1)
                    .foregroundStyle(PipaPalette.muted)
            }
            Spacer(minLength: 4)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .regular))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.55), in: Circle())
            }.accessibilityLabel("演奏设置")
        }.padding(.bottom, 10)
    }

    private var instrument: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                Rectangle().fill(PipaPalette.gold.opacity(0.5)).frame(width: 1, height: 28)
                Text("一\n弦\n一\n清\n音")
                    .font(.system(size: 13, design: .serif)).lineSpacing(7)
                    .foregroundStyle(PipaPalette.muted)
                Spacer()
            }.padding(.top, 40).padding(.leading, 4)
                .accessibilityHidden(true)
            PipaBoardView(selection: $selection, litCell: $litCell, vib: $vib,
                          slash: $slash, burst: $burst) { string, fret, position in
                play(string: string, fret: fret, position: position)
            } onStrum: { rightward, starter in
                strumAndAnimate(sao: rightward, start: starter)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noteReadout: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Rectangle().fill(PipaPalette.gold.opacity(0.4)).frame(width: 24, height: 1)
                Text(currentNoteDescription)
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .foregroundStyle(PipaPalette.cinnabar)
                Rectangle().fill(PipaPalette.gold.opacity(0.4)).frame(width: 24, height: 1)
            }
            Text(audio.isRunning ? "轻点琴弦 · 横划扫拂" : "轻触琴弦，开始演奏")
                .font(.system(size: 11)).foregroundStyle(PipaPalette.muted)
        }
    }

    private var currentNoteDescription: String {
        let midi = PipaTuning.midi(string: selection.string, fret: selection.fret)
        return "\(PipaTuning.stringNames[selection.string]) · \(PipaTuning.positionName(selection.fret)) · \(PipaTuning.noteName(midi))"
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack(spacing: 7) {
                techniqueButton("弹挑", symbol: "arrow.left.arrow.right") { tanTiaoAndAnimate() }
                techniqueButton("轮指", symbol: "repeat") { wheelAndAnimate() }
                techniqueButton("扫弦", symbol: "arrow.right") { strumAndAnimate(sao: true) }
                techniqueButton("拂弦", symbol: "arrow.left") { strumAndAnimate(sao: false) }
                techniqueButton("止音", symbol: "pause") { audio.dampAll(); vib = Array(repeating: StringVib(), count: 4) }
            }
            HStack {
                Text("四弦 · 六相 · 二十五品")
                    .font(.system(size: 10)).foregroundStyle(PipaPalette.muted)
                Spacer()
                Button { showPositions = true } label: {
                    Label("音位面板", systemImage: "square.grid.3x3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minHeight: 44)
                }
            }
        }
    }

    private func techniqueButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 16, weight: .light))
                    .foregroundStyle(PipaPalette.cinnabar)
                Text(title).font(.system(size: 13, weight: .medium, design: .serif))
                    .foregroundStyle(PipaPalette.ink)
            }
            .frame(maxWidth: .infinity).frame(height: 67)
            .background(.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(PipaPalette.gold.opacity(0.18), lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private var settings: some View {
        NavigationStack {
            Form {
                Section("声音") {
                    labelledSlider("音色明暗", value: $audio.brightness, range: 0.15...1) { "\(Int($0 * 100))%" }
                    labelledSlider("音量", value: $audio.masterGain, range: 0...1) { "\(Int($0 * 100))%" }
                }
                Section("技法速度") {
                    labelledSlider("弹挑速度", value: $tanTiaoBPM, range: 40...480) { "\(Int($0)) BPM" }
                    labelledSlider("轮指速率", value: $wheelRate, range: 4...16) { "\(Int($0)) 次 / 秒" }
                }
                Section {
                    Text("轻点相品选择音高，轻点下方弦段弹奏空弦。横划琴弦可扫拂；高把位可在音位面板中准确演奏。")
                        .font(.subheadline).foregroundStyle(PipaPalette.muted)
                }
            }
            .scrollContentBackground(.hidden).background(PipaPalette.paper)
            .navigationTitle("演奏设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }.presentationDetents([.medium, .large])
    }

    private func labelledSlider<T>(_ title: String, value: Binding<T>, range: ClosedRange<T>,
                                   format: @escaping (T) -> String) -> some View
        where T: BinaryFloatingPoint, T.Stride: BinaryFloatingPoint {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(PipaPalette.muted) }
            Slider(value: value, in: range).accessibilityLabel(title)
        }.padding(.vertical, 5)
    }

    /// Large targets preserve access to the tightly spaced high frets on phones.
    private var positionPanel: some View {
        NavigationStack {
            VStack(spacing: 10) {
                Text("点按即演奏 · 从左至右为缠、老、中、子弦")
                    .font(.caption).foregroundStyle(PipaPalette.muted)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(0..<PipaGeometry.positionCount, id: \.self) { fret in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(PipaTuning.positionName(fret)).font(.caption).foregroundStyle(PipaPalette.muted)
                                    HStack(spacing: 8) {
                                        ForEach(0..<4, id: \.self) { string in
                                            positionButton(string: string, fret: fret)
                                        }
                                    }
                                }.id(fret)
                            }
                        }.padding(.horizontal, 20).padding(.bottom, 20)
                    }.onAppear { proxy.scrollTo(selection.fret, anchor: .center) }
                }
            }
            .padding(.top, 12).background(PipaPalette.paper)
            .navigationTitle("音位面板").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPositions = false } } }
        }.presentationDetents([.large])
    }

    private func positionButton(string: Int, fret: Int) -> some View {
        let selected = selection.string == string && selection.fret == fret
        let note = PipaTuning.noteName(PipaTuning.midi(string: string, fret: fret))
        return Button { play(string: string, fret: fret, position: 0.5) } label: {
            Text(note).font(.system(size: 14, weight: .medium)).monospacedDigit()
                .frame(maxWidth: .infinity).frame(minHeight: 46)
                .foregroundStyle(selected ? .white : PipaPalette.ink)
                .background(selected ? PipaPalette.cinnabar : .white.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
        }
        .accessibilityLabel("\(PipaTuning.stringNames[string])，\(PipaTuning.positionName(fret))，\(note)")
    }

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
        let s0 = origin.string
        let order = sao ? [0, 1, 2, 3] : [3, 2, 1, 0]
        let dir = sao ? 1.0 : -1.0
        var points: [(string: Int, fret: Int)] = []
        for index in 0..<4 {
            let str = order[index]
            // Every string sounds one semitone higher than the last as the blade
            // crosses the board, but the ladder is anchored on the string the
            // player touched: that string gets f0, so the sweep starts from the
            // chosen note instead of always beginning on 缠弦. 扫 and 拂 play
            // the same four notes, just in opposite sweep order.
            let fret = min(max(f0 + (str - s0), 0), maxFret)
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
