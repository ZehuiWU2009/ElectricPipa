import Foundation

/// One string of the Pipa: a digital waveguide running the Karplus-Strong
/// plucked-string model.
///
/// The delay line is exactly one fundamental period long. Plucking fills the
/// whole line with shaped noise, which stands in for the initial displacement of
/// the string. Each sample reads out of the far end, passes through the loop
/// low-pass, is scaled by the loop gain and is written back where it came from.
/// High frequencies lose more energy on every round trip than low ones, so the
/// noise gradually settles into a pitched tone.
///
/// Three fixes keep the high positions from ending up "a waveform with no
/// pitch", and they are worth recording here:
///
/// 1. Every loss in the loop is charged per round trip, and the number of round
///    trips per second is the fundamental frequency itself. A ratio that is
///    harmless at 220 Hz compounds more than two thousand times a second at
///    2349 Hz and wipes the fundamental out instantly. The loop low-pass
///    response therefore has to scale with the fundamental instead of sitting at
///    a fixed absolute cutoff.
///
/// 2. Fractional delay built from linear interpolation acts as a low-pass of its
///    own, and its loss at the fundamental compounds in exactly the same way.
///    A first-order all-pass replaces it: its magnitude is identically 1, so it
///    contributes phase delay only and takes no energy away.
///
/// 3. The loop low-pass has unity gain at DC, where the decay runs tens of times
///    slower than at the fundamental. Any non-zero mean in the excitation
///    therefore survives as a low-frequency hum in the tail, so the excitation
///    is held to a strict zero mean.
final class PipaString {

    let sampleRate: Double

    /// Current fundamental frequency. Changing it moves the pitch smoothly, and
    /// push and pull bends rely on this.
    /// Bending only recomputes the delay and leaves the timbre alone, so the
    /// tone does not jump while the pitch glides.
    var frequency: Double {
        didSet { updateDelay() }
    }

    /// Delay-line storage. Capacity is reserved for the lowest possible
    /// fundamental; the live length is what `length` says.
    private var buffer: [Float] = [Float](repeating: 0, count: 4096)
    private let capacity = 4096

    /// Live length of the delay line, i.e. the integer sample delay the line
    /// itself contributes.
    private var length: Int = 2

    /// Current read/write head. Reading and writing happen in the same cell, and
    /// one lap around the buffer is `length` samples.
    private var index: Int = 0

    /// First-order all-pass coefficient and its two state cells, responsible for
    /// the fractional part of the delay.
    private var allpassCoeff: Float = 0
    private var allpassXPrev: Float = 0
    private var allpassYPrev: Float = 0

    /// Delay inside the loop that does not come from the delay line itself:
    /// low-pass phase delay plus all-pass phase delay.
    private var extraDelaySamples: Double = 0

    private var loopState: Float = 0

    /// First-order low-pass coefficient; larger is darker.
    /// This is the `a` in y[n] = (1-a)*x[n] + a*y[n-1].
    private var loopCoeff: Float = 0.5

    /// Fraction of energy kept on every round trip, which sets the tail length.
    private var damping: Float = 0.996

    /// Remembered brightness and requested decay, used to recompute whenever the
    /// timbre or the pitch changes.
    private var brightness: Double = 0.6
    private var requestedDecay: Double = 2.0


    /// Leaky integrator estimate of the energy, used to decide whether the tail
    /// has died away.
    private var energy: Float = 0

    private(set) var isRinging: Bool = false

    /// Real-time safe pseudo-random noise source (xorshift32): no allocation, no
    /// locking, used to generate the pluck excitation. Each string holds its own
    /// state, the sequence is deterministic and reproducible, and it is safe to
    /// call from the audio real-time thread.
    private var noiseState: UInt32 = 0x12345678

    init(sampleRate: Double, frequency: Double) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        updateDelay()
    }

    // MARK: - Tuning

    private var omega: Double {
        2.0 * Double.pi * max(frequency, 20.0) / sampleRate
    }

    /// Magnitude response of the loop low-pass at angular frequency w.
    private static func loopMagnitude(coeff s: Double, at w: Double) -> Double {
        let real = 1.0 - s * cos(w)
        let imag = s * sin(w)
        return (1.0 - s) / max(sqrt(real * real + imag * imag), 1e-12)
    }

    /// Phase delay of the first-order low-pass at angular frequency w.
    private static func loopPhaseDelay(coeff s: Double, at w: Double) -> Double {
        atan2(s * sin(w), 1.0 - s * cos(w)) / w
    }

    /// Phase delay of the first-order all-pass (a + z^-1)/(1 + a*z^-1) at angular
    /// frequency w. Its magnitude is identically 1, which is exactly why it can
    /// stand in for linear interpolation as fractional delay.
    private static func allpassPhaseDelay(coeff a: Double, at w: Double) -> Double {
        let numerator = atan2(-sin(w), a + cos(w))
        let denominator = atan2(-a * sin(w), 1.0 + a * cos(w))
        return -(numerator - denominator) / w
    }

    /// Solve for the loop low-pass coefficient that puts the magnitude at the
    /// fundamental exactly on targetGain. Magnitude falls monotonically with the
    /// coefficient, so bisection is stable.
    private func solveLoopCoefficient(targetGain: Double) -> Float {
        var low = 0.0
        var high = 0.9995
        for _ in 0..<36 {
            let middle = (low + high) * 0.5
            if Self.loopMagnitude(coeff: middle, at: omega) > targetGain {
                low = middle
            } else {
                high = middle
            }
        }
        return Float((low + high) * 0.5)
    }

    /// Solve for the all-pass coefficient whose phase delay equals targetDelay.
    /// Delay falls monotonically with the coefficient, so bisection is stable.
    private func solveAllpassCoefficient(targetDelay: Double) -> Float {
        var low = -0.6
        var high = 0.95
        for _ in 0..<36 {
            let middle = (low + high) * 0.5
            if Self.allpassPhaseDelay(coeff: middle, at: omega) > targetDelay {
                low = middle
            } else {
                high = middle
            }
        }
        return Float((low + high) * 0.5)
    }

    /// Map brightness from 0 to 1 onto the fraction of energy kept per round trip
    /// at the fundamental. The same number also caps the tail: bright strings
    /// ring long and dark strings ring short, which is how real instruments
    /// behave.
    private static func loopGainForBrightness(_ brightness: Double) -> Double {
        let b = min(max(brightness, 0.0), 1.0)
        return 0.990 + (0.99995 - 0.990) * b
    }

    private func updateDelay() {
        let w = omega
        let s = Double(loopCoeff)

        let lowpassDelay = Self.loopPhaseDelay(coeff: s, at: w)

        // The wanted total delay is one period. The delay line carries the
        // integer part and the all-pass carries the remainder.
        let total = sampleRate / max(frequency, 20.0)
        let remaining = total - lowpassDelay

        // Leave half a sample for the all-pass so it works in the flattest part
        // of its response.
        let integerPart = max(2, Int(floor(remaining - 0.5)))
        length = min(max(integerPart, 2), capacity - 1)
        let fractional = remaining - Double(length)

        allpassCoeff = solveAllpassCoefficient(targetDelay: fractional)
        extraDelaySamples = lowpassDelay + Self.allpassPhaseDelay(coeff: Double(allpassCoeff), at: w)

        if index >= length { index = index % length }

        applyDecay()
    }

    /// Work out how much energy per round trip the loop gain should keep so that
    /// the tail reaches the requested length at the fundamental.
    private func applyDecay() {
        let loopGain = Self.loopMagnitude(coeff: Double(loopCoeff), at: omega)
        let lossPerLoop = max(-log(loopGain), 1e-9)

        // Longest tail that can still reach a 60 dB decay at this loss per round
        // trip. Anything longer is physically out of reach; forcing it only
        // pushes total loop gain above 1 and the string self-oscillates.
        let maximumDecay = 6.9078 / (max(frequency, 20.0) * lossPerLoop)
        let effective = min(max(requestedDecay, 0.02), 0.85 * maximumDecay)

        let total = pow(0.001, 1.0 / (effective * max(frequency, 20.0)))
        damping = Float(min(total / max(loopGain, 1e-9), 0.99999))
    }

    /// Recompute the timbre whenever the pitch changes, so the same tone
    /// character holds at every position.
    private func retune() {
        loopCoeff = solveLoopCoefficient(targetGain: Self.loopGainForBrightness(brightness))
        updateDelay()
    }

    // MARK: - Parameters

    /// Fundamental the string actually sounds, equal to the sample rate divided
    /// by the total loop delay. Used to verify tuning: it depends on no signal
    /// analysis, so unlike autocorrelation it cannot misjudge the high register.
    var actualFrequency: Double {
        sampleRate / max(Double(length) + extraDelaySamples, 1.0)
    }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0.0), 1.0)
        retune()
    }

    /// Set the wanted tail length, i.e. the seconds needed to fall 60 dB. The
    /// real tail is clamped to what this string can do at this pitch.
    func setDecayTime(_ seconds: Double) {
        requestedDecay = seconds
        applyDecay()
    }

    // MARK: - Playing

    /// Real-time safe pseudo-random noise: xorshift32, returning [-1, 1].
    /// No allocation, no locking.
    private func nextNoise() -> Float {
        var x = noiseState
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        if x == 0 { x = 0x9E3779B9 }   // Guard against the all-zero degenerate state
        noiseState = x
        return Float(Int32(bitPattern: x)) / Float(Int32.max)
    }

    /// Pluck.
    ///
    /// Physically, plucking gives the string an initial displacement. Where the
    /// string is plucked decides which harmonics cancel out, reproduced here
    /// with a comb filter. The excitation has to fill a whole period, because
    /// anything shorter gets overwritten by the write-back.
    /// - Parameters:
    ///   - amplitude: velocity, 0 to 1.
    ///   - position: pluck position, 0 is toward the bridge, 1 toward the xiang,
    ///     0.5 is the conventional spot.
    func pluck(amplitude: Double, position: Double) {
        // Re-align timbre and tail on every pluck, so the same note sounds the
        // same at every position.
        retune()

        let gain = Float(min(max(amplitude, 0.0), 1.0))
        let pos = min(max(position, 0.06), 0.94)

        // The excitation is generated straight into the delay line: no
        // allocation and no runtime random source. Allocating memory or calling
        // a locking random source inside the real-time audio callback can take a
        // kernel lock and cause dropouts or even a crash.
        for i in 0..<length {
            buffer[i] = nextNoise()
        }

        // Comb filter for the pluck point: harmonics with a node at the pluck
        // point cancel out, which is why the pluck position changes the tone.
        let combDelay = max(1, Int(Double(length) * pos))
        if combDelay < length {
            for i in stride(from: length - 1, through: combDelay, by: -1) {
                buffer[i] -= buffer[i - combDelay] * 0.7
            }
        }

        // Remove the DC component. The loop low-pass has unity gain at DC, where
        // the decay is tens of times slower than at the fundamental; without
        // this the tail collapses into a low-frequency hum.
        var mean: Float = 0
        for i in 0..<length { mean += buffer[i] }
        mean /= Float(length)

        // Normalise to unit peak, then scale by velocity, so velocity changes
        // loudness only and leaves the timbre alone.
        var peak: Float = 0
        for i in 0..<length {
            buffer[i] -= mean
            peak = max(peak, abs(buffer[i]))
        }
        let scale = peak > 1e-9 ? gain / peak : 0
        for i in 0..<length { buffer[i] *= scale }

        index = 0
        loopState = 0
        allpassXPrev = 0
        allpassYPrev = 0
        energy = 1
        isRinging = true
    }

    /// Damp the string: pull the tail down quickly.
    func damp() {
        for i in 0..<length { buffer[i] *= 0.02 }
        loopState = 0
        allpassXPrev = 0
        allpassYPrev = 0
        energy = 0
        isRinging = false
    }

    /// Render one sample.
    func renderSample() -> Float {
        let raw = buffer[index]

        // The first-order all-pass supplies the fractional delay; its magnitude
        // is identically 1, so unlike linear interpolation it steals no energy
        // from the fundamental.
        let delayed = allpassCoeff * raw + allpassXPrev - allpassCoeff * allpassYPrev
        allpassXPrev = raw
        allpassYPrev = delayed

        // Loop low-pass: high frequencies lose more on every round trip, which
        // is how a string's vibration decays.
        let filtered = (1 - loopCoeff) * delayed + loopCoeff * loopState
        loopState = filtered

        buffer[index] = filtered * damping
        index = (index + 1) % length

        let magnitude = abs(filtered)
        energy = energy * 0.9995 + magnitude * magnitude
        isRinging = energy > 1e-9

        return delayed
    }
}
