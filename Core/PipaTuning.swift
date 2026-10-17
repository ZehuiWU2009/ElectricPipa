import Foundation

/// Pipa 的音乐参数：定弦、品位、音高换算。
///
/// 标准定弦由缠弦（最粗）到子弦（最细）为 A–d–e–a，
/// 对应科学音高 A3 / D4 / E4 / A4，是绝大多数曲目使用的「正调」。
/// 现代 Pipa 为六相二十五品，相邻相、品之间均为半音，按十二平均律排列。
enum PipaTuning {

    /// 四根弦的空弦 MIDI 音高，索引 0 为缠弦（最粗、最低），3 为子弦（最细、最高）。
    static let openStringMIDI: [Int] = [57, 62, 64, 69]

    /// 四根弦的传统名称，由粗到细。
    static let stringNames = ["缠弦", "老弦", "中弦", "子弦"]

    /// 四根弦的英文名称，由粗到细。注意乐器名 Pipa 首字母大写。
    static let stringNamesEN = ["Chan (4th)", "Lao (3rd)", "Zhong (2nd)", "Zi (1st)"]

    /// 相的数量。相位于琴颈，空弦上方的头六个半音由相确定。
    static let xiangCount = 6

    /// 品的数量。品位于面板，接在相之后继续按半音排列。
    static let pinCount = 25

    /// 可用的按音位置总数（含空弦）。空弦 + 六相 + 二十五品。
    static let positionCount = 1 + xiangCount + pinCount

    /// 把 MIDI 音高换算成频率，以 A4 = 440 Hz 为标准音。
    static func midiToFrequency(_ midi: Int) -> Double {
        440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0)
    }

    /// 把频率换算成 MIDI 音高（可能带小数，用于滑音）。
    static func frequencyToMIDI(_ frequency: Double) -> Double {
        69.0 + 12.0 * log2(frequency / 440.0)
    }

    /// 某根弦在某个品位上的 MIDI 音高。
    /// - Parameters:
    ///   - string: 弦索引，0 为缠弦。
    ///   - fret: 品位，0 为空弦，1 起每加一为高一个半音。
    static func midi(string: Int, fret: Int) -> Int {
        guard openStringMIDI.indices.contains(string) else { return 69 }
        let clampedFret = max(0, min(fret, positionCount - 1))
        return openStringMIDI[string] + clampedFret
    }

    /// 某根弦在某个品位上的频率。
    static func frequency(string: Int, fret: Int) -> Double {
        midiToFrequency(midi(string: string, fret: fret))
    }

    /// 品位位置的显示名称：0 为空弦，1–6 为相，7 起为品。
    static func positionName(_ fret: Int) -> String {
        if fret == 0 { return "空弦" }
        if fret <= xiangCount { return "相\(fret)" }
        return "品\(fret - xiangCount)"
    }

    /// 音名，例如 A3、D4。
    static func noteName(_ midi: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = midi / 12 - 1
        return "\(names[((midi % 12) + 12) % 12])\(octave)"
    }
}
