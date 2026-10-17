import Foundation

/// Musical parameters of the Pipa: tuning, positions and pitch conversion.
///
/// The standard tuning runs A-d-e-a from the Chan string (thickest) to the Zi
/// string (thinnest), which is A3 / D4 / E4 / A4 in scientific pitch notation.
/// This is the zheng diao tuning used by most of the repertoire. A modern Pipa
/// carries six xiang and twenty-five frets, every adjacent pair a semitone
/// apart, laid out in twelve-tone equal temperament.
enum PipaTuning {

    /// Open-string MIDI pitches of the four strings. Index 0 is the Chan string
    /// (thickest and lowest), index 3 is the Zi string (thinnest and highest).
    static let openStringMIDI: [Int] = [57, 62, 64, 69]

    /// Traditional names of the four strings, from thickest to thinnest.
    static let stringNames = ["缠弦", "老弦", "中弦", "子弦"]

    /// English names of the four strings, from thickest to thinnest.
    /// The instrument name Pipa is always capitalised.
    static let stringNamesEN = ["Chan (4th)", "Lao (3rd)", "Zhong (2nd)", "Zi (1st)"]

    /// Number of xiang. The xiang sit on the neck and cover the first six
    /// semitones above each open string.
    static let xiangCount = 6

    /// Number of frets. The frets sit on the soundboard and continue the
    /// semitone ladder after the xiang.
    static let pinCount = 25

    /// Total number of stop positions, open string included:
    /// open string + six xiang + twenty-five frets.
    static let positionCount = 1 + xiangCount + pinCount

    /// Convert a MIDI pitch to a frequency, with A4 = 440 Hz as the reference.
    static func midiToFrequency(_ midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    /// Convert a frequency back to a MIDI pitch. The result may be fractional,
    /// which is what makes continuous slides possible.
    static func frequencyToMIDI(_ frequency: Double) -> Double {
        69.0 + 12.0 * log2(frequency / 440.0)
    }

    /// MIDI pitch of one string stopped at one position.
    /// - Parameters:
    ///   - string: string index, 0 is the Chan string.
    ///   - fret: position, 0 is the open string and each step above it raises
    ///     the pitch by one semitone.
    static func midi(string: Int, fret: Int) -> Int {
        guard openStringMIDI.indices.contains(string) else { return 69 }
        let clampedFret = max(0, min(fret, positionCount - 1))
        return openStringMIDI[string] + clampedFret
    }

    /// Frequency of one string stopped at one position.
    static func frequency(string: Int, fret: Int) -> Double {
        midiToFrequency(midi(string: string, fret: fret))
    }

    /// Display name of a position: 0 is the open string, 1-6 are xiang,
    /// 7 and above are frets.
    static func positionName(_ fret: Int) -> String {
        if fret == 0 { return "空弦" }
        if fret <= xiangCount { return "相\(fret)" }
        return "品\(fret - xiangCount)"
    }

    /// Note name, for example A3 or D4.
    static func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = midi / 12 - 1
        return "\(names[((midi % 12) + 12) % 12])\(octave)"
    }
}
