import Foundation

/// Four-string Pipa synthesis engine.
///
/// Each string is its own digital waveguide. The four are mixed and then fed
/// through the body filter bank together: on a real instrument all four strings
/// couple into one box, so the body is applied once rather than once per string.
final class PipaSynth {

    static let stringCount = 4

    let sampleRate: Double
    private var strings: [PipaString] = []

    /// Body resonance, applied to the mixed output of the four strings.
    private let body: PipaBody

    /// Master output gain.
    var masterGain: Float = 0.5

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.body = PipaBody(sampleRate: sampleRate, sizeScale: bodySizeScale)

        for index in 0..<Self.stringCount {
            let frequency = PipaTuning.frequency(string: index, fret: 0)
            let string = PipaString(sampleRate: sampleRate, frequency: frequency)
            // Thick strings are darker and longer, thin strings brighter and
            // shorter: the real tonal gradient across the four strings.
            let thickness = Self.stringCount > 1 ? Double(index) / Double(Self.stringCount - 1) : 0
            string.setBrightness(0.34 + 0.42 * thickness)
            string.setDecayTime(4.6 - 2.6 * thickness)
            strings.append(string)
        }
    }

    /// Pluck one string at one position.
    /// - Parameters:
    ///   - string: string index, 0 is the Chan string (thickest).
    ///   - fret: position, 0 is the open string.
    ///   - velocity: velocity, 0 to 1.
    ///   - position: right-hand pluck position. 0.5 is the conventional spot;
    ///     smaller is closer to the bridge and gives a harder tone.
    func pluck(string: Int, fret: Int, velocity: Double = 0.8, position: Double = 0.5) {
        guard strings.indices.contains(string) else { return }
        let target = strings[string]

        // Set the pitch first: both the tail length and the delay-line length
        // depend on it.
        target.frequency = PipaTuning.frequency(string: string, fret: fret)

        // Stopping the string shortens the vibrating length, so the tail
        // shortens with it.
        let thickness = Self.stringCount > 1 ? Double(string) / Double(Self.stringCount - 1) : 0
        let baseDecay = 4.6 - 2.6 * thickness
        let fretFactor = 1.0 / (1.0 + Double(fret) * 0.035)
        target.setDecayTime(baseDecay * fretFactor)

        target.pluck(amplitude: velocity, position: position)
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
        strings[string].pluck(amplitude: velocity, position: position)
    }

    /// Push or pull the string, gliding its pitch continuously to the target
    /// frequency.
    func bend(string: Int, to frequency: Double) {
        guard strings.indices.contains(string) else { return }
        strings[string].frequency = frequency
    }

    /// Damp one string.
    func damp(string: Int) {
        guard strings.indices.contains(string) else { return }
        strings[string].damp()
    }

    /// Damp every string.
    func dampAll() {
        for index in strings.indices { strings[index].damp() }
    }

    /// Set the brightness of all four strings at once, 0 dark to 1 bright.
    func setBrightness(_ value: Double) {
        for index in strings.indices { strings[index].setBrightness(value) }
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

    /// Tremolo, repeating plucks on one string at a fixed density for a while.
    /// - Parameter rate: plucks per second; professional playing reaches 8 to 12.
    func tremolo(string: Int, fret: Int, rate: Double, duration: Double, velocity: Double = 0.55) {
        let count = max(1, Int(rate * duration))
        for index in 0..<count {
            let delay = duration * Double(index) / Double(count)
            // Tremolo is thrown by index, middle, ring and little finger in
            // turn, so the velocity naturally rises and falls.
            let accent = 1.0 + 0.18 * sin(Double(index % 4) * 1.7)
            Scheduler.shared.schedule(after: delay) { [weak self] in
                self?.pluck(string: string, fret: fret, velocity: velocity * accent, position: 0.55)
            }
        }
    }

    /// Render one sample.
    func renderSample() -> Float {
        Scheduler.shared.advance(sampleRate: sampleRate)
        var sum: Float = 0
        for index in strings.indices {
            sum += strings[index].renderSample()
        }
        return body.process(sum) * masterGain
    }

    /// Render a stretch into a buffer.
    func render(into output: inout [Float], count: Int) {
        for index in 0..<count {
            output[index] = renderSample()
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
