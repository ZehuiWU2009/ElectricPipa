import Foundation

/// One stereo frame. The app is a stereo instrument: the measured model carries
/// a right-channel gain and phase per partial, so the two strings that sit on
/// opposite sides of the bridge do not collapse into one point.
struct PipaFrame {
    var left: Float
    var right: Float

    init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }

    init(mono: Float) {
        left = mono
        right = mono
    }
}

/// What the audio core needs from a sound model.
///
/// Two models implement it: the Karplus-Strong waveguide bank (`PipaSynth`) and
/// the measured modal model of the recorded instrument (`PipaKitSynth`). The
/// core knows nothing else about either, so switching between them is a choice
/// made when the engine is built, not a branch inside the render loop.
protocol PipaSoundEngine: AnyObject {
    var masterGain: Float { get set }

    func pluck(string: Int, fret: Int, velocity: Double, position: Double)
    func bend(string: Int, to frequency: Double)
    func damp(string: Int)
    func dampAll()
    func setBrightness(_ value: Double)
    func renderFrame() -> PipaFrame

    /// Diagnosis only: how many voices the model currently considers sounding.
    /// A kernel that keeps applying plucks while this stays zero is not a gain
    /// problem — the voice never started. The render thread writes it; a plain
    /// Int read from the main thread is fine for a probe.
    var diagnosticVoices: Int { get }
    /// Diagnosis only: whether a pluck actually reached the model. Counted here
    /// rather than in the core so a model that silently drops a pluck shows up.
    var diagnosticPluckCount: Int { get }
}
