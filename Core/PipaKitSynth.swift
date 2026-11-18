import Foundation

/// The instrument as it was measured: four strings of fitted partials, played
/// through the app's own engine.
///
/// This replaces the waveguide bank as the app's voice. It sounds the model
/// that was accepted by ear for the four open strings, and reaches every stop
/// position by scaling the partial stack of the same fitted string. The body
/// filter bank is deliberately not applied here — the fitted amplitudes and the
/// residual layer were measured through the instrument's body, so running the
/// peaking filter bank again would colour the tone twice.
///
/// Bridge coupling is kept: a strike on one string still sets the other three
/// ringing at their own pitches, which the four single-string fits do not
/// contain.
final class PipaKitSynth: PipaSoundEngine {

    static let stringCount = 4

    /// Pluck spots the fit was made at, one per string, in the same order as
    /// `PipaTuning`: index 0 is 缠弦 (thickest). These are the positions the
    /// fitted modal amplitudes already assume, so a pluck asking for the neutral
    /// 0.5 is passed through untouched.
    static let fittedPluckPosition: [Double] = [0.263, 0.129, 0.114, 0.306]

    let sampleRate: Double
    private let model: PipaKitModel
    private var voices: [PipaKitVoice]
    private var resonators: [SympatheticString]

    /// Frequency multiplier that brings each fitted open string onto the app's
    /// equal-tempered table. The fit measured 221.44 / 165.255 / 147.19 /
    /// 110.585 Hz, up to eleven cents above the A-d-e-a the app names, so every
    /// string is pulled onto its note instead of sounding sharp against the
    /// readout and against the tuner.
    private let tuningShift: [Double]

    /// The kit's output gain already puts one open string at the level of the
    /// take it was accepted at, so nothing else is applied here: at 1.0 the
    /// single note is exactly the accepted audio, and four strings struck
    /// together peak near 0.84 before this control, which leaves headroom.
    var masterGain: Float = 0.5

    /// Spectral tilt from the brightness control: 0 is the measured tone.
    private var tilt: Double = 0

    /// Diagnosis only. See PipaSoundEngine.
    var diagnosticVoices: Int { voices.reduce(0) { $0 + ($1.isSounding ? 1 : 0) } }
    private(set) var diagnosticPluckCount = 0

    init(model: PipaKitModel, sampleRate: Double) {
        self.model = model
        self.sampleRate = sampleRate
        self.masterGain = 0.5

        var shift: [Double] = []
        var voiceList: [PipaKitVoice] = []
        var resonatorList: [SympatheticString] = []
        shift.reserveCapacity(Self.stringCount)
        voiceList.reserveCapacity(Self.stringCount)
        resonatorList.reserveCapacity(Self.stringCount)
        for string in 0..<Self.stringCount {
            let measured = model.measuredFrequency(string: string)
            let target = PipaTuning.frequency(string: string, fret: 0)
            shift.append(measured > 0 ? target / measured : 1)
            voiceList.append(model.makeVoice(string: string,
                                             fittedPosition: Self.fittedPluckPosition[string]))
            resonatorList.append(SympatheticString(
                frequency: target, sampleRate: sampleRate,
                decayTime: PipaSynth.stringDecayTime[string]))
        }
        self.voices = voiceList
        self.resonators = resonatorList
        self.tuningShift = shift
    }

    // MARK: - Playing

    func pluck(string: Int, fret: Int, velocity: Double = 0.85, position: Double = 0.5) {
        guard voices.indices.contains(string) else { return }
        diagnosticPluckCount += 1
        let clampedFret = max(0, fret)
        let shift = tuningShift[string] * pow(2.0, Double(clampedFret) / 12.0)
        voices[string].start(shift: shift, velocity: velocity, position: position, tilt: tilt)
        exciteOthers(string: string, velocity: velocity)
    }

    /// A strike reaches the other three strings through the bridge.
    private func exciteOthers(string: Int, velocity: Double) {
        let level = Float(min(max(velocity, 0), 1))
        for other in resonators.indices where other != string {
            let coupling = PipaSynth.sympatheticCoupling[string][other]
            resonators[other].excite(Float(coupling) * level)
        }
    }

    func bend(string: Int, to frequency: Double) {
        guard voices.indices.contains(string), frequency > 0 else { return }
        let measured = model.measuredFrequency(string: string)
        guard measured > 0 else { return }
        voices[string].retune(shift: frequency / measured)
    }

    func damp(string: Int) {
        guard voices.indices.contains(string) else { return }
        voices[string].damp()
        resonators[string].damp()
    }

    func dampAll() {
        for index in voices.indices {
            voices[index].damp()
            resonators[index].damp()
        }
    }

    /// The brightness control becomes a spectral tilt. The fitted tone is the
    /// neutral point; there is no brightness route to recompute as there is on
    /// the waveguide, and shifting the partial weights is the closest honest
    /// equivalent. A note already ringing keeps the tone it was struck with.
    func setBrightness(_ value: Double) {
        tilt = (min(max(value, 0), 1) - 0.5) * 0.7
    }

    // MARK: - Rendering

    func renderSample() -> Float {
        renderFrame().left
    }

    func renderFrame() -> PipaFrame {
        var left: Float = 0
        var right: Float = 0
        for index in voices.indices {
            // A voice that has finished fading returns zero without touching
            // its partial stack.
            let frame = voices[index].renderSample()
            left += frame.left
            right += frame.right
            let sympathetic = resonators[index].renderSample()
            left += sympathetic
            right += sympathetic
        }
        return PipaFrame(left: left * masterGain, right: right * masterGain)
    }
}
