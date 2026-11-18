import Foundation

/// Four-string Pipa synthesis engine.
///
/// Each string is its own digital waveguide. The four are mixed and then fed
/// through the body filter bank together: on a real instrument all four strings
/// couple into one box, so the body is applied once rather than once per string.
final class PipaSynth: PipaSoundEngine {

    static let stringCount = 4

    /// How long the direct voice takes to rise after the pick releases the
    /// string. Measured from the first pluck of each take: the thick strings
    /// take about 10 ms to reach their full level, the thin ones about 4 ms.
    /// This is an output envelope, not a change to the waveguide: the fitted
    /// steady spectrum is left alone.
    static let stringAttackSeconds: [Double] = [0.010, 0.005, 0.006, 0.004]

    let sampleRate: Double
    private var strings: [PipaString] = []
    private var resonators: [SympatheticString] = []
    private var attackElapsed: [Int] = []
    private var attackLength: [Int] = []

    /// Body resonance, applied to the mixed output of the four strings.
    private let body: PipaBody

    /// Master output gain.
    var masterGain: Float = 0.5

    /// Diagnosis only. See PipaSoundEngine. A waveguide string counts as
    /// sounding while its energy is above the level that is still audible.
    var diagnosticVoices: Int { strings.reduce(0) { $0 + ($1.isRinging ? 1 : 0) } }
    private(set) var diagnosticPluckCount = 0

    /// Per-string brightness and decay, fitted against a recorded set of four
    /// open strings on a Jiaozhi huangtan Pipa (48 kHz, 24-bit, Zoom H6).
    ///
    /// Index 0 is the Chan string. Thick strings are darker and ring longer,
    /// thin strings brighter and shorter, and the fit reproduces that gradient
    /// from the recordings rather than from a guess: 40 s of decay on the Chan
    /// string down to 6.4 s on the Zi string.
    ///
    /// Brightness sits near the top of its range on purpose. On the recorded
    /// instrument the fundamental is 35 to 40 dB below the fourth harmonic, and
    /// a darker setting cannot hold that much high-frequency content alive.
    static let stringBrightness: [Double] = [0.9704, 0.9852, 0.9927, 0.9968]
    static let stringDecayTime: [Double] = [40.00, 21.86, 10.86, 6.20]

    /// Where the right hand strikes each string, as a fraction of the speaking
    /// length. Measured off the recordings: between a fifth and a third of the
    /// string from the bridge, not the middle. The middle of a string is where
    /// the fourth harmonic has a node, which is why the old 0.5 setting thinned
    /// the tone out.
    static let stringPluckPosition: [Double] = [0.263, 0.129, 0.114, 0.306]

    /// How sharply the comb notch cuts at each pluck point, fitted together
    /// with the positions above. A narrow celluloid pick digs a deep notch;
    /// the thicker Chan string smears it. 0.7 was the old one-size-fits-all
    /// value that left the middle two strings far from the recorded spectrum.
    static let stringCombDepth: [Double] = [0.7904, 0.9850, 0.9850, 0.9850]

    /// Direct loop low-pass coefficient for the steel Zi string. The fitted
    /// brightness route leaves this string at s about 0.144, which rolls off
    /// 8-12 kHz by more than 40 dB against the recording. The Zi string is the
    /// bright one on a real instrument: its metal partials are what give a Pipa
    /// its edge. Fixing s at 0.05 keeps those partials alive while decay still
    /// controls the tail independently. The other three strings keep the fitted
    /// route. Measured against three takes; nil means use the fitted route.
    static let stringDirectLoopCoeff: [Double?] = [nil, nil, nil, 0.05]

    /// Bridge coupling between each pair of open strings. Plucking one string
    /// drives the bridge, and the other three answer at their own pitches.
    /// Six numbers, one per pair, fitted from the narrow peaks at the other
    /// strings' fundamentals in the same recordings. The 220 Hz string is the
    /// strongest voice: a 110 Hz peak while it sounds cannot come from its own
    /// harmonics, so it has to be the Chan string ringing along. Conversely the
    /// Chan string's 220 Hz peak is its own second harmonic and cannot be used
    /// to measure the coupling back, so that direction shares the pair value.
    static let sympatheticCoupling: [[Double]] = [
        [0.0000, 0.0032, 0.0031, 0.0074],   // Chan -> Lao, Zhong, Zi
        [0.0032, 0.0000, 0.0036, 0.0054],   // Lao
        [0.0031, 0.0036, 0.0000, 0.0055],   // Zhong
        [0.0074, 0.0054, 0.0055, 0.0000],   // Zi
    ]

    /// Global tone trim, 0.5 is neutral. The per-string values above are the
    /// measured truth, so the brightness control shifts them together instead of
    /// overwriting them.
    private var brightnessTrim: Double = 0.5

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.body = PipaBody(sampleRate: sampleRate, sizeScale: bodySizeScale)

        for index in 0..<Self.stringCount {
            let frequency = PipaTuning.frequency(string: index, fret: 0)
            let string = PipaString(sampleRate: sampleRate, frequency: frequency)
            string.setBrightness(Self.stringBrightness[index])
            string.setDecayTime(Self.stringDecayTime[index])
            string.combDepth = Self.stringCombDepth[index]
            string.directLoopCoeff = Self.stringDirectLoopCoeff[index]
            strings.append(string)
            resonators.append(SympatheticString(
                frequency: frequency,
                sampleRate: sampleRate,
                decayTime: Self.stringDecayTime[index]))
            attackLength.append(max(1, Int((Self.stringAttackSeconds[index] * sampleRate).rounded())))
            attackElapsed.append(0)
        }
    }

    /// Pluck one string at one position.
    /// - Parameters:
    ///   - string: string index, 0 is the Chan string (thickest).
    ///   - fret: position, 0 is the open string.
    ///   - velocity: velocity, 0 to 1.
    ///   - position: right-hand pluck position in the conventional scale, where
    ///     0.5 means the middle of the string. This is not a fraction of the
    ///     speaking length: the hand does not play in the middle, so 0.5 is
    ///     mapped onto the measured spot for that string and everything else
    ///     scales with it. A smaller value is closer to the bridge.
    func pluck(string: Int, fret: Int, velocity: Double = 0.8, position: Double = 0.5) {
        guard strings.indices.contains(string) else { return }
        diagnosticPluckCount += 1
        let target = strings[string]

        // Set the pitch first: both the tail length and the delay-line length
        // depend on it.
        target.frequency = PipaTuning.frequency(string: string, fret: fret)

        // Stopping the string shortens the vibrating length, so the tail
        // shortens with it.
        let baseDecay = Self.stringDecayTime[string]
        let fretFactor = 1.0 / (1.0 + Double(fret) * 0.035)
        target.setDecayTime(baseDecay * fretFactor)

        target.pluck(amplitude: velocity, position: Self.measuredPosition(position, string: string))
        attackElapsed[string] = 0

        exciteOthers(string: string, velocity: velocity)
    }

    /// A strike travels through the bridge into the strings that were not
    /// touched. They answer at their own open pitch, quietly and with a short
    /// build-up rather than a click: the bridge has to start them moving.
    private func exciteOthers(string: Int, velocity: Double) {
        for other in resonators.indices where other != string {
            let coupling = Self.sympatheticCoupling[string][other]
            resonators[other].excite(Float(coupling * min(max(velocity, 0.0), 1.0)))
        }
    }

    /// Map a conventional pluck position onto the measured region for a string.
    ///
    /// 0.5 is the middle of the string in the old scale and maps to the fitted
    /// spot; 0.4 or 0.6 land the same 20 percent nearer or further from the
    /// bridge, which keeps the relative spacing of tan-tiao and the wheel
    /// strokes intact while moving the whole hand to where it actually plays.
    static func measuredPosition(_ conventional: Double, string: Int) -> Double {
        let base = stringPluckPosition[min(max(string, 0), stringPluckPosition.count - 1)]
        return min(max(base * (conventional / 0.5), 0.05), 0.95)
    }

    /// For verification: set one string to a position and return the fundamental
    /// the delay line actually produces. This value is free of signal-analysis
    /// error, so it is what the whole-range tuning check runs on.
    func measuredFrequency(string: Int, fret: Int) -> Double {
        guard strings.indices.contains(string) else { return 0 }
        let target = strings[string]
        target.frequency = PipaTuning.frequency(string: string, fret: fret)
        return target.actualFrequency
    }

    /// Sound an arbitrary frequency, used as the starting point for harmonics
    /// and slides.
    func pluckFrequency(string: Int, frequency: Double, velocity: Double = 0.8, position: Double = 0.5) {
        guard strings.indices.contains(string) else { return }
        strings[string].frequency = frequency
        strings[string].pluck(amplitude: velocity,
                              position: Self.measuredPosition(position, string: string))
        attackElapsed[string] = 0
        exciteOthers(string: string, velocity: velocity)
    }

    /// Push or pull the string, gliding its pitch continuously to the target
    /// frequency.
    func bend(string: Int, to frequency: Double) {
        guard strings.indices.contains(string) else { return }
        strings[string].frequency = frequency
    }

    /// Damp one string. Pressing a string stops its own waveguide and the
    /// sympathetic voice it was carrying, which is what a player hears when
    /// they lay a finger across an instrument that is ringing.
    func damp(string: Int) {
        guard strings.indices.contains(string) else { return }
        strings[string].damp()
        resonators[string].damp()
    }

    /// Damp every string.
    func dampAll() {
        for index in strings.indices {
            strings[index].damp()
            resonators[index].damp()
        }
    }

    /// Shift the tone of all four strings together, 0.5 being the measured
    /// setting. The per-string values stay the baseline: a global control that
    /// overwrote them would throw away the fit, which is why this is a trim and
    /// not an assignment.
    func setBrightness(_ value: Double) {
        brightnessTrim = min(max(value, 0.0), 1.0)
        applyBrightness()
    }

    private func applyBrightness() {
        let offset = (brightnessTrim - 0.5) * 0.6
        for index in strings.indices {
            let base = Self.stringBrightness[index]
            strings[index].setBrightness(min(max(base + offset, 0.02), 1.0))
        }
    }

    /// Strum, sounding the four strings in quick succession.
    /// - Parameter ascending: true sweeps from the Chan string toward the Zi
    ///   string (fu), false the other way (sao).
    func strum(ascending: Bool = true, velocity: Double = 0.75, spacing: Double = 0.018) {
        let order = ascending ? Array(0..<Self.stringCount) : Array((0..<Self.stringCount).reversed())
        for (offset, string) in order.enumerated() {
            let delay = spacing * Double(offset)
            Scheduler.shared.schedule(after: delay) { [weak self] in
                self?.pluck(string: string, fret: 0, velocity: velocity * (1.0 - Double(offset) * 0.06))
            }
        }
    }

    /// Wheel (轮指): the five fingers thrown in turn — index, middle, ring,
    /// little, thumb — repeating on one string at a fixed density for a
    /// number of cycles, so one cycle of the wheel is five plucks with the
    /// accent on the first. Each finger strikes at its own spot and its own
    /// weight, which is what separates a wheel from tan-tiao (弹挑).
    ///
    /// A passage is counted in cycles rather than seconds: five cycles are
    /// twenty-five plucks and take 25 / rate seconds. For a wheel that goes on
    /// until the player stops it, drive a roll instead.
    /// - Parameter rate: plucks per second; a full five-finger cycle takes
    ///   5 / rate seconds. Professional playing reaches 8 to 12.
    func tremolo(string: Int, fret: Int, rate: Double, cycles: Double, velocity: Double = 0.55) {
        let fingers = WheelFinger.allCases
        let count = max(1, Int((cycles * Double(fingers.count)).rounded()))
        for index in 0..<count {
            let finger = fingers[index % fingers.count]
            Scheduler.shared.schedule(after: Double(index) / rate) { [weak self] in
                self?.pluck(string: string, fret: fret,
                            velocity: velocity * finger.velocityScale,
                            position: finger.position)
            }
        }
    }

    /// Render one sample.
    func renderSample() -> Float {
        Scheduler.shared.advance(sampleRate: sampleRate)
        var sum: Float = 0
        for index in strings.indices {
            let direct = strings[index].renderSample()
            sum += direct * attackGain(index)
            sum += resonators[index].renderSample()
        }
        return body.process(sum) * masterGain
    }

    /// Smooth rise from silence to full level over the measured few
    /// milliseconds. A cosine keeps both the start and the end free of the
    /// step that a linear ramp would put at either edge. The waveguide keeps
    /// running underneath, so only the onset changes; every harmonic measured
    /// from 100 ms onward is untouched.
    private func attackGain(_ index: Int) -> Float {
        let elapsed = attackElapsed[index]
        let length = attackLength[index]
        if elapsed >= length { return 1 }
        attackElapsed[index] = elapsed + 1
        let phase = Float(elapsed) / Float(length)
        return Float(0.5 - 0.5 * cos(Double.pi * Double(phase)))
    }

    /// The core asks for a stereo frame; a waveguide string is mono, so both
    /// channels carry the same sample.
    func renderFrame() -> PipaFrame {
        PipaFrame(mono: renderSample())
    }

    /// Render a stretch into a buffer.
    func render(into output: inout [Float], count: Int) {
        for index in 0..<count {
            output[index] = renderSample()
        }
    }
}

/// One open string answering a pluck on another string.
///
/// The bridge is a shared path, so every strike sets all four strings in
/// motion, not just the one the pick touched. A driven string does not start
/// with the sharp transient of a pluck: it takes a few milliseconds to build
/// up and then rings at its own pitch, which is why the same physics is a
/// different sound from the direct voice. A rotating phasor keeps the frequency
/// exact without accumulating the phase error that a large angle would cause
/// after minutes of continuous sound.
struct SympatheticString {
    private let cosStep: Float
    private let sinStep: Float
    private let decayPerSample: Float
    private let attackPerSample: Float
    private var real: Float = 1
    private var imag: Float = 0
    private var level: Float = 0
    private var target: Float = 0

    init(frequency: Double, sampleRate: Double, decayTime: Double) {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        cosStep = Float(cos(omega))
        sinStep = Float(sin(omega))
        decayPerSample = Float(exp(-1.0 / (max(decayTime, 0.05) * sampleRate)))
        attackPerSample = Float(1.0 - exp(-1.0 / (0.03 * sampleRate)))
    }

    mutating func excite(_ amount: Float) {
        target = max(target, min(max(amount, 0), 1))
    }

    mutating func damp() {
        target = 0
        level = 0
        real = 1
        imag = 0
    }

    mutating func renderSample() -> Float {
        target *= decayPerSample
        level += (target - level) * attackPerSample
        let value = imag * level
        let nextReal = real * cosStep - imag * sinStep
        imag = real * sinStep + imag * cosStep
        real = nextReal
        return value
    }
}

/// The five fingers of the right hand in the order a wheel (轮指) throws
/// them: index, middle, ring, little, thumb.
///
/// A real wheel is five strokes in a cycle, not four. Modelling it as four
/// throws makes the accent recur every four plucks, which the ear groups as
/// 2 + 2 pairs — exactly the two-against-two feel of tan-tiao (弹挑). Five
/// per cycle, with the thumb answering against the grain, is what a wheel
/// sounds like.
enum WheelFinger: CaseIterable {
    case index, middle, ring, little, thumb

    /// How hard this finger strikes, relative to the others. The four
    /// throwing fingers weaken toward the little finger, the shortest and
    /// last thrown; the thumb answers against the grain and comes back the
    /// strongest, closing each cycle with a lift instead of a click.
    var velocityScale: Double {
        switch self {
        case .index: return 1.00
        case .middle: return 0.95
        case .ring: return 0.88
        case .little: return 0.82
        case .thumb: return 1.06
        }
    }

    /// Where this finger strikes, in the conventional scale where 0.5 is the
    /// middle of the string: smaller is closer to the bridge and harder. The
    /// four throwing fingers creep toward the bridge as they weaken; the thumb
    /// sits on the other side of the group. PipaSynth maps the whole set onto
    /// the measured pluck region when the stroke is played.
    var position: Double {
        switch self {
        case .index: return 0.50
        case .middle: return 0.52
        case .ring: return 0.54
        case .little: return 0.56
        case .thumb: return 0.47
        }
    }
}

/// A minimal sample-accurate event scheduler, used to lay out the time offsets
/// of strums and tremolos during offline rendering.
final class Scheduler: @unchecked Sendable {
    static let shared = Scheduler()

    private var events: [(time: Double, action: () -> Void)] = []
    private var elapsed: Double = 0

    func schedule(after seconds: Double, action: @escaping () -> Void) {
        events.append((elapsed + seconds, action))
        events.sort { $0.time < $1.time }
    }

    func advance(sampleRate: Double) {
        elapsed += 1.0 / sampleRate
        while let first = events.first, first.time <= elapsed {
            events.removeFirst()
            first.action()
        }
    }

    func reset() {
        events.removeAll()
        elapsed = 0
    }
}
