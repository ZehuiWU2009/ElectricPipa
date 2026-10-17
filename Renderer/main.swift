import Foundation

// MARK: - 命令行入口

let arguments = CommandLine.arguments
let sampleRate: Double = 48000

func outputDirectory() -> URL {
    if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("PipaAudio", isDirectory: true)
}

let outputDir = outputDirectory()
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

print("Pipa 物理建模合成器  |  采样率 \(Int(sampleRate)) Hz")
print("输出目录：\(outputDir.path)")
print("")

// MARK: - 音高校验

/// 用归一化自相关估计基频，并在峰值处做抛物线插值取得亚样本精度。
/// 搜索范围限定在期望音高附近，这是校验而不是盲检测，可以避开八度误判。
func detectPitch(_ samples: [Float], sampleRate: Double, expected: Double) -> (pitch: Double, score: Float) {
    let minLag = max(2, Int(sampleRate / (expected * 1.3)))
    let maxLag = min(samples.count / 2, Int(sampleRate / (expected * 0.75)))

    // 跳过起音，取持续段来做估计。
    let start = min(samples.count / 5, samples.count / 2)
    let length = min(samples.count - start, 16384)
    guard length > maxLag * 2 else { return (0, 0) }

    // 先看这一段到底有没有声音，静音上做自相关只会得到噪声。
    var peakAmplitude: Float = 0
    for i in 0..<length {
        peakAmplitude = max(peakAmplitude, abs(samples[start + i]))
    }
    guard peakAmplitude > 1e-5 else { return (0, 0) }

    var bestLag = 0
    var bestScore: Float = -1

    for lag in minLag...maxLag {
        var dot: Float = 0
        var energyA: Float = 0
        var energyB: Float = 0
        for i in 0..<length {
            let a = samples[start + i]
            let b = samples[start + i + lag]
            dot += a * b
            energyA += a * a
            energyB += b * b
        }
        guard energyA > 1e-12, energyB > 1e-12 else { continue }
        let score = dot / sqrt(energyA * energyB)
        if score > bestScore {
            bestScore = score
            bestLag = lag
        }
    }

    guard bestLag > 1, bestScore > 0.2 else { return (0, bestScore) }

    // 在最佳延迟的左右两点上做抛物线插值，细化周期估计。
    func correlation(at lag: Int) -> Float {
        var dot: Float = 0
        for i in 0..<length {
            dot += samples[start + i] * samples[start + i + lag]
        }
        return dot
    }
    let left = correlation(at: bestLag - 1)
    let center = correlation(at: bestLag)
    let right = correlation(at: bestLag + 1)
    let denominator = left - 2 * center + right
    var refined = Double(bestLag)
    // 分母趋零时插值会发散，只接受小于一个样本的修正。
    if abs(denominator) > 1e-6 {
        let correction = Double(0.5 * (left - right) / denominator)
        if abs(correction) < 1.0 { refined += correction }
    }
    return (sampleRate / refined, bestScore)
}

/// 渲染一次拨弦的样本，返回整段波形。
func renderPluck(string: Int, fret: Int, seconds: Double) -> [Float] {
    Scheduler.shared.reset()
    let synth = PipaSynth(sampleRate: sampleRate)
    synth.pluck(string: string, fret: fret, velocity: 0.9, position: 0.5)
    let count = Int(seconds * sampleRate)
    var output = [Float](repeating: 0, count: count)
    synth.render(into: &output, count: count)
    return output
}

/// 测量衰减到 -40 dB 所需时间。
func decayTime(_ samples: [Float], sampleRate: Double) -> Double {
    var peak: Float = 0
    for value in samples { peak = max(peak, abs(value)) }
    guard peak > 0 else { return 0 }
    let threshold = peak * 0.01
    for index in stride(from: samples.count - 1, to: 0, by: -1) {
        if abs(samples[index]) > threshold {
            return Double(index) / sampleRate
        }
    }
    return 0
}

print("── 空弦音高校验 ──")
print("弦       期望      实测      音分偏差")
var tuningPassed = true
for string in 0..<PipaSynth.stringCount {
    let expected = PipaTuning.frequency(string: string, fret: 0)
    let wave = renderPluck(string: string, fret: 0, seconds: 2.0)
    let result = detectPitch(wave, sampleRate: sampleRate, expected: expected)
    let cents = result.pitch > 0 ? 1200 * log2(result.pitch / expected) : .nan
    let note = PipaTuning.noteName(PipaTuning.midi(string: string, fret: 0))
    let name = PipaTuning.stringNames[string]
    if !(abs(cents) <= 10) { tuningPassed = false }
    print(String(format: "%@(%@)  %6.1f Hz  %6.1f Hz  %+6.1f cents  相关度 %.2f",
                 name, note, expected, result.pitch, cents, result.score))
}
print(tuningPassed ? "✅ 四根空弦音高全部在 ±10 音分内" : "⚠️ 存在超过 10 音分的偏差")
print("")

// 解析法校验全音域：128 个音位全部检查，不受信号分析误差影响。
print("── 全音域音准校验（解析法，4 弦 × 32 音位 = 128 个音）──")
let verificationSynth = PipaSynth(sampleRate: sampleRate)
var worstCent: Double = 0
var worstLabel = ""
var analyticFailures = 0
var totalChecked = 0

for string in 0..<PipaSynth.stringCount {
    for fret in 0..<PipaTuning.positionCount {
        let expected = PipaTuning.frequency(string: string, fret: fret)
        let actual = verificationSynth.measuredFrequency(string: string, fret: fret)
        let cents = 1200 * log2(actual / expected)
        totalChecked += 1
        if abs(cents) > abs(worstCent) {
            worstCent = cents
            worstLabel = "\(PipaTuning.stringNames[string]) \(PipaTuning.positionName(fret)) \(PipaTuning.noteName(PipaTuning.midi(string: string, fret: fret)))"
        }
        if abs(cents) > 5 {
            analyticFailures += 1
            if analyticFailures <= 6 {
                print(String(format: "  ⚠️ %@ %@ %@：%7.2f Hz → %7.2f Hz，%+6.1f cents",
                             PipaTuning.stringNames[string], PipaTuning.positionName(fret),
                             PipaTuning.noteName(PipaTuning.midi(string: string, fret: fret)),
                             expected, actual, cents))
            }
        }
    }
}
print(String(format: "共 %d 个音位，最大偏差 %+.2f cents（%@）", totalChecked, worstCent, worstLabel))
print(analyticFailures == 0 ? "✅ 全部 128 个音位都在 ±5 音分内（人耳分辨不出）" : "⚠️ 有 \(analyticFailures) 个音位超出 ±5 音分")
print("")

// 音频级抽查：解析法只保证延迟线算得对，这里确认高音区真的发得出声、音也准。
print("── 音频级抽查（高音区，自相关）──")
for fret in [6, 12, 18, 24, 31] {
    let expected = PipaTuning.frequency(string: 3, fret: fret)
    let wave = renderPluck(string: 3, fret: fret, seconds: 1.2)
    let result = detectPitch(wave, sampleRate: sampleRate, expected: expected)
    let cents = result.pitch > 0 ? 1200 * log2(result.pitch / expected) : .nan
    let label = "\(PipaTuning.positionName(fret)) \(PipaTuning.noteName(PipaTuning.midi(string: 3, fret: fret)))"
    let mark = result.pitch > 0 && abs(cents) <= 15 ? "✅" : "⚠️"
    print(String(format: "  %@ %-12@ %7.1f Hz → %7.1f Hz  %+6.1f cents  相关度 %.2f",
                 mark, label, expected, result.pitch, cents, result.score))
}
print("")

// MARK: - 演示片段

func write(_ samples: [Float], named name: String) {
    // 峰值为 0.9 左右归一化，留出余量避免削波。
    var peak: Float = 0
    for value in samples { peak = max(peak, abs(value)) }
    var normalized = samples
    if peak > 1e-6 {
        let scale = 0.9 / peak
        for index in normalized.indices { normalized[index] *= scale }
    }
    let url = outputDir.appendingPathComponent(name)
    do {
        try WavFile.writeMono24Bit(normalized, sampleRate: Int(sampleRate), to: url)
        print("  写出 \(name)")
    } catch {
        print("  写出失败 \(name)：\(error)")
    }
}

struct Note {
    var time: Double
    var string: Int
    var fret: Int
    var velocity: Double = 0.85
}

/// 按事件表渲染一段演奏。
func renderNotes(_ notes: [Note], tail: Double = 1.8) -> [Float] {
    Scheduler.shared.reset()
    let synth = PipaSynth(sampleRate: sampleRate)

    let last = notes.map { $0.time }.max() ?? 0
    let count = Int((last + tail) * sampleRate)
    var output = [Float](repeating: 0, count: count)

    var cursor = 0
    for note in notes.sorted(by: { $0.time < $1.time }) {
        let target = min(Int(note.time * sampleRate), count)
        if target > cursor {
            var chunk = [Float](repeating: 0, count: target - cursor)
            synth.render(into: &chunk, count: chunk.count)
            for (offset, value) in chunk.enumerated() { output[cursor + offset] = value }
            cursor = target
        }
        synth.pluck(string: note.string, fret: note.fret, velocity: note.velocity)
    }
    if cursor < count {
        var chunk = [Float](repeating: 0, count: count - cursor)
        synth.render(into: &chunk, count: chunk.count)
        for (offset, value) in chunk.enumerated() { output[cursor + offset] = value }
    }
    return output
}

print("── 演示片段 ──")

// 1. 四根空弦依次拨响。
var openStringNotes: [Note] = []
for index in 0..<PipaSynth.stringCount {
    openStringNotes.append(Note(time: Double(index) * 0.9, string: index, fret: 0, velocity: 0.9))
}
write(renderNotes(openStringNotes), named: "01_open_strings.wav")

// 2. 子弦上的五声音阶，D 调，对应 Pipa 的正调音阶。
var scaleNotes: [Note] = []
let pentatonicFrets = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21]
for (index, fret) in pentatonicFrets.enumerated() {
    scaleNotes.append(Note(time: Double(index) * 0.32, string: 3, fret: fret, velocity: 0.8))
}
write(renderNotes(scaleNotes), named: "02_scale.wav")

// 3. 轮指：子弦空弦上每秒 9 下，持续 2 秒。
Scheduler.shared.reset()
let tremoloSynth = PipaSynth(sampleRate: sampleRate)
tremoloSynth.tremolo(string: 3, fret: 7, rate: 9, duration: 2.0, velocity: 0.5)
var tremolo = [Float](repeating: 0, count: Int(3.4 * sampleRate))
tremoloSynth.render(into: &tremolo, count: tremolo.count)
write(tremolo, named: "03_tremolo.wav")

// 4. 扫弦：拂与扫各一次。
Scheduler.shared.reset()
let strumSynth = PipaSynth(sampleRate: sampleRate)
strumSynth.strum(ascending: true, velocity: 0.85)
var strum = [Float](repeating: 0, count: Int(3.0 * sampleRate))
strumSynth.render(into: &strum, count: strum.count)
write(strum, named: "04_strum.wav")

// 5. 推拉弦滑音：在子弦上把音高连续推高再放回。
Scheduler.shared.reset()
let slideSynth = PipaSynth(sampleRate: sampleRate)
let startFrequency = PipaTuning.frequency(string: 3, fret: 5)
let slideSamples = Int(2.6 * sampleRate)
var slide = [Float](repeating: 0, count: slideSamples)
slideSynth.pluckFrequency(string: 3, frequency: startFrequency, velocity: 0.9)
for index in 0..<slideSamples {
    let time = Double(index) / sampleRate
    // 前 0.9 秒推高一个全音，之后缓慢回落。
    var semitones: Double = 0
    if time < 0.9 {
        semitones = 2.0 * (time / 0.9)
    } else {
        let progress = min((time - 0.9) / 1.0, 1.0)
        semitones = 2.0 * (1.0 - progress)
    }
    slideSynth.bend(string: 3, to: startFrequency * pow(2.0, semitones / 12.0))
    slide[index] = slideSynth.renderSample()
}
write(slide, named: "05_slide.wav")

// 6. 一段乐句：五声音阶上行 + 轮指长音 + 下行收尾。
var phrase: [Note] = []
var time: Double = 0
for fret in [0, 2, 4, 7, 9] {
    phrase.append(Note(time: time, string: 3, fret: fret, velocity: 0.85))
    time += 0.28
}
phrase.append(Note(time: time, string: 0, fret: 0, velocity: 0.7))   // 缠弦空弦衬托
time += 0.5
for fret in [12, 9, 7, 4, 2, 0] {
    phrase.append(Note(time: time, string: 3, fret: fret, velocity: 0.8))
    time += 0.26
}
phrase.append(Note(time: time + 0.3, string: 1, fret: 0, velocity: 0.75))
write(renderNotes(phrase, tail: 2.5), named: "06_phrase.wav")

// 7. 与实测脉冲响应的对比说明：没有 IR 时使用合成响应，这里输出一份合成 IR 供参考。
let syntheticIR = PipaBody.synthesizeImpulseResponse(sampleRate: sampleRate)
write(syntheticIR, named: "07_synthetic_body_ir.wav")

print("")
print("完成。共 \(PipaSynth.stringCount) 根弦，音域 \(PipaTuning.noteName(PipaTuning.midi(string: 0, fret: 0))) 到 \(PipaTuning.noteName(PipaTuning.midi(string: 3, fret: 25)))。")
