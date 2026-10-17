import Foundation
import Accelerate

/// Acoustic model of the Pipa body.
///
/// The Pipa is a half-pear-shaped wooden box: a paulownia soundboard, a hardwood
/// back, and a pronounced air-cavity resonance inside, with the soundboard
/// itself carrying several modes of vibration. Five peaking filters stand in for
/// these resonances, and together they form the tonal skeleton that says this is
/// a Pipa and not a guitar.
final class PipaBody {

    private var filters: [Biquad] = []

    /// Body size scale, 1.0 is standard. Smaller means a bigger body and lower
    /// resonances.
    private let sizeScale: Double

    init(sampleRate: Double, sizeScale: Double = 1.0) {
        self.sizeScale = sizeScale
        let peaks: [(frequency: Double, q: Double, gainDB: Double)] = [
            (205, 3.5, 9.0),    // Air-cavity resonance; most of the low-register weight comes from here
            (420, 3.0, 6.0),    // First bending mode of the soundboard
            (760, 2.6, 4.5),
            (1350, 2.2, 3.5),
            (2600, 1.8, 2.5),   // High-frequency brightness; sets the grain of the metal-wound strings
        ]
        filters = peaks.map { peak in
            Biquad.peaking(
                sampleRate: sampleRate,
                frequency: peak.frequency * sizeScale,
                q: peak.q,
                gainDB: peak.gainDB
            )
        }
    }

    /// Per-sample processing, used for direct filtering outside commuted synthesis.
    func process(_ input: Float) -> Float {
        var value = input
        for index in filters.indices {
            value = filters[index].process(value)
        }
        return value
    }

    /// Reset internal state; call before switching notes.
    func reset() {
        for index in filters.indices { filters[index].reset() }
    }

    // MARK: - Commuted Synthesis

    /// Convolve a short excitation with the body impulse response to obtain a
    /// pre-convolved excitation.
    ///
    /// The point of commuted synthesis is that the two operations swap places:
    /// the body response is time-invariant, so instead of running a long
    /// convolution on every output sample, the very short excitation is
    /// convolved with the impulse response once and the result drives the
    /// string model. The timbre is equivalent while the cost drops by two or
    /// three orders of magnitude.
    /// - Parameters:
    ///   - excitation: the raw excitation, usually only a few milliseconds.
    ///   - impulseResponse: the body impulse response, either measured on a real
    ///     instrument or synthesised by this class.
    /// - Returns: the pre-convolved excitation, about as long as both inputs together.
    static func commute(excitation: [Float], impulseResponse: [Float]) -> [Float] {
        guard !excitation.isEmpty, !impulseResponse.isEmpty else { return excitation }

        let filterLength = vDSP_Length(impulseResponse.count)
        let resultLength = vDSP_Length(excitation.count) + filterLength - 1
        var result = [Float](repeating: 0, count: Int(resultLength))

        excitation.withUnsafeBufferPointer { inputPointer in
            impulseResponse.withUnsafeBufferPointer { irPointer in
                result.withUnsafeMutableBufferPointer { outputPointer in
                    vDSP_conv(
                        inputPointer.baseAddress!, 1,
                        irPointer.baseAddress!, 1,
                        outputPointer.baseAddress!, 1,
                        resultLength,
                        filterLength
                    )
                }
            }
        }

        // Normalise, so the level does not run away when the impulse response changes.
        var peak: Float = 0
        var scalar: Float = 0
        vDSP_maxmgv(result, 1, &peak, vDSP_Length(result.count))
        if peak > 1e-9 {
            scalar = 1 / peak
            vDSP_vsmul(result, 1, &scalar, &result, 1, vDSP_Length(result.count))
        }
        return result
    }

    /// Synthesise an approximate body impulse response, used as a fallback when
    /// no measured recording is available.
    ///
    /// A very short pulse is pushed through the body filter bank and the result
    /// is given an exponential envelope. The response keeps the resonance
    /// positions but is cruder than a measured one.
    static func synthesizeImpulseResponse(sampleRate: Double, lengthSeconds: Double = 0.25, sizeScale: Double = 1.0) -> [Float] {
        let body = PipaBody(sampleRate: sampleRate, sizeScale: sizeScale)
        let count = Int(sampleRate * lengthSeconds)
        var response = [Float](repeating: 0, count: count)

        // The filters ringing on a unit pulse is the bulk of the impulse
        // response; the exponential envelope cleans up the tail.
        for index in 0..<count {
            let input: Float = index == 0 ? 1.0 : 0.0
            let filtered = body.process(input)
            let decay = Float(exp(-Double(index) / (sampleRate * 0.06)))
            response[index] = filtered * decay
        }
        return response
    }
}

/// Biquad filter, transposed direct form II, numerically steadier than direct form I.
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// Peaking EQ, built after Robert Bristow-Johnson's audio filter cookbook.
    static func peaking(sampleRate: Double, frequency: Double, q: Double, gainDB: Double) -> Biquad {
        let amplitude = pow(10.0, gainDB / 40.0)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let cosOmega = cos(omega)

        let b0 = Float(1 + alpha * amplitude)
        let b1 = Float(-2 * cosOmega)
        let b2 = Float(1 - alpha * amplitude)
        let a0 = Float(1 + alpha / amplitude)
        let a1 = Float(-2 * cosOmega)
        let a2 = Float(1 - alpha / amplitude)

        var filter = Biquad()
        filter.b0 = b0 / a0
        filter.b1 = b1 / a0
        filter.b2 = b2 / a0
        filter.a1 = a1 / a0
        filter.a2 = a2 / a0
        return filter
    }
}
