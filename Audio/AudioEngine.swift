import AVFoundation
import Foundation

/// 一类演奏事件。
fileprivate enum PipaEvent {
    case pluck(string: Int, fret: Int, velocity: Double, position: Double)
    case bend(string: Int, to: Double)
    case damp(string: Int)
    case dampAll
    case setBrightness(Double)
    case setMasterGain(Float)
}

/// 一条排好时间的事件。
fileprivate struct ScheduledPipaEvent {
    let dueSample: Int64
    let event: PipaEvent
}

/// 真正跑在音频线程上的内核。
///
/// 合成器与事件队列都收在这里。为避免在实时线程上做任何内存分配、加锁或调用随机源，
/// 事件队列用有界环形缓冲加原子序号实现（主线程生产、渲染线程消费），所有对合成器的
/// 改写也只在渲染线程里发生：主线程只把演奏意图投进队列，渲染线程在对应采样点取出并作用。
/// 这样 AVAudioSourceNode 的渲染闭包就能安全地捕获它，且全程零分配、无锁、无随机源，
/// 满足 CoreAudio 对实时回调的硬性要求。
final class PipaAudioCore: @unchecked Sendable {
    let sampleRate: Double
    let synth: PipaSynth

    // 有界环形事件队列。容量远大于一次演奏同时堆积的事件数。
    // 单生产者（主线程）单消费者（渲染线程）模式：用普通整数下标加 OSMemoryBarrier 做无锁同步，
    // 渲染线程全程不分配内存、不加锁，满足 CoreAudio 实时回调的硬性要求。
    private let queueCapacity = 128
    private var eventQueue: ContiguousArray<ScheduledPipaEvent>
    private var enqueueIndex: Int = 0   // 仅主线程写
    private var dequeueIndex: Int = 0   // 仅渲染线程写
    private var rendered: Int64 = 0      // 渲染线程写，主线程近似读

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.synth = PipaSynth(sampleRate: sampleRate, bodySizeScale: bodySizeScale)
        self.eventQueue = ContiguousArray(repeating: ScheduledPipaEvent(dueSample: 0, event: .dampAll), count: queueCapacity)
    }

    /// 主线程侧设置：只投递意图，真正的改写发生在渲染线程。
    func setMasterGain(_ value: Float) { enqueue(.setMasterGain(value), at: rendered) }
    func setBrightness(_ value: Double) { enqueue(.setBrightness(value), at: rendered) }

    // MARK: - 实时渲染

    func render(frames: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(bufferList)
        guard abl.count > 0 else { return }

        // 以所有声道里最小的容量为上限，避免写入越界。
        var n = frames
        for buf in 0..<abl.count {
            guard abl[buf].mData != nil else { n = 0; break }
            let cap = Int(abl[buf].mDataByteSize) / MemoryLayout<Float>.stride
            n = min(n, cap)
        }
        guard n > 0 else { return }

        let prod = enqueueIndex
        for i in 0..<n {
            // 取出所有已到点的事件，作用到合成器上。这一步只在渲染线程发生。
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

    // MARK: - 主线程接口

    private func enqueue(_ event: PipaEvent, at dueSample: Int64) {
        let prod = enqueueIndex
        let cons = dequeueIndex
        // 队列满则丢弃（实时场景极少触发：宁可漏一个事件，也不在实时线程分配内存）。
        if (prod + 1) % queueCapacity == cons % queueCapacity { return }
        eventQueue[prod % queueCapacity] = ScheduledPipaEvent(dueSample: dueSample, event: event)
        OSMemoryBarrier()  // 确保槽位写入对渲染线程可见，再推进下标
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

    func dampAll() {
        schedule(.dampAll, atOffset: 0)
    }
}

/// 把 PipaSynth 接到手机的实时音频引擎（主线程侧）。
///
/// 它负责 AVAudioEngine 的生命周期，并把 UI 的演奏意图转交给 PipaAudioCore。
/// 所有会触发音频的入口都先调用 ensureStarted，满足 iOS「音频须在用户手势后启动」的要求。
///
/// 装配要点（修复 iOS 26 上 AURemoteIO::IOThread 的 EXC_BREAKPOINT）：
/// AVAudioSourceNode 的格式必须严格等于引擎实际的输出格式（采样率 + 声道数），
/// 并直接连到 outputNode，绕开 iOS 26 默认的空间混音器。否则源节点与输出之间会被
/// 插入采样率/声道数转换器，其输入缓冲区列表会被 CoreAudio 判为「bogus」
/// （CrashIfClientProvidedBogusAudioBufferList），触发实时线程上的断言崩溃。
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

        // 读引擎真实的输出格式：会话可能把 48000 回退到设备实际支持的采样率，
        // 声道数也以输出为准。源节点必须与它完全一致，杜绝中间的格式转换。
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let rate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : preferredSampleRate
        let channels: AVAudioChannelCount = outputFormat.channelCount > 0 ? outputFormat.channelCount : 2

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: rate,
                                   channels: channels,
                                   interleaved: false)!

        // 用真实采样率重建 DSP 内核：音高以频率(Hz)为准，任何采样率都正确，
        // 且此时源节点采样率与输出一致，不会再插入采样率转换器。
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

    /// 渲染块工厂，必须在 nonisolated 上下文里创建。
    ///
    /// 如果在 `@MainActor` 的 start() 里直接写闭包，闭包会继承 MainActor 隔离；
    /// CoreAudio 从实时 IO 线程调用它时，Swift 6 运行时的
    /// `MainActor.assumeIsolated` 检查失败，会直接 `__builtin_trap()`
    /// —— 表现为 `AURemoteIO::IOThread: EXC_BREAKPOINT`，进程当场死掉。
    /// 放进 nonisolated 工厂后闭包不带任何 actor 隔离，IO 线程调用即安全。
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
        core?.damp(string: string)
    }

    func dampAll() {
        core?.dampAll()
    }
}
