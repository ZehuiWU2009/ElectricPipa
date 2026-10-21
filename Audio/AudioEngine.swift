import AVFoundation
import Foundation

/// The main-thread side that wires PipaSynth into the phone's real-time audio
/// engine.
///
/// It owns the AVAudioEngine lifecycle and turns UI performance intent into
/// events for PipaAudioCore. Every entry point that can make sound calls
/// ensureStarted first, satisfying the iOS rule that audio must start from a
/// user gesture.
///
/// Wiring notes, from fixing an EXC_BREAKPOINT on AURemoteIO::IOThread under
/// iOS 26: the AVAudioSourceNode format has to match the engine's real output
/// format exactly, sample rate and channel count alike, and the node connects
/// straight to the output node, bypassing the spatial mixer that iOS 26 installs
/// by default. Otherwise a sample-rate or channel converter gets inserted
/// between the source and the output, CoreAudio judges its input buffer list
/// bogus (CrashIfClientProvidedBogusAudioBufferList) and an assertion kills the
/// real-time thread.
@MainActor
final class AudioEngine: ObservableObject {
    private var core: PipaAudioCore!
    private let engine = AVAudioEngine()
    private let preferredSampleRate: Double = 48000
    private var started = false

    @Published var isRunning = false
    @Published var masterGain: Float = 0.5 {
        didSet { core?.setMasterGain(masterGain) }
    }
    @Published var brightness: Double = 0.6 {
        didSet { core?.setBrightness(brightness) }
    }

    init() {}

    func ensureStarted() {
        guard !started else { return }
        started = true
        do {
            try start()
        } catch {
            started = false
            print("音频引擎启动失败：\(error)")
        }
    }

    private func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setActive(true)

        // Read the engine's real output format: the session may fall back from
        // 48000 to whatever the device supports, and the channel count follows
        // the output. The source node has to match it exactly so that no
        // converter is inserted anywhere.
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : preferredSampleRate
        let channels: AVAudioChannelCount = outputFormat.channelCount > 0 ? outputFormat.channelCount : 2

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: rate,
                                   channels: channels,
                                   interleaved: false)!

        // Rebuild the DSP kernel at the real sample rate: pitch is defined in
        // Hz, so any rate is correct, and now the source and the output agree,
        // so no sample-rate converter can appear.
        let core = PipaAudioCore(sampleRate: rate, bodySizeScale: 1.0)
        core.setMasterGain(masterGain)
        core.setBrightness(brightness)
        self.core = core

        let source = AVAudioSourceNode(format: format,
                                       renderBlock: AudioEngine.makeRenderBlock(core: core))

        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: format)

        try engine.start()
        DispatchQueue.main.async { self.isRunning = true }
    }

    /// Render block factory, which must be created in a nonisolated context.
    ///
    /// Writing the closure directly inside the @MainActor start() makes the
    /// closure inherit MainActor isolation. When CoreAudio then calls it from
    /// the real-time IO thread, the Swift 6 runtime's MainActor.assumeIsolated
    /// check fails and the process dies on __builtin_trap(), surfacing as
    /// AURemoteIO::IOThread: EXC_BREAKPOINT. Creating the block in a nonisolated
    /// factory leaves it free of any actor isolation, so the IO thread can call
    /// it safely.
    nonisolated private static func makeRenderBlock(core: PipaAudioCore) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            core.render(frames: Int(frameCount), bufferList: audioBufferList)
            return noErr
        }
    }

    func stop() {
        engine.stop()
        started = false
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - Performance interface

    func pluck(string: Int, fret: Int, velocity: Double = 0.85, position: Double = 0.5) {
        ensureStarted()
        core.pluck(string: string, fret: fret, velocity: velocity, position: position)
    }

    func strum(ascending: Bool = true, velocity: Double = 0.78) {
        ensureStarted()
        core.strum(ascending: ascending, velocity: velocity)
    }

    /// Wheel (轮指): one string taken through a whole passage of cycles. Each
    /// cycle is the five fingers thrown in turn, so five cycles are
    /// twenty-five plucks and take 25 / rate seconds.
    func tremolo(string: Int, fret: Int, rate: Double, cycles: Double, velocity: Double = 0.5) {
        ensureStarted()
        core.tremolo(string: string, fret: fret, rate: rate, cycles: cycles, velocity: velocity)
    }

    func bend(string: Int, to frequency: Double) {
        ensureStarted()
        core.bend(string: string, to: frequency)
    }

    func damp(string: Int) {
        core?.damp(string: string)
    }

    /// Tan-Tiao (弹挑): the string is struck repeatedly, alternating outward and
    /// inward `interval` seconds apart for `duration` seconds. One metronome
    /// beat is one 弹+挑 pair — two strokes — so the UI passes
    /// interval = 30 / BPM (at 120 BPM, 240 strokes per minute).
    func tanTiao(string: Int, fret: Int, velocity: Double = 0.7, position: Double = 0.5, interval: Double = 0.5, duration: Double = 5.0) {
        ensureStarted()
        core.tanTiao(string: string, fret: fret, velocity: velocity, position: position, interval: interval, duration: duration)
    }

    // MARK: - Sustained rolls (continuous mode)

    /// Start a roll that keeps throwing strokes until it is stopped. The
    /// strokes fall on the string and position given here until the roll is
    /// moved elsewhere.
    func rollStart(kind: RollKind, string: Int, fret: Int, interval: Double,
                   velocity: Double, position: Double = 0.5) {
        ensureStarted()
        core.rollStart(kind: kind, string: string, fret: fret, interval: interval,
                       velocity: velocity, position: position)
    }

    /// Move a running roll to another string or position. The next stroke
    /// sounds the new pitch.
    func rollMove(string: Int, fret: Int) {
        core?.rollMove(string: string, fret: fret)
    }

    /// Change the stroke spacing of a running roll.
    func rollSetTempo(_ interval: Double) {
        core?.rollSetTempo(interval)
    }

    /// Stop a running roll. Strings already sounding keep ringing.
    func rollStop() {
        core?.rollStop()
    }

    func dampAll() {
        core?.dampAll()
    }
}
