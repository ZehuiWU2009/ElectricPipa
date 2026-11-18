import CoreAudio
import Foundation

/// Which continuous stroke a sustained roll throws.
///
/// A roll is one technique repeated without end: the wheel (轮指) throws the
/// five fingers in turn, tan-tiao (弹挑) alternates an outward and an inward
/// strike. The roll keeps its own clock on the render thread, so the stroke
/// spacing stays sample-accurate however long the player keeps it going.
enum RollKind {
    case wheel
    case tanTiao
}

/// One kind of performance event.
fileprivate enum PipaEvent {
    case pluck(string: Int, fret: Int, velocity: Double, position: Double)
    case bend(string: Int, to: Double)
    case damp(string: Int)
    case dampAll
    case setBrightness(Double)
    case setMasterGain(Float)
    case rollStart(kind: RollKind, string: Int, fret: Int, interval: Double, velocity: Double, position: Double)
    case rollSetTempo(Double)
    case rollMove(string: Int, fret: Int)
    case rollStop
}

/// One event with its time already resolved.
fileprivate struct ScheduledPipaEvent {
    let dueSample: Int64
    let event: PipaEvent
}

/// The clock of a sustained roll, owned by the render thread alone.
///
/// The main thread only ever drops intent into the event queue; every field
/// here is written by the render thread, either when it applies an event or
/// when it throws a stroke. Keeping the roll here rather than in the event
/// queue is what lets it run for as long as the player wants: a queue would
/// need one event per stroke, and nobody knows when the last stroke comes.
private struct RollState {
    var active = false
    var kind: RollKind = .wheel
    var string = PipaSynth.stringCount - 1
    var fret = 0
    /// Seconds between strokes. The wheel divides one second by its rate;
    /// tan-tiao halves one metronome beat.
    var interval = 0.11
    var velocity = 0.5
    /// Where tan-tiao strikes around. The wheel ignores this and uses each
    /// finger's own spot.
    var position = 0.5
    /// Sample index the next stroke falls on.
    var nextSample: Int64 = 0
    /// Strokes thrown so far, which picks the finger and the direction.
    var step = 0
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
///
/// A sustained roll (continuous mode) is the one thing that cannot be laid out
/// as events ahead of time, so the render thread drives it from `RollState`
/// instead: it checks the clock once per sample and throws the stroke that has
/// come due. No queue can overflow and no stroke is ever early or late.
final class PipaAudioCore: @unchecked Sendable {
    let sampleRate: Double
    /// Whichever sound model this kernel was built with. The event queue, the
    /// roll clock and the render loop are the same for both, so the choice is
    /// made once, when the engine starts, and never inside a sample.
    let synth: PipaSoundEngine

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

    /// The sustained roll, if one is running. Render thread only.
    private var roll = RollState()

    /// Delayed strokes wait on the main queue before entering the ring buffer.
    /// A generation stamp lets 止音 cancel strokes that were laid out earlier
    /// by a tremolo or tan-tiao and have not reached the queue yet; without it
    /// a hand that stops the sound would still hear the tail of a passage
    /// arrive a moment later. Written on the main thread only.
    private var scheduledGeneration: UInt64 = 0

    /// Diagnosis only: peak absolute sample the synth produced since the last
    /// probe read, and how many samples were non-zero. The render thread writes
    /// these, the main thread reads and clears them; approximate values are
    /// fine. Together they distinguish "the synth produced no audio" from
    /// "audio was produced but never reached the speaker".
    private var probePeak: Float = 0
    private var probeNonzero: Int = 0
    /// Gap between the last two .pluck events as the render thread saw them,
    /// in milliseconds. This is the decisive probe: if the kernel is being fed
    /// plucks every ~44 ms, repeat calls are getting past the main-thread
    /// guard; if the gap is normal but the ear still hears a machine-gun run,
    /// the repetition is happening below the event layer (buffer replay).
    private var probePluckGapMs: Double = -1
    private var lastPluckSample: Int64 = -1
    /// How many .pluck events the render thread has actually applied. Compared
    /// against the engine's own pluck count, it says whether an event reached
    /// the synth at all or was lost between the UI and this loop.
    private var appliedPlucks: Int = 0

    /// The Karplus-Strong waveguide bank.
    convenience init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.init(sampleRate: sampleRate,
                  synth: PipaSynth(sampleRate: sampleRate, bodySizeScale: bodySizeScale))
    }

    /// Any other sound model, such as the measured one.
    init(sampleRate: Double, synth: PipaSoundEngine) {
        self.sampleRate = sampleRate
        self.synth = synth
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

        // Clear every channel before rendering. If a buffer ever comes in short
        // or nil, returning without writing leaves the previous block in place
        // and CoreAudio replays it — heard as a short click once per buffer
        // (2048 frames / 48 kHz ≈ 43 ms), the exact repeating pattern in the
        // field recording. Zero first so a bad block is silence, never a replay.
        for buf in 0..<abl.count {
            if let p = abl[buf].mData?.assumingMemoryBound(to: Float.self) {
                let cap = Int(abl[buf].mDataByteSize) / MemoryLayout<Float>.stride
                p.update(repeating: 0, count: min(frames, cap))
            }
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

            // A sustained roll throws its own strokes here, off its own clock,
            // so it keeps going for as long as the player leaves it running.
            if roll.active, rendered >= roll.nextSample {
                throwRollStroke()
            }

            // The measured model is stereo: its partials carry a right-channel
            // gain and phase. Channel 0 is left, channel 1 right, anything
            // beyond repeats the right channel, and a mono output gets the sum
            // of the two rather than dropping half the image.
            let frame = synth.renderFrame()
            // Diagnosis: track what the kernel actually produced this buffer.
            let peak = max(abs(frame.left), abs(frame.right))
            if peak > probePeak { probePeak = peak }
            if peak > 1e-6 { probeNonzero += 1 }
            let mono = (frame.left + frame.right) * 0.5
            for buf in 0..<abl.count {
                if let pointer = abl[buf].mData?.assumingMemoryBound(to: Float.self) {
                    let cap = Int(abl[buf].mDataByteSize) / MemoryLayout<Float>.stride
                    if i < cap {
                        pointer[i] = abl.count == 1 ? mono : (buf == 0 ? frame.left : frame.right)
                    }
                }
            }
            rendered += 1
        }
    }

    private func apply(_ event: PipaEvent) {
        switch event {
        case .pluck(let string, let fret, let velocity, let position):
            // Record how far apart two plucks reached the render thread.
            if lastPluckSample >= 0, rendered > lastPluckSample {
                probePluckGapMs = Double(rendered - lastPluckSample) / sampleRate * 1000
            }
            lastPluckSample = rendered
            appliedPlucks += 1
            synth.pluck(string: string, fret: fret, velocity: velocity, position: position)
        case .bend(let string, let frequency):
            synth.bend(string: string, to: frequency)
        case .damp(let string):
            synth.damp(string: string)
        case .dampAll:
            synth.dampAll()
            // Silence is what 止音 asks for, so a sustained roll ends with it.
            roll.active = false
        case .setBrightness(let value):
            synth.setBrightness(value)
        case .setMasterGain(let value):
            synth.masterGain = value
        case .rollStart(let kind, let string, let fret, let interval, let velocity, let position):
            roll.active = true
            roll.kind = kind
            roll.string = string
            roll.fret = fret
            roll.interval = clampInterval(interval)
            roll.velocity = velocity
            roll.position = position
            roll.step = 0
            roll.nextSample = rendered   // first stroke answers the press at once
        case .rollSetTempo(let interval):
            // The pending stroke keeps its old spacing; every stroke after it
            // uses the new one, so the tempo slides instead of jumping.
            roll.interval = clampInterval(interval)
        case .rollMove(let string, let fret):
            roll.string = string
            roll.fret = fret
        case .rollStop:
            roll.active = false
        }
    }

    /// Throw one stroke of the sustained roll and arm the next one. Every synth
    /// write happens here, on the render thread, exactly as it does for queued
    /// events.
    private func throwRollStroke() {
        switch roll.kind {
        case .wheel:
            let fingers = WheelFinger.allCases
            let finger = fingers[roll.step % fingers.count]
            synth.pluck(string: roll.string, fret: roll.fret,
                        velocity: roll.velocity * finger.velocityScale,
                        position: finger.position)
        case .tanTiao:
            let outward = roll.step % 2 == 0
            let spot = outward ? min(0.92, roll.position + 0.12) : max(0.08, roll.position - 0.12)
            synth.pluck(string: roll.string, fret: roll.fret,
                        velocity: outward ? roll.velocity : roll.velocity * 0.9,
                        position: spot)
        }
        // Wrap rather than overflow, so a roll left running for days still
        // selects fingers and directions correctly.
        roll.step = roll.step == Int.max ? 0 : roll.step + 1
        roll.nextSample = rendered + Int64(roll.interval * sampleRate)
    }

    private func clampInterval(_ interval: Double) -> Double {
        min(max(interval, 1.0 / sampleRate), 5.0)
    }

    // MARK: - Main-thread interface

    /// A read-only view of the queue for the diagnosis line in the console.
    /// Main thread only; the counters are written on their own threads and are
    /// intentionally not made atomic, since an approximate reading is plenty.
    func diagnosticSnapshot() -> (pending: Int, rendered: Int64, peak: Float, nonzero: Int, pluckGapMs: Double, applied: Int, sounding: Int, synthPlucks: Int) {
        let result = (enqueueIndex - dequeueIndex, rendered, probePeak, probeNonzero,
                      probePluckGapMs, appliedPlucks, synth.diagnosticVoices, synth.diagnosticPluckCount)
        probePeak = 0
        probeNonzero = 0
        probePluckGapMs = -1
        return result
    }

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

    /// Put an event on the render thread's queue.
    ///
    /// An event with a delay used to be enqueued immediately with a due time in
    /// the future. The render loop consumes the ring buffer in strict FIFO
    /// order and stops at the first event whose due time has not arrived, so
    /// one future stroke blocked every pluck queued behind it. A tremolo laid
    /// out 25 strokes over three seconds, for example, silenced every plain
    /// pluck made during those three seconds, then fired all of the backlog at
    /// once when the clock caught up — heard as a stuck note repeating in
    /// short bursts, and "cured" by 止音 only because that drained the queue.
    ///
    /// The fix is to keep the queue made up of nothing but events that are due
    /// now. A delayed event waits on the main queue and is enqueued when its
    /// time comes, so a plain pluck never sits behind a stroke that has not
    /// happened yet. Dispatch timing (about a millisecond) is ample next to a
    /// 22 ms strum gap or a 100 ms wheel stroke, and the render loop stays
    /// lock-free and allocation-free.
    fileprivate func schedule(_ event: PipaEvent, atOffset seconds: Double) {
        guard seconds > 0 else {
            enqueue(event, at: rendered)
            return
        }
        let generation = scheduledGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.scheduledGeneration == generation else { return }
            self.enqueue(event, at: self.rendered)
        }
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

    /// Wheel (轮指): the five fingers thrown in turn — index, middle, ring,
    /// little, thumb — one cycle being five plucks with the accent on the
    /// first, each finger at its own spot and its own weight. See
    /// WheelFinger for why five rather than four: a four-finger cycle falls
    /// into 2 + 2 pairs and sounds like tan-tiao (弹挑).
    ///
    /// A passage is measured in cycles, not seconds: one cycle is five plucks,
    /// so `cycles` full cycles take `cycles * 5 / rate` seconds. For an
    /// open-ended wheel, start a roll instead.
    func tremolo(string: Int, fret: Int, rate: Double, cycles: Double, velocity: Double = 0.5) {
        let count = max(1, Int((cycles * Double(WheelFinger.allCases.count)).rounded()))
        for index in 0..<count {
            let finger = WheelFinger.allCases[index % WheelFinger.allCases.count]
            schedule(.pluck(string: string, fret: fret,
                            velocity: velocity * finger.velocityScale,
                            position: finger.position), atOffset: Double(index) / rate)
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
    /// apart, for `duration` seconds — the classic continuous 弹挑 roll. For an
    /// open-ended one, start a roll instead.
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

    // MARK: - Sustained rolls (continuous mode)

    /// Start a sustained roll. The first stroke falls on the next sample, so
    /// the sound answers the press at once.
    func rollStart(kind: RollKind, string: Int, fret: Int, interval: Double,
                   velocity: Double, position: Double = 0.5) {
        schedule(.rollStart(kind: kind, string: string, fret: fret,
                            interval: interval, velocity: velocity, position: position), atOffset: 0)
    }

    /// Move the roll to another string or position. The next stroke lands on
    /// the new spot, which is how the left hand changes note under a roll.
    func rollMove(string: Int, fret: Int) {
        schedule(.rollMove(string: string, fret: fret), atOffset: 0)
    }

    /// Change the stroke spacing of a running roll without restarting it.
    func rollSetTempo(_ interval: Double) {
        schedule(.rollSetTempo(interval), atOffset: 0)
    }

    /// Stop the roll. Strings already sounding keep ringing; the roll simply
    /// throws no further strokes.
    func rollStop() {
        schedule(.rollStop, atOffset: 0)
    }

    func dampAll() {
        // 止音也作废此前排布、尚未入队的延迟拨弦，否则停音之后
        // 轮指剩下的那几下会过一会儿又冒出来。
        scheduledGeneration &+= 1
        schedule(.dampAll, atOffset: 0)
    }
}
