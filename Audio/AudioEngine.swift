import AVFoundation
import Foundation

/// One kind of performance event.
fileprivate enum PipaEvent {
    case pluck(string: Int, fret: Int, velocity: Double, position: Double)
    case bend(string: Int, to: Double)
    case damp(string: Int)
    case dampAll
    case setBrightness(Double)
    case setMasterGain(Float)
}

/// One event with its time already resolved.
fileprivate struct ScheduledPipaEvent {
    let dueSample: Int64
    let event: PipaEvent
}

/// The kernel that actually runs on the audio thread.
///
/// The synth and the event queue both live here. To keep the real-time thread
/// free of memory allocation, locking and random sources, the event queue is a
/// bounded ring buffer with atomic indices: the main thread produces, the render
/// thread consumes. Every write to the synth also happens on the render thread
/// only. The main thread just drops performance intent into the queue, and the
/// render thread picks it up at the matching sample and applies it. The
/// AVAudioSourceNode render block can therefore capture this object safely while
/// the whole path stays allocation-free, lock-free and random-source-free, which
/// is what CoreAudio demands of a real-time callback.
final class PipaAudioCore: @unchecked Sendable {
    let sampleRate: Double
    let synth: PipaSynth

    // Bounded ring buffer for events. The capacity far exceeds the number of
    // events a single gesture can pile up.
    // Single producer (main thread), single consumer (render thread): plain
    // integer indices plus OSMemoryBarrier give lock-free synchronisation, so
    // the render thread never allocates and never locks, which is what CoreAudio
    // demands of a real-time callback.
    private let queueCapacity = 128
    private var eventQueue: ContiguousArray<ScheduledPipaEvent>
    private var enqueueIndex: Int = 0   // written by the main thread only
    private var dequeueIndex: Int = 0   // written by the render thread only
    private var rendered: Int64 = 0      // written by the render thread, read approximately by the main thread

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.synth = PipaSynth(sampleRate: sampleRate, bodySizeScale: bodySizeScale)
        self.eventQueue = ContiguousArray(repeating: ScheduledPipaEvent(dueSample: 0, event: .dampAll), count: queueCapacity)
    }

    /// Main-thread side settings: only intent is queued; the real write happens
    /// on the render thread.
    func setMasterGain(_ value: Float) { enqueue(.setMasterGain(value), at: rendered) }
    func setBrightness(_ value: Double) { enqueue(.setBrightness(value), at: rendered) }

    // MARK: - Real-time rendering

    func render(frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count > 0 else { return }

        // Cap the work at the smallest capacity across channels, so nothing is
        // ever written out of bounds.
        var n = frames
        for buf in 0..<abl.count {
            guard abl[buf].mData != nil else { n = 0; break }
            let cap = Int(abl[buf].mDataByteSize) / MemoryLayout<Float>.stride
            n = min(n, cap)
        }
        guard n > 0 else { return }

        let prod = enqueueIndex
        for i in 0..<n {
            // Pick up every event that has come due and apply it to the synth.
            // This step happens on the render thread only.
            var cons = dequeueIndex
            let now = rendered
            while cons != prod {
                let slot = cons % queueCapacity
                let ev = eventQueue[slot]
                if ev.dueSample > now { break }
                apply(ev.event)
                cons += 1
                dequeueIndex = cons
            }

            let sample = synth.renderSample()
            for buf in 0..<abl.count {
                if let pointer = abl[buf].mData?.assumingMemoryBound(to: Float.self) {
                    let cap = Int(abl[buf].mDataByteSize) / MemoryLayout<Float>.stride
                    if i < cap { pointer[i] = sample }
                }
            }
            rendered += 1
        }
    }

    private func apply(_ event: PipaEvent) {
        switch event {
        case .pluck(let string, let fret, let velocity, let position):
            synth.pluck(string: string, fret: fret, velocity: velocity, position: position)
        case .bend(let string, let frequency):
            synth.bend(string: string, to: frequency)
        case .damp(let string):
            synth.damp(string: string)
        case .dampAll:
            synth.dampAll()
        case .setBrightness(let value):
            synth.setBrightness(value)
        case .setMasterGain(let value):
            synth.masterGain = value
        }
    }

    // MARK: - Main-thread interface

    private func enqueue(_ event: PipaEvent, at dueSample: Int64) {
        let prod = enqueueIndex
        let cons = dequeueIndex
        // Drop the event when the queue is full. This almost never fires in
        // practice: missing one event is preferable to allocating on the
        // real-time thread.
        if (prod + 1) % queueCapacity == cons % queueCapacity { return }
        eventQueue[prod % queueCapacity] = ScheduledPipaEvent(dueSample: dueSample, event: event)
        OSMemoryBarrier()  // Make the slot write visible to the render thread before the index advances
        enqueueIndex = prod + 1
    }

    fileprivate func schedule(_ event: PipaEvent, atOffset seconds: Double) {
        let due = rendered + Int64(seconds * sampleRate)
        enqueue(event, at: due)
    }

    func pluck(string: Int, fret: Int, velocity: Double = 0.85, position: Double = 0.5) {
        schedule(.pluck(string: string, fret: fret, velocity: velocity, position: position), atOffset: 0)
    }

    func strum(ascending: Bool = true, velocity: Double = 0.78, spacing: Double = 0.022) {
        let order = ascending ? [0, 1, 2, 3] : [3, 2, 1, 0]
        for (offset, string) in order.enumerated() {
            let v = velocity * (1.0 - Double(offset) * 0.06)
            schedule(.pluck(string: string, fret: 0, velocity: v, position: 0.5), atOffset: spacing * Double(offset))
        }
    }

    func tremolo(string: Int, fret: Int, rate: Double, duration: Double, velocity: Double = 0.5) {
        let count = max(1, Int(rate * duration))
        for index in 0..<count {
            let time = duration * Double(index) / Double(count)
            let accent = 1.0 + 0.18 * sin(Double(index % 4) * 1.7)
            schedule(.pluck(string: string, fret: fret, velocity: velocity * accent, position: 0.55), atOffset: time)
        }
    }

    func bend(string: Int, to frequency: Double) {
        schedule(.bend(string: string, to: frequency), atOffset: 0)
    }

    func damp(string: Int) {
        schedule(.damp(string: string), atOffset: 0)
    }

    /// Tan-Tiao (弹挑): the string is struck again and again, alternating
    /// outward (tan, brighter) and inward (tiao, darker) `interval` seconds
    /// apart, for `duration` seconds — the classic continuous 弹挑 roll.
    func tanTiao(string: Int, fret: Int, velocity: Double = 0.7, position: Double = 0.5, interval: Double = 0.5, duration: Double = 5.0) {
        var t = 0.0
        var outward = true
        while t < duration {
            let pos = outward ? min(0.92, position + 0.12) : max(0.08, position - 0.12)
            let v = outward ? velocity : velocity * 0.9
            schedule(.pluck(string: string, fret: fret, velocity: v, position: pos), atOffset: t)
            t += interval
            outward.toggle()
        }
    }

    func dampAll() {
        schedule(.dampAll, atOffset: 0)
    }
}

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

    func tremolo(string: Int, fret: Int, rate: Double, duration: Double, velocity: Double = 0.5) {
        ensureStarted()
        core.tremolo(string: string, fret: fret, rate: rate, duration: duration, velocity: velocity)
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

    func dampAll() {
        core?.dampAll()
    }
}
