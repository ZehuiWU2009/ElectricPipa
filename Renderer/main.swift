import Foundation

// MARK: - Command-line entry

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

// MARK: - Pitch verification

/// Estimate the fundamental with normalised autocorrelation and refine it to
/// sub-sample accuracy with parabolic interpolation at the peak. The search is
/// confined to a neighbourhood of the expected pitch: this is a verification
/// rather than a blind detection, which keeps octave errors away.
func detectPitch(_ samples: [Float], sampleRate: Double, expected: Double) -> (pitch: Double, score: Float) {
    let minLag = max(2, Int(sampleRate / (expected * 1.3)))
    let maxLag = min(samples.count / 2, Int(sampleRate / (expected * 0.75)))

    // Skip the attack and estimate on the sustained stretch.
    let start = min(samples.count / 5, samples.count / 2)
    let length = min(samples.count - start, 16384)
    guard length > maxLag * 2 else { return (0, 0) }

    // First check whether this stretch has any sound at all; autocorrelation on
    // silence only yields noise.
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

    // Parabolic interpolation on the two neighbours of the best lag refines the
    // period estimate.
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
    // When the denominator approaches zero the interpolation blows up, so only
    // corrections smaller than one sample are accepted.
    if abs(denominator) > 1e-6 {
        let correction = Double(0.5 * (left - right) / denominator)
        if abs(correction) < 1.0 { refined += correction }
    }
    return (sampleRate / refined, bestScore)
}

/// Render one pluck and return the whole waveform.
func renderPluck(string: Int, fret: Int, seconds: Double) -> [Float] {
    Scheduler.shared.reset()
    let synth = PipaSynth(sampleRate: sampleRate)
    synth.pluck(string: string, fret: fret, velocity: 0.9, position: 0.5)
    let count = Int(seconds * sampleRate)
    var output = [Float](repeating: 0, count: count)
    synth.render(into: &output, count: count)
    return output
}

/// Measure the time it takes to decay to -40 dB.
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

// Analytic check across the whole range: all 128 positions, free of
// signal-analysis error.
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

// Audio-level spot check: the analytic method only proves the delay line is
// computed correctly; this confirms the high register really sounds, and in tune.
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

// MARK: - Demo pieces

func write(_ samples: [Float], named name: String) {
    // Normalise to a peak around 0.9, leaving headroom against clipping.
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

/// Render a performance from an event table.
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

// 1. The four open strings in turn.
var openStringNotes: [Note] = []
for index in 0..<PipaSynth.stringCount {
    openStringNotes.append(Note(time: Double(index) * 0.9, string: index, fret: 0, velocity: 0.9))
}
write(renderNotes(openStringNotes), named: "01_open_strings.wav")

// 2. A pentatonic scale on the Zi string, D mode, matching the zheng diao scale of the Pipa.
var scaleNotes: [Note] = []
let pentatonicFrets = [0, 2, 4, 7, 9, 12, 14, 16, 19, 21]
for (index, fret) in pentatonicFrets.enumerated() {
    scaleNotes.append(Note(time: Double(index) * 0.32, string: 3, fret: fret, velocity: 0.8))
}
write(renderNotes(scaleNotes), named: "02_scale.wav")

// 3. Tremolo: nine plucks a second on the open Zi string, two seconds long.
Scheduler.shared.reset()
let tremoloSynth = PipaSynth(sampleRate: sampleRate)
tremoloSynth.tremolo(string: 3, fret: 7, rate: 9, duration: 2.0, velocity: 0.5)
var tremolo = [Float](repeating: 0, count: Int(3.4 * sampleRate))
tremoloSynth.render(into: &tremolo, count: tremolo.count)
write(tremolo, named: "03_tremolo.wav")

// 4. Strum: one fu and one sao.
Scheduler.shared.reset()
let strumSynth = PipaSynth(sampleRate: sampleRate)
strumSynth.strum(ascending: true, velocity: 0.85)
var strum = [Float](repeating: 0, count: Int(3.0 * sampleRate))
strumSynth.render(into: &strum, count: strum.count)
write(strum, named: "04_strum.wav")

// 5. Push-pull slide: glide the pitch up a whole tone on the Zi string and let it fall back.
Scheduler.shared.reset()
let slideSynth = PipaSynth(sampleRate: sampleRate)
let startFrequency = PipaTuning.frequency(string: 3, fret: 5)
let slideSamples = Int(2.6 * sampleRate)
var slide = [Float](repeating: 0, count: slideSamples)
slideSynth.pluckFrequency(string: 3, frequency: startFrequency, velocity: 0.9)
for index in 0..<slideSamples {
    let time = Double(index) / sampleRate
    // Push up a whole tone over the first 0.9 s, then fall back slowly.
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

// 6. A short phrase: pentatonic ascent, a tremolo long note, then a descent to close.
var phrase: [Note] = []
var time: Double = 0
for fret in [0, 2, 4, 7, 9] {
    phrase.append(Note(time: time, string: 3, fret: fret, velocity: 0.85))
    time += 0.28
}
phrase.append(Note(time: time, string: 0, fret: 0, velocity: 0.7))   // Open Chan string underneath
time += 0.5
for fret in [12, 9, 7, 4, 2, 0] {
    phrase.append(Note(time: time, string: 3, fret: fret, velocity: 0.8))
    time += 0.26
}
phrase.append(Note(time: time + 0.3, string: 1, fret: 0, velocity: 0.75))
write(renderNotes(phrase, tail: 2.5), named: "06_phrase.wav")

// 7. A note on comparing against a measured impulse response: with no measured
// IR available, a synthesised one is used, and a copy is written out for reference.
let syntheticIR = PipaBody.synthesizeImpulseResponse(sampleRate: sampleRate)
write(syntheticIR, named: "07_synthetic_body_ir.wav")

print("")
print("完成。共 \(PipaSynth.stringCount) 根弦，音域 \(PipaTuning.noteName(PipaTuning.midi(string: 0, fret: 0))) 到 \(PipaTuning.noteName(PipaTuning.midi(string: 3, fret: 25)))。")
