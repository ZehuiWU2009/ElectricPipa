/// Verification for the measured modal model the app now sounds.
///
/// Three questions, in the order that matters:
///
/// 1. Is the port faithful? Each string is rendered at 48 kHz straight from the
///    voice and compared, sample by sample, against the kit's own golden file
///    (exported from an independent Python model) and against the peaks the kit
///    reported. A slow drift here would mean the accepted timbre is not what
///    the app plays.
/// 2. Does it play an instrument? Open pitches against the app's own tuning
///    table, all four strings in the right order, every fret in tune, the pluck
///    position and the tone trim doing something in the right direction, 止音
///    actually stopping, and the stereo image present.
/// 3. Can it run in real time? Four voices plus the sympathetic layer rendered
///    faster than they play, with the CPU headroom reported.
///
/// Build and run from the project root:
///   xcrun swiftc -O -parse-as-library Core/PipaTuning.swift Core/PipaString.swift \
///     Core/PipaBody.swift Core/PipaSynth.swift Core/WavFile.swift \
///     Core/PipaSoundEngine.swift Core/PipaKitModel.swift Core/PipaKitVoice.swift \
///     Core/PipaKitSynth.swift Scripts/verify-kit-model.swift -o /tmp/verify_kit
///   /tmp/verify_kit
///
/// It also writes listening files under Recordings/pilot/kit/ — the measured
/// model beside the waveguide for the same phrases, so the choice can be made
/// by ear.
import AVFoundation
import Foundation

@main
struct VerifyKitModel {

    static let sampleRate = 48_000.0
    static let resources = URL(fileURLWithPath: "Core/KitResources")
    static let fixtures = URL(fileURLWithPath: "Scripts/kit-fixtures")
    static let output = URL(fileURLWithPath: "Recordings/pilot/kit")

    static var failures = 0

    static func check(_ passed: Bool, _ label: String, _ detail: String = "") {
        if !passed { failures += 1 }
        print("  \(passed ? "✅" : "⚠️") \(label)\(detail.isEmpty ? "" : "  \(detail)")")
    }

    static func main() throws {
        let model = try PipaKitModel.load(from: resources, sampleRate: sampleRate)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        print("琵琶实测模态模型  |  48 kHz  |  四弦")
        print("")

        try checkFidelity(model)
        try checkTuning(model)
        try checkPlaying(model)
        try checkCost()
        try checkDeviceRate(model)
        try checkCore(model)
        try writeListeningFiles(model)

        print("")
        if failures == 0 {
            print("✅ 全部通过")
        } else {
            print("⚠️ \(failures) 项未通过")
            exit(1)
        }
    }

    // MARK: - 1. Fidelity against the kit

    struct Golden: Decodable {
        struct Frame: Decodable { let index: Int; let left: Float; let right: Float }
        let string: Int
        let frames: [Frame]
    }

    struct KitVerification: Decodable {
        struct Entry: Decodable { let string: Int; let peak: Float }
        let strings: [Entry]
    }

    static func checkFidelity(_ model: PipaKitModel) throws {
        print("── 一、与音色包逐点比对（12 秒，48 kHz，未加调音修正）──")
        let golden = try JSONDecoder().decode(
            [Golden].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("golden.json")))
        let kitPeaks = try JSONDecoder().decode(
            KitVerification.self,
            from: Data(contentsOf: fixtures.appendingPathComponent("kit-verification.json")))

        for fixture in golden {
            // Fixture strings are numbered by thickness from the kit's side:
            // 1 is the thinnest. The model keeps that numbering in `presets`.
            var voice = PipaKitVoice(preset: model.presets[fixture.string - 1],
                                     sampleRate: sampleRate,
                                     fittedPosition: PipaKitSynth.fittedPluckPosition[4 - fixture.string])
            voice.start(shift: 1, velocity: 1, position: 0.5)

            var worst: Float = 0
            var peak: Float = 0
            var checked = 0
            for index in 0..<576_000 {
                let frame = voice.renderSample()
                peak = max(peak, max(abs(frame.left), abs(frame.right)))
                if checked < fixture.frames.count, fixture.frames[checked].index == index {
                    let expected = fixture.frames[checked]
                    worst = max(worst, abs(frame.left - expected.left))
                    worst = max(worst, abs(frame.right - expected.right))
                    checked += 1
                }
            }
            let kitPeak = kitPeaks.strings.first { $0.string == fixture.string }?.peak ?? 0
            print(String(format: "  第 %d 弦：%d 个采样点，最大误差 %.2e，峰值 %.6f（音色包 %.6f）",
                         fixture.string, checked, worst, peak, kitPeak))
            check(checked == fixture.frames.count, "第 \(fixture.string) 弦比对点齐全", "\(checked) / \(fixture.frames.count)")
            check(worst < 2e-6, "第 \(fixture.string) 弦与音色包一致", String(format: "最大误差 %.2e", worst))
            check(abs(peak - kitPeak) < 5e-4, "第 \(fixture.string) 弦峰值与音色包一致",
                  String(format: "差 %.2e", abs(peak - kitPeak)))
        }
        print("")
    }

    // MARK: - 2. Playing an instrument

    static func checkTuning(_ model: PipaKitModel) throws {
        print("── 二、音高（实测开弦被拉回平均律）──")
        let synth = PipaKitSynth(model: model, sampleRate: sampleRate)
        synth.masterGain = 1.0
        synth.setBrightness(0.5)
        var worstOpen: Double = 0

        for string in 0..<4 {
            let expected = PipaTuning.frequency(string: string, fret: 0)
            let measured = model.measuredFrequency(string: string)
            let detected = detectPitch(render(synth, string: string, fret: 0, seconds: 1.2), expected: expected)
            let cents = 1200 * log2(detected / expected)
            worstOpen = max(worstOpen, abs(cents))
            print(String(format: "  %@ %@：拟合 %7.2f Hz → 目标 %7.2f Hz，实测 %7.2f Hz，%+.1f 音分",
                         PipaTuning.stringNames[string],
                         PipaTuning.noteName(PipaTuning.midi(string: string, fret: 0)),
                         measured, expected, detected, cents))
            check(abs(cents) <= 5, "\(PipaTuning.stringNames[string]) 空弦对准音名",
                  String(format: "%+.1f 音分", cents))
        }
        check(worstOpen <= 5, "四弦空弦都在 ±5 音分内", String(format: "最大 %.1f", worstOpen))

        // The ordering check. Reversed outer strings still sound like a Pipa;
        // only the pitches give it away, so 缠弦 must be the low one.
        let low = detectPitch(render(synth, string: 0, fret: 0, seconds: 1.2), expected: 110)
        let high = detectPitch(render(synth, string: 3, fret: 0, seconds: 1.2), expected: 220)
        check(low < high - 50, "弦序没有装反", String(format: "缠弦 %.1f Hz，子弦 %.1f Hz", low, high))

        print("── 三、按品音准（每弦 32 个音位抽样）──")
        var worstFret: Double = 0
        var worstLabel = ""
        for string in 0..<4 {
            for fret in [1, 5, 7, 12, 15, 19, 24, 31] {
                let expected = PipaTuning.frequency(string: string, fret: fret)
                let detected = detectPitch(render(synth, string: string, fret: fret, seconds: 1.0),
                                           expected: expected)
                let cents = detected > 0 ? 1200 * log2(detected / expected) : .infinity
                if abs(cents) > abs(worstFret) {
                    worstFret = cents
                    worstLabel = "\(PipaTuning.stringNames[string]) \(PipaTuning.positionName(fret))"
                }
                if abs(cents) > 8 {
                    print(String(format: "  ⚠️ %@ %@ %+.1f 音分", PipaTuning.stringNames[string],
                                 PipaTuning.positionName(fret), cents))
                }
            }
        }
        check(worstFret <= 8, "按品采样全部在 ±8 音分内",
              String(format: "最大 %+.1f 音分（%@）", worstFret, worstLabel))
        print("")
    }

    static func checkPlaying(_ model: PipaKitModel) throws {
        print("── 四、演奏行为 ──")

        // Neutral pluck must be the accepted tone: two renders of the same
        // pluck have to be identical, and a pluck away from the fitted spot
        // must change the tone without changing the level wildly.
        let neutral = render(PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1),
                             string: 3, fret: 0, seconds: 0.5)
        let again = render(PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1),
                           string: 3, fret: 0, seconds: 0.5)
        check(zip(neutral, again).allSatisfy { $0 == $1 }, "同一拨弦结果可复现")

        // Pluck position: near the bridge, the partials with a node under the
        // pick are the low ones, so the sixth partial gains against the second.
        // Measured with a Goertzel pair rather than a spectral average, because
        // a broadband brightness number is dominated by the top partials where
        // the notch pattern averages out.
        let nearBridge = render(PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1),
                                string: 3, fret: 0, seconds: 0.5, position: 0.18)
        let nearXiang = render(PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1),
                               string: 3, fret: 0, seconds: 0.5, position: 0.9)
        let f0 = PipaTuning.frequency(string: 3, fret: 0)
        let neutralRatio = harmonic(neutral, f0, 6) / max(harmonic(neutral, f0, 2), 1e-12)
        let bridgeRatio = harmonic(nearBridge, f0, 6) / max(harmonic(nearBridge, f0, 2), 1e-12)
        let xiangRatio = harmonic(nearXiang, f0, 6) / max(harmonic(nearXiang, f0, 2), 1e-12)
        check(bridgeRatio > neutralRatio * 1.2, "靠桥拨弦更亮",
              String(format: "第6/第2泛音 %.2f → %.2f", neutralRatio, bridgeRatio))
        // Away from the fitted spot the notch pattern moves with the pick:
        // near the middle of the string the even partials die, which is a
        // different sound from the thin one near the bridge, not simply a
        // darker one. What has to be true is that the three spots differ.
        check(abs(xiangRatio - bridgeRatio) > neutralRatio * 0.2, "两个拨弦点音色不同",
              String(format: "靠桥 %.2f，近相 %.2f", bridgeRatio, xiangRatio))
        for (label, samples) in [("靠桥", nearBridge), ("近相", nearXiang)] {
            let levelRatio = rms(samples) / max(rms(neutral), 1e-9)
            check(levelRatio > 0.4 && levelRatio < 2.0, "\(label)拨弦音量不跳",
                  String(format: "%.2f 倍", levelRatio))
        }

        let dark = PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1)
        dark.setBrightness(0.15)
        let darkTone = brightness(render(dark, string: 3, fret: 0, seconds: 0.5))
        let bright = PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1)
        bright.setBrightness(1.0)
        let brightTone = brightness(render(bright, string: 3, fret: 0, seconds: 0.5))
        check(brightTone > darkTone * 1.05, "明暗调节方向正确",
              String(format: "%.3f → %.3f", darkTone, brightTone))

        // 止音: a damped string must be silent within 100 ms, not ring on.
        // 止音 is dampAll in the app: the hand is laid across all four strings,
        // so the bridge-driven voices stop too.
        let damped = PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1)
        var tail: [Float] = []
        damped.pluck(string: 0, fret: 0, velocity: 0.9)
        for index in 0..<Int(sampleRate * 0.35) {
            if index == Int(sampleRate * 0.2) { damped.dampAll() }
            let frame = damped.renderFrame()
            if index > Int(sampleRate * 0.3) { tail.append(abs(frame.left)) }
        }
        let tailPeak = tail.max() ?? 0
        check(tailPeak < 0.001, "止音后 100 毫秒内静音", String(format: "残余峰值 %.2e", tailPeak))

        // Stereo: the fitted right-channel gains and phases must survive.
        let frames = renderFrames(PipaKitSynth(model: model, sampleRate: sampleRate, gain: 1),
                                  string: 1, fret: 0, seconds: 0.6)
        let leftRMS = rms(frames.map(\.left))
        let rightRMS = rms(frames.map(\.right))
        var correlation = 0.0
        var leftSquare = 0.0
        var rightSquare = 0.0
        for frame in frames {
            correlation += Double(frame.left) * Double(frame.right)
            leftSquare += Double(frame.left) * Double(frame.left)
            rightSquare += Double(frame.right) * Double(frame.right)
        }
        let normalised = correlation / max((leftSquare * rightSquare).squareRoot(), 1e-9)
        check(rightRMS > leftRMS * 0.2 && rightRMS < leftRMS * 2.0, "左右声道各自有信号",
              String(format: "L %.4f / R %.4f", leftRMS, rightRMS))
        check(normalised < 0.999, "立体声不是简单的双单声道", String(format: "相关度 %.3f", normalised))

        // Level: a four-string strum at the default volume must leave headroom.
        let strum = PipaKitSynth(model: model, sampleRate: sampleRate)
        strum.masterGain = 0.5
        for string in 0..<4 {
            strum.pluck(string: string, fret: 0, velocity: 0.85)
        }
        var strumPeak: Float = 0
        for _ in 0..<Int(sampleRate * 2) {
            let frame = strum.renderFrame()
            strumPeak = max(strumPeak, max(abs(frame.left), abs(frame.right)))
        }
        check(strumPeak < 0.98, "默认音量下扫弦不削波", String(format: "峰值 %.3f", strumPeak))
        print("")
    }

    // MARK: - 3. Cost

    static func checkCost() throws {
        print("── 五、实时开销（四弦同时发声）──")
        let model = try PipaKitModel.load(from: resources, sampleRate: sampleRate)
        let synth = PipaKitSynth(model: model, sampleRate: sampleRate)
        synth.masterGain = 0.5
        for string in 0..<4 { synth.pluck(string: string, fret: 0, velocity: 0.8) }
        let seconds = 10.0
        let started = Date()
        var sink: Float = 0
        for _ in 0..<Int(sampleRate * seconds) {
            sink += synth.renderFrame().left
        }
        let elapsed = Date().timeIntervalSince(started)
        let ratio = seconds / max(elapsed, 1e-9)
        check(ratio > 10, "渲染快于实时 10 倍以上",
              String(format: "%.0f 倍实时（每秒约 %.1f%% 单核）", ratio, 100 / ratio))
        check(sink.isFinite, "输出有限")
        print("")
    }

    // MARK: - A device that will not give us 48 kHz

    static func checkDeviceRate(_ model: PipaKitModel) throws {
        print("── 六、44.1 kHz 设备（残余层需要重采样）──")
        let rate = 44_100.0
        let resampled = try PipaKitModel.load(from: resources, sampleRate: rate)
        check(resampled.presets[0].residual.count > 0, "残余层已按设备采样率重建",
              "\(resampled.presets[0].residual.count / 2) 帧")
        /// Peak of one open string through the full synth path at a given rate.
        func peakAt(_ rate: Double, _ model: PipaKitModel) -> (peak: Float, samples: [Float]) {
            let synth = PipaKitSynth(model: model, sampleRate: rate)
            synth.masterGain = 1
            synth.pluck(string: 3, fret: 0, velocity: 0.9)
            var peak: Float = 0
            var samples: [Float] = []
            for _ in 0..<Int(rate * 1.5) {
                let frame = synth.renderFrame()
                peak = max(peak, max(abs(frame.left), abs(frame.right)))
                samples.append(frame.left)
            }
            return (peak, samples)
        }
        let reference = peakAt(48_000, model)
        let measuredRate = peakAt(rate, resampled)
        let peak = measuredRate.peak
        let samples = measuredRate.samples
        let expected = PipaTuning.frequency(string: 3, fret: 0)
        let detected = detectPitch(samples, expected: expected, rate: rate)
        let cents = detected > 0 ? 1200 * log2(detected / expected) : .infinity
        check(abs(cents) <= 5, "44.1 kHz 下音高不变", String(format: "%+.1f 音分", cents))
        // Compared against the same synth path at 48 kHz, so the check is about
        // the resampled residual and not about the mix gain.
        let difference = abs(peak - reference.peak) / max(reference.peak, 1e-6)
        check(difference < 0.05, "44.1 kHz 下电平不变",
              String(format: "%.4f 对 %.4f，差 %.1f%%", peak, reference.peak, difference * 100))
        print("")
    }

    // MARK: - The audio core that ships

    /// Render through the real kernel with a hand-built buffer list, the way an
    /// earlier crash investigation did: this is the path CoreAudio calls, not a
    /// convenience wrapper, so it catches a wrong channel count or a stereo
    /// frame written into one buffer.
    static func renderCore(_ core: PipaAudioCore, seconds: Double,
                           frames: Int = 512) -> (left: [Float], right: [Float]) {
        let total = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        let block = min(frames, total)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }

        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                // Each call writes from the start of the buffer it is given,
                // exactly as CoreAudio does, so the payload pointer advances
                // with every block instead of the buffer being reused in place.
                var written = 0
                while written < total {
                    let count = min(block, total - written)
                    list[0] = AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: UInt32(count * 4),
                                          mData: leftBuffer.baseAddress!.advanced(by: written))
                    list[1] = AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: UInt32(count * 4),
                                          mData: rightBuffer.baseAddress!.advanced(by: written))
                    core.render(frames: count, bufferList: list.unsafeMutablePointer)
                    written += count
                }
            }
        }
        return (left, right)
    }

    static func checkCore(_ model: PipaKitModel) throws {
        print("── 七、音频内核（立体声、事件队列、持续轮指）──")
        let core = PipaAudioCore(sampleRate: sampleRate,
                                 synth: PipaKitSynth(model: model, sampleRate: sampleRate))
        core.setMasterGain(0.5)
        core.pluck(string: 3, fret: 0, velocity: 0.9)
        let plucked = renderCore(core, seconds: 1.0)
        let leftPeak = plucked.left.map(abs).max() ?? 0
        let rightPeak = plucked.right.map(abs).max() ?? 0
        check(leftPeak > 0.05 && rightPeak > 0.05, "左右声道都有输出",
              String(format: "L %.3f / R %.3f", leftPeak, rightPeak))
        let identical = zip(plucked.left, plucked.right).allSatisfy { $0 == $1 }
        check(!identical, "内核没有把立体声写成双单声道")

        // A continuous roll holds its own clock on the render thread; nine
        // strokes a second should show up as nine onsets.
        let rollingCore = PipaAudioCore(sampleRate: sampleRate,
                                        synth: PipaKitSynth(model: model, sampleRate: sampleRate))
        rollingCore.setMasterGain(0.5)
        rollingCore.rollStart(kind: .wheel, string: 2, fret: 0, interval: 1.0 / 9,
                              velocity: 0.6)
        let rolled = renderCore(rollingCore, seconds: 1.2)
        let onsets = countOnsets(rolled.left)
        check(abs(onsets - 11) <= 2, "轮指按自己的时钟连续发声", "1.2 秒内 \(onsets) 次起音")

        // 止音 through the queue must actually stop it.
        rollingCore.dampAll()
        let silenced = renderCore(rollingCore, seconds: 0.3)
        // The hand takes a few tens of milliseconds to stop the string; what
        // matters is that nothing is still sounding 100 ms later.
        let afterFade = silenced.left.dropFirst(Int(sampleRate * 0.1))
        let silencePeak = afterFade.map(abs).max() ?? 0
        check(silencePeak < 0.002, "滚奏止音后静音", String(format: "残余峰值 %.2e", silencePeak))
        print("")
    }

    /// Onsets counted from a first-difference energy envelope: a new stroke
    /// gives a step up in energy that the decay does not.
    static func countOnsets(_ samples: [Float]) -> Int {
        var envelope: [Double] = []
        let window = 64
        var index = 1
        while index + window < samples.count {
            var energy = 0.0
            for offset in 0..<window {
                let delta = Double(samples[index + offset] - samples[index + offset - 1])
                energy += delta * delta
            }
            envelope.append(energy)
            index += window
        }
        guard let maximum = envelope.max(), maximum > 0 else { return 0 }
        var count = 0
        var armed = true
        for value in envelope {
            if armed, value > maximum * 0.18 {
                count += 1
                armed = false
            } else if !armed, value < maximum * 0.06 {
                armed = true
            }
        }
        return count
    }

    // MARK: - Listening files

    struct Note {
        let time: Double
        let string: Int
        let fret: Int
        var velocity: Double = 0.85
        var position: Double = 0.5
    }

    static func writeListeningFiles(_ model: PipaKitModel) throws {
        print("── 八、试听文件（Recordings/pilot/kit/）──")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let measured = PipaKitSynth(model: model, sampleRate: sampleRate)
        measured.masterGain = 0.5
        let waveguide = PipaSynth(sampleRate: sampleRate)
        waveguide.masterGain = 0.5

        // 1. Four open strings, thickest first, then the same phrase on the
        // waveguide for comparison.
        var open: [Note] = []
        for (index, string) in [0, 1, 2, 3].enumerated() {
            open.append(Note(time: Double(index) * 0.85, string: string, fret: 0, velocity: 0.9))
        }
        try write(render(measured, notes: open, seconds: 5.4), named: "01_open_strings_measured.wav")
        try write(render(waveguide, notes: open, seconds: 5.4), named: "01_open_strings_waveguide.wav")

        // 2. Pentatonic ascent on the thinnest string.
        var scale: [Note] = []
        for (index, fret) in [0, 2, 4, 7, 9, 12, 14, 16, 19, 21].enumerated() {
            scale.append(Note(time: Double(index) * 0.3, string: 3, fret: fret, velocity: 0.8))
        }
        try write(render(measured, notes: scale, seconds: 3.6), named: "02_scale_measured.wav")
        try write(render(waveguide, notes: scale, seconds: 3.6), named: "02_scale_waveguide.wav")

        // 3. Wheel: five fingers, twelve strokes a second, 25 strokes.
        var wheel: [Note] = []
        let fingers = WheelFinger.allCases
        for index in 0..<25 {
            let finger = fingers[index % fingers.count]
            wheel.append(Note(time: Double(index) / 12, string: 3, fret: 7,
                              velocity: 0.55 * finger.velocityScale, position: finger.position))
        }
        try write(render(measured, notes: wheel, seconds: 3.2), named: "03_wheel_measured.wav")
        try write(render(waveguide, notes: wheel, seconds: 3.2), named: "03_wheel_waveguide.wav")

        // 4. Fu and sao: one chord bar across all four strings, both ways.
        var strum: [Note] = []
        for (index, string) in [0, 1, 2, 3].enumerated() {
            strum.append(Note(time: 0.02 * Double(index), string: string, fret: 5, velocity: 0.85))
        }
        for (index, string) in [3, 2, 1, 0].enumerated() {
            strum.append(Note(time: 1.1 + 0.02 * Double(index), string: string, fret: 5, velocity: 0.8))
        }
        try write(render(measured, notes: strum, seconds: 3.2), named: "04_strum_measured.wav")
        try write(render(waveguide, notes: strum, seconds: 3.2), named: "04_strum_waveguide.wav")

        // 5. One note, three pluck positions: bridge, neutral, further up.
        var positions: [Note] = []
        for (index, position) in [0.2, 0.5, 0.85].enumerated() {
            positions.append(Note(time: Double(index) * 1.0, string: 1, fret: 3,
                                  velocity: 0.85, position: position))
        }
        try write(render(measured, notes: positions, seconds: 3.2), named: "05_positions_measured.wav")
        print("")
    }

    static func render(_ synth: PipaSoundEngine, notes: [Note], seconds: Double) -> [PipaFrame] {
        var frames: [PipaFrame] = []
        frames.reserveCapacity(Int(seconds * sampleRate))
        let ordered = notes.sorted { $0.time < $1.time }
        var next = 0
        for index in 0..<Int(seconds * sampleRate) {
            let time = Double(index) / sampleRate
            while next < ordered.count, ordered[next].time <= time {
                let note = ordered[next]
                synth.pluck(string: note.string, fret: note.fret,
                            velocity: note.velocity, position: note.position)
                next += 1
            }
            frames.append(synth.renderFrame())
        }
        return frames
    }

    // MARK: - Helpers

    static func render(_ synth: PipaKitSynth, string: Int, fret: Int, seconds: Double,
                       position: Double = 0.5) -> [Float] {
        synth.pluck(string: string, fret: fret, velocity: 0.9, position: position)
        return (0..<Int(seconds * sampleRate)).map { _ in synth.renderFrame().left }
    }

    static func renderFrames(_ synth: PipaKitSynth, string: Int, fret: Int,
                             seconds: Double) -> [PipaFrame] {
        synth.pluck(string: string, fret: fret, velocity: 0.9, position: 0.5)
        return (0..<Int(seconds * sampleRate)).map { _ in synth.renderFrame() }
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// High-frequency share of the energy, a one-number stand-in for brightness:
    /// the RMS of the first difference over the RMS of the signal.
    static func brightness(_ samples: [Float]) -> Double {
        guard samples.count > 2 else { return 0 }
        var difference = 0.0
        for index in 1..<samples.count {
            let delta = Double(samples[index] - samples[index - 1])
            difference += delta * delta
        }
        let slope = (difference / Double(samples.count - 1)).squareRoot()
        return slope / max(rms(samples), 1e-12)
    }

    /// Energy of one harmonic of `frequency` in the window, by Goertzel with a
    /// Hann window so neighbouring partials do not leak in.
    static func harmonic(_ samples: [Float], _ frequency: Double, _ multiple: Int,
                         from seconds: Double = 0.08, rate: Double = sampleRate) -> Double {
        let start = Int(seconds * rate)
        let count = min(samples.count - start, 16_384)
        guard count > 16, frequency > 0 else { return 0 }
        let omega = 2 * Double.pi * frequency * Double(multiple) / rate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var beforeThat = 0.0
        for index in 0..<count {
            let phase = 2 * Double.pi * Double(index) / Double(count - 1)
            let window = 0.5 - 0.5 * cos(phase)
            let sample = Double(samples[start + index]) * window
            let current = sample + coefficient * previous - beforeThat
            beforeThat = previous
            previous = current
        }
        return previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
    }

    /// Normalised autocorrelation around the expected pitch.
    static func detectPitch(_ samples: [Float], expected: Double,
                            rate: Double = sampleRate) -> Double {
        let start = min(samples.count / 3, samples.count - 2)
        let length = min(samples.count - start, 16_384)
        let minimumLag = max(2, Int(rate / (expected * 1.3)))
        let maximumLag = min(length / 2, Int(rate / (expected * 0.75)))
        guard length > maximumLag * 2 else { return 0 }

        var bestLag = 0
        var bestScore = -1.0
        for lag in minimumLag...maximumLag {
            var dot = 0.0
            var energyA = 0.0
            var energyB = 0.0
            for index in 0..<length {
                let a = Double(samples[start + index])
                let b = Double(samples[start + index + lag])
                dot += a * b
                energyA += a * a
                energyB += b * b
            }
            guard energyA > 1e-12, energyB > 1e-12 else { continue }
            let score = dot / (energyA * energyB).squareRoot()
            if score > bestScore { bestScore = score; bestLag = lag }
        }
        guard bestLag > 1, bestScore > 0.2 else { return 0 }

        func correlation(_ lag: Int) -> Double {
            var dot = 0.0
            for index in 0..<length { dot += Double(samples[start + index]) * Double(samples[start + index + lag]) }
            return dot
        }
        let left = correlation(bestLag - 1)
        let center = correlation(bestLag)
        let right = correlation(bestLag + 1)
        let denominator = left - 2 * center + right
        var refined = Double(bestLag)
        if abs(denominator) > 1e-9 {
            let correction = 0.5 * (left - right) / denominator
            if abs(correction) < 1 { refined += correction }
        }
        return rate / refined
    }

    /// 24-bit stereo WAV, interleaved, for listening rather than measurement.
    static func write(_ frames: [PipaFrame], named name: String) throws {
        var peak: Float = 0
        for frame in frames { peak = max(peak, max(abs(frame.left), abs(frame.right))) }
        let scale = peak > 1e-6 ? 0.92 / peak : 1

        var data = Data(capacity: frames.count * 6)
        for frame in frames {
            for value in [frame.left * scale, frame.right * scale] {
                let clamped = max(-1, min(1, value))
                let integer = Int32((Double(clamped) * 8_388_607).rounded())
                let bits = UInt32(bitPattern: integer) & 0x00FF_FFFF
                data.append(UInt8(bits & 0xFF))
                data.append(UInt8((bits >> 8) & 0xFF))
                data.append(UInt8((bits >> 16) & 0xFF))
            }
        }

        var wav = Data()
        func append(_ string: String) { wav.append(string.data(using: .ascii)!) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        append("RIFF"); append32(UInt32(36 + data.count)); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(2)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate) * 6); append16(6); append16(24)
        append("data"); append32(UInt32(data.count)); wav.append(data)

        let url = output.appendingPathComponent(name)
        try wav.write(to: url)
        print("  写出 \(name)（\(String(format: "%.1f", Double(frames.count) / sampleRate)) 秒）")
    }
}

extension PipaKitSynth {
    /// A convenience for the verification only: master gain 0…1 set at build.
    convenience init(model: PipaKitModel, sampleRate: Double, gain: Float) {
        self.init(model: model, sampleRate: sampleRate)
        masterGain = gain
    }
}
