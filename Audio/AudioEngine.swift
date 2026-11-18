import AVFoundation
import Foundation
import UIKit

/// Which synthesis model the engine should sound.
///
/// `measured` is the modal model fitted from the recorded instrument and
/// accepted by ear on the four open strings. `waveguide` is the Karplus-Strong
/// bank the app shipped with before. Both run through the same event queue and
/// the same render block, so switching is a rebuild of the kernel, not a second
/// audio path.
enum PipaSoundModel: String, CaseIterable, Identifiable {
    case measured
    case waveguide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .measured: return "实测模态"
        case .waveguide: return "波导模型"
        }
    }

    var detail: String {
        switch self {
        case .measured:
            return "四根空弦取自实琴录音拟合的模态参数，按品移位后发声。"
        case .waveguide:
            return "Karplus-Strong 数字波导，按音高实时生成。"
        }
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
    private var core: PipaAudioCore?
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let preferredSampleRate: Double = 48000
    private var started = false
    /// Session activation runs on a background queue. Until it finishes the
    /// output format is not final, so starting the engine early would wire the
    /// source node to a format the output later changes — the exact mismatch
    /// that inserts a converter and kills the render thread. A pluck arriving
    /// in that window is dropped and `pendingStart` retries once ready.
    private var sessionReady = false
    private var pendingStart = false

    /// Cached measured model, one per device sample rate. Loading decodes 2.3 MB
    /// of parameters and residual audio, which is far too much for the render
    /// thread and pointless to repeat on every engine restart.
    private var kitModel: PipaKitModel?
    private var kitModelRate: Double = 0

    /// Surfaced in the UI when the audio session refuses to start, so a silent
    /// instrument is never mistaken for a broken view.
    @Published var startupError: String?
    @Published var isRunning = false
    @Published var masterGain: Float = 0.5 {
        didSet { core?.setMasterGain(masterGain) }
    }
    /// Tone trim, 0.5 means "as measured on the real instrument". 0.6 used to
    /// be the default when brightness was an absolute per-string setting; with
    /// the fitted values now baked into the strings, neutral is the middle.
    @Published var brightness: Double = 0.5 {
        didSet { core?.setBrightness(brightness) }
    }
    /// The model the player asked for. Changing it rebuilds the kernel, on the
    /// next turn of the run loop rather than inside the view update that
    /// changed the picker, because the rebuild publishes its own state.
    @Published var soundModel: PipaSoundModel = .measured {
        didSet {
            guard soundModel != oldValue else { return }
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
        }
    }
    /// What is actually sounding. It stays on the waveguide when the measured
    /// resources could not be loaded, and the settings row says so.
    @Published private(set) var activeModel: PipaSoundModel = .measured
    @Published private(set) var modelNote: String?

    /// Block-based notification observers unregister themselves the moment
    /// their token is released. The first version discarded both tokens, so
    /// neither the interruption nor the route hook ever fired and an engine
    /// stopped by the system never came back. Holding them for the engine's
    /// lifetime is what actually keeps the recovery alive.
    private var notificationTokens: [NSObjectProtocol] = []

    /// Session work must stay off the main thread. iOS logs "This method can
    /// lead to UI unresponsiveness" when setActive is called there, and a call
    /// that lands while another app still holds the session can block the view
    /// for a noticeable moment — or fail, which used to clear the kernel and
    /// leave the instrument permanently silent. Everything session-related
    /// goes through this background queue; `sessionReady` gates the engine
    /// until the output format is final.
    private let sessionQueue = DispatchQueue(label: "com.zehuiwu.electricpipa.session",
                                             qos: .userInitiated)

    init() {
        configureSession()
        // The system can stop AVAudioEngine behind our back: an incoming call,
        // Siri, another app taking the session, or the app going to the
        // background. The notification block is not MainActor-isolated, so
        // pull out the plain values first and hop back before touching state.
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType),
                  let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            Task { @MainActor in self.handleInterruption(type: type, options: options) }
        })
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.rebuildAfterRouteChange() }
        })
    }

    @discardableResult
    func ensureStarted() -> Bool {
        // Trust our own flag, and let the interruption notification clear it.
        //
        // An earlier version asked `engine.isRunning` here on every pluck. On
        // a real iPhone that property reports false for a moment around a
        // session or route switch even while the render thread is alive, and
        // each such false made this path tear down the core and stop/restart
        // the engine. Stop/start makes CoreAudio replay the previous buffer,
        // which is heard as a stuck note repeating in short clicks. Now only
        // the explicit .began handler stops the engine, so a pluck can never
        // rebuild it behind the render thread's back.
        if started, core != nil { return true }
        // The session is still activating in the background. Remember that a
        // start was asked for and let configureSession() finish it; starting
        // now would read a format the session is about to change.
        guard sessionReady else {
            pendingStart = true
            return false
        }
        started = true
        do {
            try start()
            startupError = nil
            return true
        } catch {
            started = false
            core = nil
            startupError = String(describing: error)
            print("[ElectricPipa] 音频引擎启动失败：\(error)")
            return false
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType,
                                    options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            // An interruption is the one event that really does stop the
            // engine, so this is the place to tear it down. Clearing `started`
            // here is what makes the next pluck go through start() again. Do
            // not infer this state by polling isRunning from a pluck — that
            // property lies for a moment around route/session switches, and
            // rebuilding on that false reading is what caused the stutter.
            if engine.isRunning { engine.stop() }
            if let sourceNode {
                engine.detach(sourceNode)
                self.sourceNode = nil
            }
            core = nil
            started = false
            isRunning = false
            print("[ElectricPipa] 收到音频中断 began，引擎已停止")
        case .ended:
            print("[ElectricPipa] 收到音频中断 ended，shouldResume=\(options.contains(.shouldResume))")
            if options.contains(.shouldResume) { reactivateSessionAndRestart() }
        @unknown default:
            // A future interruption type gets the same treatment as "ended":
            // try to come back, which is harmless if the engine is already up.
            reactivateSessionAndRestart()
        }
    }

    /// Configure the session once at launch, off the main thread. iOS warns
    /// when setCategory/setActive run on the main thread because they can block
    /// for a long time while another app still holds the session. The
    /// background queue keeps the main thread free; `start()` only wires
    /// the nodes once this is done.
    private func configureSession() {
        let rate = preferredSampleRate
        // The warning is specifically about calling setActive on the MAIN
        // thread. Doing the whole configure-and-activate sequence on a
        // background queue keeps the view responsive and works on iOS 17,
        // where the async activate/deactivate API does not exist yet.
        sessionQueue.async { [weak self] in
            let session = AVAudioSession.sharedInstance()
            let problem: String?
            do {
                try session.setCategory(.playback, options: [.mixWithOthers])
                try session.setPreferredSampleRate(rate)
                try session.setActive(true)
                problem = nil
            } catch {
                problem = "音频会话配置失败：\(error)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                // The output format is final now, even if activation failed:
                // let start() try and report its own error rather than leaving
                // a pluck permanently parked behind a closed gate.
                self.sessionReady = true
                if let problem {
                    self.startupError = problem
                    print(problem)
                }
                if self.pendingStart {
                    self.pendingStart = false
                    _ = self.ensureStarted()
                }
            }
        }
    }

    /// The interruption ended and the system gave the session back. Reactivate
    /// off the main thread, then rebuild the engine only after it succeeds.
    /// Calling setActive synchronously from the interruption handler is what
    /// produced the "UI unresponsiveness" warning and, on failure, cleared the
    /// kernel and left the instrument silent for good.
    private func reactivateSessionAndRestart() {
        sessionQueue.async { [weak self] in
            let problem: String?
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                problem = nil
            } catch {
                problem = "音频会话恢复失败：\(error)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let problem {
                    self.startupError = problem
                    print(problem)
                    return
                }
                self.startupError = nil
                _ = self.ensureStarted()
            }
        }
    }

    /// A headphone or Bluetooth switch can post several route-change
    /// notifications in a row. Rebuilding on each one means several stop/start
    /// cycles close together, and every one of them makes CoreAudio replay a
    /// buffer — the same stuck, stuttering note as the isRunning bug. Debounce
    /// to one rebuild after the route has settled.
    private weak var routeRebuildWork: DispatchWorkItem?

    private func rebuildAfterRouteChange() {
        print("[ElectricPipa] 输出路由变化，准备重建")
        // Headphones or a Bluetooth device can change the output format. The
        // source node has to match it exactly or iOS inserts a converter and
        // CoreAudio kills the real-time thread, so re-read the format here —
        // but only once the burst of notifications has stopped.
        guard core != nil else { return }
        routeRebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        routeRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func start() throws {
        // Session activation already happened at launch (or after an
        // interruption), asynchronously and off the main thread. Doing it
        // here on the main thread is what produced the AVAudioSession warning
        // and could fail while another app held the session.

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
        let core = makeCore(sampleRate: rate)
        core.setMasterGain(masterGain)
        core.setBrightness(brightness)
        self.core = core

        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        let source = AVAudioSourceNode(format: format,
                                       renderBlock: AudioEngine.makeRenderBlock(core: core))
        engine.attach(source)
        engine.connect(source, to: engine.outputNode, format: format)
        sourceNode = source

        try engine.start()
        DispatchQueue.main.async { self.isRunning = true }
        startHeartbeat()
    }

    /// Build the kernel for the requested model. A failure to load the measured
    /// resources must never leave the instrument silent, so it falls back to
    /// the waveguide and says why.
    private func makeCore(sampleRate: Double) -> PipaAudioCore {
        guard soundModel == .measured else {
            activeModel = .waveguide
            modelNote = nil
            return PipaAudioCore(sampleRate: sampleRate, bodySizeScale: 1.0)
        }
        if let model = loadKitModel(sampleRate: sampleRate) {
            activeModel = .measured
            modelNote = nil
            return PipaAudioCore(sampleRate: sampleRate,
                                 synth: PipaKitSynth(model: model, sampleRate: sampleRate))
        }
        activeModel = .waveguide
        return PipaAudioCore(sampleRate: sampleRate, bodySizeScale: 1.0)
    }

    private func loadKitModel(sampleRate: Double) -> PipaKitModel? {
        if let kitModel, abs(kitModelRate - sampleRate) < 0.5 { return kitModel }
        do {
            let model = try PipaKitModel.load(sampleRate: sampleRate)
            kitModel = model
            kitModelRate = sampleRate
            return model
        } catch {
            kitModel = nil
            modelNote = "实测音色未载入，已使用波导模型：\(error)"
            print("实测音色加载失败：\(error)")
            return nil
        }
    }

    /// Swap the sound model under a running engine. The session is already
    /// active, so the restart is short: stop, detach the old source, build the
    /// new kernel, start again.
    private func rebuild() {
        guard core != nil else { return }
        // The engine may already have been stopped by an interruption, in
        // which case stop() again is harmless but the flag must be cleared
        // before ensureStarted() so it actually builds a new kernel.
        if engine.isRunning { engine.stop() }
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        core = nil
        started = false
        isRunning = false
        _ = ensureStarted()
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - Performance interface

    /// Every entry point guards on a live kernel. Starting the audio session is
    /// allowed to fail on a real device — a call, another app holding the
    /// session, a route change — and the old force-unwrap turned that into a
    /// crash on the very first pluck. A failed start now leaves the view alive
    /// and reports the reason through `startupError`.
    /// A counter, not a log line. One line per stroke filled the console during
    /// a real performance, and the question worth answering — did the render
    /// thread hear a stroke and still produce silence — is answered better by
    /// this count next to the kernel's own count, printed together only when
    /// the heartbeat sees something wrong.
    ///
    /// An earlier version read the kernel's diagnostics from inside `pluck`,
    /// before the new note had rendered, so every line described the previous
    /// stroke one beat late and a stroke that never arrived printed nothing.
    /// The heartbeat exists to make both of those impossible.
    private var pluckProbeCount = 0
    private func probe(string: Int) {
        pluckProbeCount += 1
    }

    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatCount = 0
    private var heartbeatLastRendered: Int64 = -1
    private var heartbeatStalls = 0
    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatLastRendered = -1
        heartbeatStalls = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let self, !Task.isCancelled else { return }
                let snap = self.core?.diagnosticSnapshot()
                self.heartbeatCount += 1

                // Did the render callback advance at all since the last tick?
                // A frozen `rendered` while the engine claims to be running is
                // the one signature of an IO thread that has stopped pulling
                // buffers: nothing is zeroed by us, nothing is synthesised, and
                // every buffer comes out silent. Distinguishing this from "the
                // callback runs but the synth is silent" is what tells us
                // whether to restart the engine or look inside the synth.
                let rendered = snap?.rendered ?? -1
                let advanced = rendered > self.heartbeatLastRendered
                if self.heartbeatLastRendered >= 0, !advanced { self.heartbeatStalls += 1 } else { self.heartbeatStalls = 0 }
                self.heartbeatLastRendered = rendered

                let peak = String(format: "%.4f", snap?.peak ?? -1)
                // Only speak up when something is wrong. The instrument used to
                // go quiet after a few plucks because the render callback could
                // not finish inside the buffer deadline; a window with sounding
                // voices but not one sample of output is that signature, and it
                // is the one thing worth printing here. A healthy session stays
                // silent in the console.
                let silentButSounding = (snap?.nonzero ?? 1) == 0 && (snap?.sounding ?? 0) > 0
                if silentButSounding || self.heartbeatStalls > 0 {
                    print("[ElectricPipa 心跳#\(self.heartbeatCount)] 窗口峰值=\(peak) 出声采样=\(snap?.nonzero ?? -1) 渲染推进=\(advanced ? "是" : "否") 在响声部=\(snap?.sounding ?? -1) 请求拨=\(self.pluckProbeCount) 内核已拨=\(snap?.applied ?? -1) 队列=\(snap?.pending ?? -1) 引擎运行=\(self.engine.isRunning) 内核=\(self.core != nil)")
                }

                // Self-heal: three frozen ticks (1.2 s) with a live engine and
                // no audio is an IO thread that will not come back on its own.
                // Tear down and restart once, then keep watching. Only while
                // the app is in front: a backgrounded app legitimately stops
                // pulling buffers, and restarting then would fight the system.
                let foreground = UIApplication.shared.applicationState == .active
                if foreground, self.heartbeatStalls >= 3, self.core != nil {
                    print("[ElectricPipa 自愈] 渲染回调已停 \(self.heartbeatStalls) 个周期，重建引擎")
                    self.heartbeatStalls = 0
                    self.forceRestart()
                }
            }
        }
    }

    /// Rebuild the engine from the floor after the render callback stopped
    /// advancing. Unlike rebuild(), this does not trust `started`/`core`: it
    /// clears both, reactivates the session off the main thread, then starts.
    private func forceRestart() {
        if engine.isRunning { engine.stop() }
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
        core = nil
        started = false
        isRunning = false
        reactivateSessionAndRestart()
    }

    /// 同一根弦两次拨弦之间的最小间隔。
    ///
    /// 真机录音里量到的事实：一次正常拨弦之后，同一根弦会以精确 44 ms 的
    /// 节奏被反复触发约二十次，力度逐次递减，听起来是一串"哒哒哒"短音而
    /// 不是一条长音。人手指不可能在 44 ms 内重新拨同一根弦，所以这是一次
    /// 手势被上层重复回调的结果，不是演奏。每一击都把 voice 的起音包络
    /// 清零，长短音于是永远立不起来。
    ///
    /// 55 ms 的门槛只吞掉这种重复：扫弦是四根不同的弦各隔 22 ms，轮指
    /// 最快 1/16 s = 62.5 ms，弹挑最快 30/480 = 62.5 ms，都在门槛之上，
    /// 三种正常技法一个都不会被误伤。
    private var lastPluckTime: [Int: TimeInterval] = [:]
    private static let pluckRefractory: TimeInterval = 0.055

    func pluck(string: Int, fret: Int, velocity: Double = 0.85, position: Double = 0.5) {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = lastPluckTime[string], now - last < Self.pluckRefractory { return }
        lastPluckTime[string] = now
        guard ensureStarted(), let core else { return }
        probe(string: string)
        core.pluck(string: string, fret: fret, velocity: velocity, position: position)
    }

    func strum(ascending: Bool = true, velocity: Double = 0.78) {
        guard ensureStarted(), let core else { return }
        core.strum(ascending: ascending, velocity: velocity)
    }

    /// Wheel (轮指): one string taken through a whole passage of cycles. Each
    /// cycle is the five fingers thrown in turn, so five cycles are
    /// twenty-five plucks and take 25 / rate seconds.
    func tremolo(string: Int, fret: Int, rate: Double, cycles: Double, velocity: Double = 0.5) {
        guard ensureStarted(), let core else { return }
        core.tremolo(string: string, fret: fret, rate: rate, cycles: cycles, velocity: velocity)
    }

    func bend(string: Int, to frequency: Double) {
        guard ensureStarted(), let core else { return }
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
        guard ensureStarted(), let core else { return }
        core.tanTiao(string: string, fret: fret, velocity: velocity, position: position, interval: interval, duration: duration)
    }

    // MARK: - Sustained rolls (continuous mode)

    /// Start a roll that keeps throwing strokes until it is stopped. The
    /// strokes fall on the string and position given here until the roll is
    /// moved elsewhere.
    func rollStart(kind: RollKind, string: Int, fret: Int, interval: Double,
                   velocity: Double, position: Double = 0.5) {
        guard ensureStarted(), let core else { return }
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
