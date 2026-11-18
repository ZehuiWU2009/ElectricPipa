import Foundation

/// The measured modal model behind the four open strings.
///
/// These are the fitted numbers that ElectricPipaKit 1.0.0 ships — strings one
/// to three from the V3 fit, string four from the V3.1 tail correction — moved
/// into the app so that they can run inside the app's own audio engine. The
/// kit's ready-made player only knows four fixed pitches; this app has to sound
/// 32 stop positions on each string, plus the wheel, tan-tiao and a roll that
/// never stops, all through one engine and one output format.
///
/// What is taken over unchanged: every modal amplitude, split pair, fast and
/// slow decay constant, stereo calibration, attack time and output gain, and
/// the 1.5 s residual layer (interleaved stereo Float32, little endian, 48 kHz)
/// that keeps the synthesis identical to the take that was accepted by ear.
/// What had to change: the sample rate is a parameter instead of a fixed
/// 48 kHz, so the engine can run at whatever rate the device actually gives us;
/// the residual is resampled once at load time when that rate is not 48 kHz.
///
/// The four strings are numbered by thickness, matching the app's index after
/// the mapping the kit recommends: 1 is the thinnest (子弦, 221.44 Hz as
/// measured), 4 is the thickest (缠弦, 110.585 Hz).
struct PipaKitModel {

    struct Pair {
        let splitHz: Double
        let ratio: Double
        let relativePhase: Double
        let rightSecondaryGain: Double
        let rightSecondaryPhase: Double
    }

    struct Mode {
        let amplitude: Double
        let fastFraction: Double
        let fastTau: Double
        let slowTau: Double
        let frequencyRatio: Double
        let phase: Double
        let rightGain: Double
        let rightPhase: Double
        let pair: Pair?
    }

    struct Calibration {
        let rightMultiplier: Double
        let leftFeed: Double
    }

    struct Preset {
        /// 1 is the thinnest string, 4 the thickest.
        let string: Int
        /// Open pitch the fit measured on the recording.
        let frequencyHz: Double
        let attackSeconds: Double
        let attackSoftening: Double
        let outputGain: Double
        let modes: [Mode]
        let calibration: Calibration
        /// Interleaved left/right, already at the engine's sample rate.
        let residual: [Float]
    }

    /// Sampling rate of the shipped parameters and of the residual files.
    static let sourceSampleRate = 48_000.0

    let sampleRate: Double
    /// Index 0 is string 1 (thinnest).
    let presets: [Preset]

    // MARK: - Decoding

    private struct File: Decodable {
        let version: String
        let sampleRate: Int
        let presets: [FilePreset]
    }

    private struct FilePreset: Decodable {
        struct FilePair: Decodable {
            let splitHz: Double, ratio: Double, relativePhase: Double
            let rightSecondaryGain: Double, rightSecondaryPhase: Double
        }
        struct FileMode: Decodable {
            let amplitude: Double, fastFraction: Double, fastTau: Double, slowTau: Double
            let frequencyRatio: Double, phase: Double, rightGain: Double, rightPhase: Double
            let pair: FilePair?
        }
        struct FileCalibration: Decodable {
            let rightMultiplier: Double, leftFeed: Double
        }
        let string: Int
        let frequencyHz: Double, attackSeconds: Double, attackSoftening: Double, outputGain: Double
        let modes: [FileMode]
        let stereoCalibration: FileCalibration
        let residualFile: String
    }

    enum LoadError: Error, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        var description: String {
            switch self {
            case .missing(let name): return "音色资源缺失：\(name)"
            case .invalid(let reason): return "音色资源不可用：\(reason)"
            }
        }
    }

    /// Load the packaged model.
    /// - Parameters:
    ///   - directory: folder holding `model.json` and the residual files. Nil
    ///     means the app bundle, so the shipping app passes nothing and the
    ///     command-line renderer passes `Core/KitResources`.
    ///   - sampleRate: rate the engine will run at. The residual is resampled
    ///     to it once, here, never inside the audio callback.
    static func load(from directory: URL? = nil, sampleRate: Double) throws -> PipaKitModel {
        guard sampleRate > 0, sampleRate.isFinite else {
            throw LoadError.invalid("采样率 \(sampleRate)")
        }
        let modelURL = try locate("model", withExtension: "json", in: directory)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file: File
        do {
            file = try decoder.decode(File.self, from: Data(contentsOf: modelURL))
        } catch {
            throw LoadError.invalid("model.json 解析失败：\(error)")
        }
        guard file.sampleRate == Int(sourceSampleRate) else {
            throw LoadError.invalid("model.json 采样率 \(file.sampleRate)")
        }
        guard file.presets.map(\.string) == [1, 2, 3, 4] else {
            throw LoadError.invalid("model.json 弦序不是 1…4")
        }

        var presets: [Preset] = []
        presets.reserveCapacity(4)
        for preset in file.presets {
            let numbers = [preset.frequencyHz, preset.attackSeconds, preset.attackSoftening, preset.outputGain,
                           preset.stereoCalibration.rightMultiplier, preset.stereoCalibration.leftFeed]
            guard numbers.allSatisfy({ $0.isFinite }), preset.frequencyHz > 0, preset.attackSeconds > 0,
                  (0...1).contains(preset.attackSoftening), preset.outputGain > 0, !preset.modes.isEmpty else {
                throw LoadError.invalid("第 \(preset.string) 弦的参数越界")
            }
            var modes: [Mode] = []
            modes.reserveCapacity(preset.modes.count)
            for mode in preset.modes {
                let values = [mode.amplitude, mode.fastFraction, mode.fastTau, mode.slowTau,
                              mode.frequencyRatio, mode.phase, mode.rightGain, mode.rightPhase]
                guard values.allSatisfy({ $0.isFinite }), mode.amplitude >= 0,
                      (0...1).contains(mode.fastFraction), mode.fastTau > 0, mode.slowTau > 0,
                      mode.frequencyRatio > 0, mode.rightGain >= 0 else {
                    throw LoadError.invalid("第 \(preset.string) 弦的模态越界")
                }
                let pair = try mode.pair.map { pair -> Pair in
                    let pairValues = [pair.splitHz, pair.ratio, pair.relativePhase,
                                      pair.rightSecondaryGain, pair.rightSecondaryPhase]
                    guard pairValues.allSatisfy({ $0.isFinite }), pair.ratio >= 0 else {
                        throw LoadError.invalid("第 \(preset.string) 弦的拍频参数越界")
                    }
                    return Pair(splitHz: pair.splitHz, ratio: pair.ratio, relativePhase: pair.relativePhase,
                                rightSecondaryGain: pair.rightSecondaryGain,
                                rightSecondaryPhase: pair.rightSecondaryPhase)
                }
                modes.append(Mode(amplitude: mode.amplitude, fastFraction: mode.fastFraction,
                                  fastTau: mode.fastTau, slowTau: mode.slowTau,
                                  frequencyRatio: mode.frequencyRatio, phase: mode.phase,
                                  rightGain: mode.rightGain, rightPhase: mode.rightPhase, pair: pair))
            }
            let residualURL = try locate(preset.residualFile, withExtension: nil, in: directory)
            let residual = try readResidual(at: residualURL, targetRate: sampleRate)
            presets.append(Preset(string: preset.string, frequencyHz: preset.frequencyHz,
                                  attackSeconds: preset.attackSeconds,
                                  attackSoftening: preset.attackSoftening,
                                  outputGain: preset.outputGain, modes: modes,
                                  calibration: Calibration(
                                    rightMultiplier: preset.stereoCalibration.rightMultiplier,
                                    leftFeed: preset.stereoCalibration.leftFeed),
                                  residual: residual))
        }
        return PipaKitModel(sampleRate: sampleRate, presets: presets)
    }

    /// Model file lookup: an explicit folder, or the app bundle (files are
    /// copied flat into the bundle by the Resources build phase, with a
    /// `KitResources` subfolder accepted in case the folder reference is used).
    private static func locate(_ name: String, withExtension suffix: String?, in directory: URL?) throws -> URL {
        let fileManager = FileManager.default
        if let directory {
            let candidate = directory.appendingPathComponent(suffix.map { "\(name).\($0)" } ?? name)
            guard fileManager.fileExists(atPath: candidate.path) else { throw LoadError.missing(candidate.path) }
            return candidate
        }
        if let url = Bundle.main.url(forResource: name, withExtension: suffix) { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "KitResources") {
            return url
        }
        throw LoadError.missing(suffix.map { "\(name).\($0)" } ?? name)
    }

    /// Read interleaved stereo little-endian Float32 and bring it to the
    /// engine's rate. The residual is a broadband noise-and-body layer, so a
    /// linear resample of it cannot colour the tone; it only has to keep the
    /// layer's level and spectrum in the same place.
    private static func readResidual(at url: URL, targetRate: Double) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count % 8 == 0, !data.isEmpty else { throw LoadError.invalid("残余层 \(url.lastPathComponent) 长度不对") }
        let frames = data.count / 8
        var source = [Float](repeating: 0, count: frames * 2)
        data.withUnsafeBytes { raw in
            for index in 0..<(frames * 2) {
                let offset = index * 4
                let bits = UInt32(raw[offset]) | (UInt32(raw[offset + 1]) << 8)
                    | (UInt32(raw[offset + 2]) << 16) | (UInt32(raw[offset + 3]) << 24)
                source[index] = Float(bitPattern: bits)
            }
        }
        guard source.allSatisfy({ $0.isFinite }) else { throw LoadError.invalid("残余层含非有限值") }
        if abs(targetRate - sourceSampleRate) < 0.5 { return source }

        // Linear interpolation, done once at load time on a worker thread.
        let ratio = sourceSampleRate / targetRate
        let outputFrames = max(1, Int((Double(frames) / ratio).rounded()))
        var output = [Float](repeating: 0, count: outputFrames * 2)
        for frame in 0..<outputFrames {
            let position = Double(frame) * ratio
            let base = min(Int(position), max(frames - 2, 0))
            let fraction = Float(position - Double(base))
            let next = min(base + 1, frames - 1)
            for channel in 0..<2 {
                let a = source[base * 2 + channel]
                let b = source[next * 2 + channel]
                output[frame * 2 + channel] = a + (b - a) * fraction
            }
        }
        return output
    }

    /// Open pitch the fit measured, before any tuning correction.
    /// - Parameter string: the app's index, 0 being 缠弦, the thickest string.
    func measuredFrequency(string: Int) -> Double {
        preset(for: string).frequencyHz
    }

    /// The app numbers the strings from the thickest (0, 缠弦) to the thinnest
    /// (3, 子弦); the kit numbers them the other way round. Everything that
    /// crosses between the two goes through here, because a reversed pair of
    /// outer strings still sounds like a Pipa and nobody notices until the
    /// pitches are checked.
    func preset(for string: Int) -> Preset {
        let clamped = min(max(string, 0), presets.count - 1)
        return presets[presets.count - 1 - clamped]
    }

    /// Build one voice. Allocation happens here, never on the audio thread, so
    /// the synth builds its voices up front and only restarts them per pluck.
    func makeVoice(string: Int, fittedPosition: Double) -> PipaKitVoice {
        PipaKitVoice(preset: preset(for: string), sampleRate: sampleRate,
                     fittedPosition: fittedPosition)
    }
}
