import Foundation

/// One sounding note of the measured model: every partial of one string, with
/// its own fast and slow decay, its split pair, and the residual layer of the
/// accepted take.
///
/// The arithmetic is the kit's, restated at the engine's sample rate. Three
/// things were added for playing an instrument rather than a soundboard of four
/// buttons:
///
/// 1. `shift` — the whole partial stack is multiplied by one number, so any
///    stop position can be sounded from the same fitted string. The fit itself
///    only covers the open string; a shorter speaking length scales every
///    partial, which is what this does. Decay and the residual stay as fitted,
///    the same way the kit's own experimental transposition keeps them.
/// 2. `position` — the fit was made at one pluck spot per string. Plucking
///    elsewhere weighs each partial by sin(kπp): the harmonics that have a node
///    under the pick cancel, which is why the tone moves toward the bridge.
///    The weighting is taken relative to the fitted spot, so the neutral pluck
///    reproduces the accepted sound exactly.
/// 3. `damp()` — the app's 止音 has to stop a string that has already been
///    struck. The model has no damping input, so the voice fades out fast and
///    then stops rendering.
///
/// Once `start` has run, everything here is allocation-free and lock-free, so
/// the render thread can own it.
struct PipaKitVoice {

    private struct Oscillator {
        var real: Double
        var imaginary: Double
        var cosStep: Double = 1
        var sinStep: Double = 0

        init(phase: Double) {
            real = cos(phase)
            imaginary = sin(phase)
        }

        mutating func tune(to frequency: Double, sampleRate: Double) {
            let omega = 2 * Double.pi * frequency / sampleRate
            cosStep = cos(omega)
            sinStep = sin(omega)
        }

        mutating func advance() {
            let old = real
            real = real * cosStep - imaginary * sinStep
            imaginary = old * sinStep + imaginary * cosStep
        }
    }

    private struct ModeState {
        var primary: Oscillator
        var secondary: Oscillator
        var hasSecondary: Bool
        /// Envelope values for this pluck, and the fitted levels they decay from.
        var fast: Double
        var slow: Double
        let baseFast: Double
        let baseSlow: Double
        let fastMultiplier: Double
        let slowMultiplier: Double
        let softening: Double
        let normalizer: Double
        let pairRatio: Double
        let rightGain: Double
        let rightCos: Double
        let rightSin: Double
        let secondaryRightGain: Double
        let secondaryRightCos: Double
        let secondaryRightSin: Double
        /// Frequency of this partial on the open string, before any shift.
        let baseFrequency: Double
        /// Distance of the split partner above it, in Hz, still unshifted.
        let pairSplitHz: Double
        /// Harmonic number, used for the pluck-position weighting.
        let harmonic: Int
        /// Weight from pluck position and tone trim, recomputed per pluck.
        var weight: Double = 1
        var enabled = true
    }

    private let sampleRate: Double
    private var modes: [ModeState]
    private let residual: [Float]
    private let gainScale: Double
    private let rightMultiplier: Double
    private let leftFeed: Double
    private let attackMultiplier: Double
    private let dampMultiplier: Double
    private let fittedPosition: Double

    private var attack = 1.0
    private var shelf = 1.0
    private var sampleIndex = 0
    /// Zero until the first pluck, so a voice that has never sounded costs
    /// nothing on the render thread.
    private var dampLevel = 0.0
    private var gain = 0.0

    /// The kit's attack softening relaxes over the first 40 ms.
    private let shelfMultiplier: Double

    /// Ringing, or still fading after 止音; a silent voice can be skipped whole.
    private(set) var isSounding = false

    /// A voice releases itself after this many consecutive samples of output
    /// below -120 dBFS, so the release can never be heard: the level it fires
    /// at is a thousand times below the quietest thing a phone speaker can
    /// reproduce, and the note has been fading for over a minute by then.
    ///
    /// The decision is taken on the voice's own output, not on a proxy. An
    /// earlier version compared the summed partial envelopes times gain
    /// against a threshold, and that number sits about three orders of
    /// magnitude away from what the voice actually emits, so it cut notes at
    /// -72 dBFS instead of -120. Measuring the thing being judged is the only
    /// way this stays honest.
    ///
    /// This matters for the render thread rather than for the ear. A voice used
    /// to keep running every one of its 44–90 partials for the life of the app,
    /// so four struck strings were four times the work of one, for as long as
    /// the app stayed open. That growing load is what pushed the IO thread past
    /// its deadline after a few plucks, and why 止音 (which stops every voice)
    /// brought the sound back for another few.
    private static let silenceFloor = 1e-6
    private let quietSamplesToRelease: Int
    private var quietRun = 0

    init(preset: PipaKitModel.Preset, sampleRate: Double, fittedPosition: Double) {
        self.sampleRate = sampleRate
        self.fittedPosition = min(max(fittedPosition, 0.05), 0.95)
        self.residual = preset.residual
        self.gainScale = preset.outputGain
        self.rightMultiplier = preset.calibration.rightMultiplier
        self.leftFeed = preset.calibration.leftFeed
        self.quietSamplesToRelease = max(1, Int(sampleRate * 0.1))
        self.attackMultiplier = exp(-1 / (sampleRate * preset.attackSeconds))
        self.shelfMultiplier = exp(-1 / (sampleRate * 0.04))
        self.dampMultiplier = exp(-1 / (sampleRate * 0.006))

        var states: [ModeState] = []
        states.reserveCapacity(preset.modes.count)
        for mode in preset.modes {
            let base = preset.frequencyHz * mode.frequencyRatio
            let pair = mode.pair
            let q = pow(base / 2500, 2)
            let pairRatio = pair?.ratio ?? 0
            let fast = mode.amplitude * mode.fastFraction
            let slow = mode.amplitude * (1 - mode.fastFraction)
            states.append(ModeState(
                primary: Oscillator(phase: mode.phase),
                secondary: Oscillator(phase: mode.phase + (pair?.relativePhase ?? 0)),
                hasSecondary: pair != nil,
                fast: fast,
                slow: slow,
                baseFast: fast,
                baseSlow: slow,
                fastMultiplier: exp(-1 / (sampleRate * mode.fastTau)),
                slowMultiplier: exp(-1 / (sampleRate * mode.slowTau)),
                softening: preset.attackSoftening * q / (1 + q),
                normalizer: 1 / (1 + pairRatio * pairRatio).squareRoot(),
                pairRatio: pairRatio,
                rightGain: mode.rightGain,
                rightCos: cos(mode.rightPhase),
                rightSin: sin(mode.rightPhase),
                secondaryRightGain: pair?.rightSecondaryGain ?? 0,
                secondaryRightCos: cos(pair?.rightSecondaryPhase ?? 0),
                secondaryRightSin: sin(pair?.rightSecondaryPhase ?? 0),
                baseFrequency: base,
                pairSplitHz: pair?.splitHz ?? 0,
                harmonic: max(1, Int(mode.frequencyRatio.rounded()))))
        }
        self.modes = states
    }

    // MARK: - Playing

    /// Restart the voice on a new note.
    /// - Parameters:
    ///   - shift: frequency multiplier against the fitted open string, so the
    ///     open string is 1 and every fret above it multiplies by 2^(1/12).
    ///   - velocity: 0 to 1, gain only.
    ///   - position: pluck point in the conventional scale, where 0.5 is the
    ///     measured spot; clamped to the playable band.
    ///   - tilt: tone trim, 0 is neutral. Positive lifts the upper partials.
    mutating func start(shift: Double, velocity: Double, position: Double, tilt: Double = 0) {
        let safeShift = shift.isFinite && shift > 0 ? shift : 1
        let safeVelocity = min(max(velocity.isFinite ? velocity : 0, 0), 1)
        let nyquist = sampleRate * 0.5

        // Where the pick lands, on the string's own scale: the conventional
        // 0.5 maps onto the fitted spot and everything else scales with it.
        let pluck = min(max(fittedPosition * (min(max(position, 0.02), 0.98) / 0.5), 0.05), 0.95)

        var weightSquareSum = 0.0
        var counted = 0
        for index in modes.indices {
            let base = modes[index].baseFrequency
            let frequency = base * safeShift
            let partner = (base + modes[index].pairSplitHz) * safeShift
            let hasPartner = modes[index].hasSecondary && partner > 0 && partner < nyquist
            modes[index].enabled = frequency > 0 && frequency < nyquist
            if modes[index].hasSecondary && !hasPartner {
                modes[index].hasSecondary = false
            }

            // Pluck weighting: |sin(kπp)| against the value at the fitted spot,
            // clamped so a pick parked on a node cannot ask for an unbounded
            // boost, then renormalised over the stack below so that moving the
            // hand does not change the loudness.
            let harmonicPhase = Double(modes[index].harmonic) * Double.pi
            let measured = sin(harmonicPhase * fittedPosition)
            var weight = 1.0
            if abs(measured) > 0.08 {
                weight = min(abs(sin(harmonicPhase * pluck)) / abs(measured), 2.5)
            }
            // Tone trim: a gentle spectral tilt around 1 kHz, neutral at 0.
            if tilt != 0 {
                weight *= min(max(pow(max(frequency, 1) / 1000, tilt), 0.3), 3.5)
            }
            modes[index].weight = weight
            if modes[index].enabled {
                weightSquareSum += weight * weight
                counted += 1
            }

            modes[index].primary.tune(to: frequency, sampleRate: sampleRate)
            if hasPartner {
                modes[index].secondary.tune(to: partner, sampleRate: sampleRate)
            }
            modes[index].fast = modes[index].baseFast
            modes[index].slow = modes[index].baseSlow
        }

        // Keep the level steady as the hand moves. At the fitted spot every
        // weight is already exactly one, so this is an exact no-op there.
        if counted > 0 {
            let rms = (weightSquareSum / Double(counted)).squareRoot()
            if rms > 0.001, abs(rms - 1) > 1e-9 {
                for index in modes.indices { modes[index].weight /= rms }
            }
        }

        gain = gainScale * safeVelocity
        attack = 1
        shelf = 1
        sampleIndex = 0
        dampLevel = 1
        quietRun = 0
        isSounding = true
    }

    /// Move the pitch of a note that is already ringing, for a push or a pull.
    /// Phases and envelopes carry on, so the glide is smooth.
    mutating func retune(shift: Double) {
        guard shift.isFinite, shift > 0 else { return }
        let nyquist = sampleRate * 0.5
        for index in modes.indices {
            let frequency = modes[index].baseFrequency * shift
            let partner = (modes[index].baseFrequency + modes[index].pairSplitHz) * shift
            let enabled = frequency > 0 && frequency < nyquist
            modes[index].enabled = enabled
            if enabled {
                modes[index].primary.tune(to: frequency, sampleRate: sampleRate)
                if modes[index].hasSecondary, partner > 0, partner < nyquist {
                    modes[index].secondary.tune(to: partner, sampleRate: sampleRate)
                }
            }
        }
    }

    /// 止音: a hand laid across the string, not a switch.
    mutating func damp() {
        isSounding = false
    }

    // MARK: - Rendering

    mutating func renderSample() -> (left: Float, right: Float) {
        guard isSounding || dampLevel > 0.0001 else { return (0, 0) }

        var left = 0.0
        var right = 0.0
        for index in modes.indices {
            guard modes[index].enabled else { continue }
            let mode = modes[index]
            let envelope = (mode.fast + mode.slow) * (1 - mode.softening * shelf)
                * mode.normalizer * mode.weight
            var l = mode.primary.real
            var r = mode.rightGain * (mode.primary.real * mode.rightCos - mode.primary.imaginary * mode.rightSin)
            if mode.hasSecondary {
                l += mode.pairRatio * mode.secondary.real
                r += mode.pairRatio * mode.secondaryRightGain
                    * (mode.secondary.real * mode.secondaryRightCos
                       - mode.secondary.imaginary * mode.secondaryRightSin)
            }
            left += envelope * l
            right += envelope * r
            modes[index].primary.advance()
            if mode.hasSecondary { modes[index].secondary.advance() }
            modes[index].fast *= mode.fastMultiplier
            modes[index].slow *= mode.slowMultiplier
        }

        left *= 1 - attack
        right *= 1 - attack

        // The residual layer plays at the pitch it was fitted at, whatever the
        // note is doing. Replaying it transposed with the string was tried and
        // made no audible difference, so the layer stays where the take put
        // it: the model is fitted at the open strings, and covering the rest of
        // the neck means measuring it, not moving this layer.
        let residualFrame = residual.count / 2
        if sampleIndex < residualFrame {
            left += Double(residual[sampleIndex * 2])
            right += Double(residual[sampleIndex * 2 + 1])
        }
        right = rightMultiplier * right + leftFeed * left
        attack *= attackMultiplier
        shelf *= shelfMultiplier
        sampleIndex += 1

        if !isSounding {
            dampLevel *= dampMultiplier
            if dampLevel < 0.0005 { dampLevel = 0 }
            left *= dampLevel
            right *= dampLevel
        }

        let outputLeft = left * gain
        let outputRight = right * gain

        // Partials and residual have both faded to true silence below
        // -120 dBFS: release the voice so it stops costing the render thread
        // anything until the next pluck. Judged on the samples it emits, after
        // every gain stage, so "silent" means exactly that.
        let residualEnded = sampleIndex >= residualFrame
        if isSounding, residualEnded {
            if max(abs(outputLeft), abs(outputRight)) < Self.silenceFloor {
                quietRun += 1
                if quietRun >= quietSamplesToRelease {
                    isSounding = false
                    dampLevel = 0
                }
            } else {
                quietRun = 0
            }
        }

        return (Float(outputLeft), Float(outputRight))
    }
}
