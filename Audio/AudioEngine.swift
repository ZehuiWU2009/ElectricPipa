import AVFoundation
import Foundation

/// 一类演奏事件。
fileprivate enum PipaEvent {
    case pluck(string: Int, fret: Int, velocity: Double, position: Double)
    case bend(string: Int, to: Double)
    case damp(string: Int)
    case dampAll
}

/// 一条排好时间的事件。
fileprivate struct ScheduledPipaEvent {
    let dueSample: Int64
    let event: PipaEvent
}

/// 真正跑在音频线程上的内核。
///
/// 合成器、事件队列、已渲染样本数都收在这里。它被打上 `@unchecked Sendable`：
/// 调用方保证只在音频线程上改写合成器、只在主线程上通过受锁保护的队列投递事件，因此不会有真正的竞争。
/// 这样 AVAudioSourceNode 的渲染闭包就能安全地捕获它，而不是捕获整个 AudioEngine。
final class PipaAudioCore: @unchecked Sendable {
    let sampleRate: Double
    let synth: PipaSynth

    private var pending: [ScheduledPipaEvent] = []
    private let lock = NSLock()
    private var renderedSamples: Int64 = 0

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.synth = PipaSynth(sampleRate: sampleRate, bodySizeScale: bodySizeScale)
    }

    func setMasterGain(_ value: Float) { synth.masterGain = value }
    func setBrightness(_ value: Double) { synth.setBrightness(value) }

    // MARK: - 实时渲染

    func render(frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let pointer = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let capacity = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.stride

        for i in 0..<min(frames, capacity) {
            // 取出所有到点的事件，作用到合成器上。这一步只在音频线程发生。
            lock.lock()
            var due: [ScheduledPipaEvent] = []
            while let first = pending.first, first.dueSample <= renderedSamples {
                due.append(pending.removeFirst())
            }
            lock.unlock()
            for item in due { apply(item.event) }

            pointer[i] = synth.renderSample()
            renderedSamples += 1
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
        }
    }

    // MARK: - 主线程接口

    fileprivate func schedule(_ event: PipaEvent, atOffset seconds: Double) {
        lock.lock()
        let due = renderedSamples + Int64(seconds * sampleRate)
        pending.append(ScheduledPipaEvent(dueSample: due, event: event))
        pending.sort { $0.dueSample < $1.dueSample }
        lock.unlock()
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

    func dampAll() {
        schedule(.dampAll, atOffset: 0)
    }
}

/// 把 PipaSynth 接到手机的实时音频引擎（主线程侧）。
///
/// 它负责 AVAudioEngine 的生命周期，并把 UI 的演奏意图转交给 PipaAudioCore。
/// 所有会触发音频的入口都先调用 ensureStarted，满足 iOS「音频须在用户手势后启动」的要求。
@MainActor
final class AudioEngine: ObservableObject {
    private let core: PipaAudioCore
    private let engine = AVAudioEngine()
    private let sampleRate: Double = 48000
    private var started = false

    @Published var isRunning = false
    @Published var masterGain: Float = 0.5 {
        didSet { core.setMasterGain(masterGain) }
    }
    @Published var brightness: Double = 0.6 {
        didSet { core.setBrightness(brightness) }
    }

    init() {
        self.core = PipaAudioCore(sampleRate: sampleRate, bodySizeScale: 1.0)
        self.core.setMasterGain(0.5)
        self.core.setBrightness(0.6)
    }

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
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!

        let core = self.core
        let source = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            core.render(frames: Int(frameCount), bufferList: audioBufferList)
            return noErr
        }

        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, options: [.mixWithOthers])
        try session.setPreferredSampleRate(sampleRate)
        try session.setActive(true)

        try engine.start()
        DispatchQueue.main.async { self.isRunning = true }
    }

    func stop() {
        engine.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - 对外演奏接口

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
        core.damp(string: string)
    }

    func dampAll() {
        core.dampAll()
    }
}
