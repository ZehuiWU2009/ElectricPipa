import Foundation

/// 四弦 Pipa 合成引擎。
///
/// 四根弦各自是一段数字波导，混合之后一起进入琴体滤波器组。
/// 真实乐器里四根弦都耦合到同一个音箱，所以琴体只做一次，而不是每根弦各做一次。
final class PipaSynth {

    static let stringCount = 4

    let sampleRate: Double
    private var strings: [PipaString] = []

    /// 琴体共振，作用于四弦混合之后的输出。
    private let body: PipaBody

    /// 总输出增益。
    var masterGain: Float = 0.5

    init(sampleRate: Double, bodySizeScale: Double = 1.0) {
        self.sampleRate = sampleRate
        self.body = PipaBody(sampleRate: sampleRate, sizeScale: bodySizeScale)

        for index in 0..<Self.stringCount {
            let frequency = PipaTuning.frequency(string: index, fret: 0)
            let string = PipaString(sampleRate: sampleRate, frequency: frequency)
            // 粗弦更暗更长，细弦更亮更短，这是四根弦真实的音色梯度。
            let thickness = Self.stringCount > 1 ? Double(index) / Double(Self.stringCount - 1) : 0
            string.setBrightness(0.34 + 0.42 * thickness)
            string.setDecayTime(4.6 - 2.6 * thickness)
            strings.append(string)
        }
    }

    /// 拨某根弦的某个品位。
    /// - Parameters:
    ///   - string: 弦索引，0 为缠弦（最粗）。
    ///   - fret: 品位，0 为空弦。
    ///   - velocity: 力度，0 到 1。
    ///   - position: 右手拨弦位置，0.5 为常规位置，越小越靠近琴码、音色越硬。
    func pluck(string: Int, fret: Int, velocity: Double = 0.8, position: Double = 0.5) {
        guard strings.indices.contains(string) else { return }
        let target = strings[string]

        // 先定音高，余音长度和延迟线长度都依赖它。
        target.frequency = PipaTuning.frequency(string: string, fret: fret)

        // 按弦缩短了振动长度，余音相应变短。
        let thickness = Self.stringCount > 1 ? Double(string) / Double(Self.stringCount - 1) : 0
        let baseDecay = 4.6 - 2.6 * thickness
        let fretFactor = 1.0 / (1.0 + Double(fret) * 0.035)
        target.setDecayTime(baseDecay * fretFactor)

        target.pluck(amplitude: velocity, position: position)
    }

    /// 校验用：把某根弦设到指定品位，返回延迟线实际给出的基频。
    /// 这个值不受信号分析误差影响，用来做全音域音准检查。
    func measuredFrequency(string: Int, fret: Int) -> Double {
        guard strings.indices.contains(string) else { return 0 }
        let target = strings[string]
        target.frequency = PipaTuning.frequency(string: string, fret: fret)
        return target.actualFrequency
    }

    /// 以任意频率发声，用于泛音和滑音的起点。
    func pluckFrequency(string: Int, frequency: Double, velocity: Double = 0.8, position: Double = 0.5) {
        guard strings.indices.contains(string) else { return }
        strings[string].frequency = frequency
        strings[string].pluck(amplitude: velocity, position: position)
    }

    /// 推弦或拉弦，把某根弦的音高连续推到目标频率。
    func bend(string: Int, to frequency: Double) {
        guard strings.indices.contains(string) else { return }
        strings[string].frequency = frequency
    }

    /// 止弦。
    func damp(string: Int) {
        guard strings.indices.contains(string) else { return }
        strings[string].damp()
    }

    /// 全部止弦。
    func dampAll() {
        for index in strings.indices { strings[index].damp() }
    }

    /// 统一设定四根弦的明亮程度，0 暗到 1 亮。
    func setBrightness(_ value: Double) {
        for index in strings.indices { strings[index].setBrightness(value) }
    }

    /// 扫弦，四根弦依次快速发声。
    /// - Parameter ascending: true 为由缠弦扫向子弦（拂），false 为反向（扫）。
    func strum(ascending: Bool = true, velocity: Double = 0.75, spacing: Double = 0.018) {
        let order = ascending ? Array(0..<Self.stringCount) : Array((0..<Self.stringCount).reversed())
        for (offset, string) in order.enumerated() {
            let delay = spacing * Double(offset)
            Scheduler.shared.schedule(after: delay) { [weak self] in
                self?.pluck(string: string, fret: 0, velocity: velocity * (1.0 - Double(offset) * 0.06))
            }
        }
    }

    /// 轮指，在一段时间内以固定密度反复拨同一根弦。
    /// - Parameter rate: 每秒拨弦次数，专业演奏可达每秒 8 到 12 次。
    func tremolo(string: Int, fret: Int, rate: Double, duration: Double, velocity: Double = 0.55) {
        let count = max(1, Int(rate * duration))
        for index in 0..<count {
            let delay = duration * Double(index) / Double(count)
            // 轮指由食指、中指、无名指、小指依次弹出，力度天然有起伏。
            let accent = 1.0 + 0.18 * sin(Double(index % 4) * 1.7)
            Scheduler.shared.schedule(after: delay) { [weak self] in
                self?.pluck(string: string, fret: fret, velocity: velocity * accent, position: 0.55)
            }
        }
    }

    /// 渲染一个样本。
    func renderSample() -> Float {
        Scheduler.shared.advance(sampleRate: sampleRate)
        var sum: Float = 0
        for index in strings.indices {
            sum += strings[index].renderSample()
        }
        return body.process(sum) * masterGain
    }

    /// 渲染一段到缓冲区。
    func render(into output: inout [Float], count: Int) {
        for index in 0..<count {
            output[index] = renderSample()
        }
    }
}

/// 极简的样本精度事件调度器，用于在离线渲染里安排扫弦和轮指的时间差。
final class Scheduler: @unchecked Sendable {
    static let shared = Scheduler()

    private var events: [(time: Double, action: () -> Void)] = []
    private var elapsed: Double = 0

    func schedule(after seconds: Double, action: @escaping () -> Void) {
        events.append((elapsed + seconds, action))
        events.sort { $0.time < $1.time }
    }

    func advance(sampleRate: Double) {
        elapsed += 1.0 / sampleRate
        while let first = events.first, first.time <= elapsed {
            events.removeFirst()
            first.action()
        }
    }

    func reset() {
        events.removeAll()
        elapsed = 0
    }
}
