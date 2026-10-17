import Foundation

/// 一根 Pipa 弦：数字波导实现的 Karplus-Strong 拨弦模型。
///
/// 延迟线长度恰好等于基频的一个周期，拨弦时把整条延迟线填入经过塑形的噪声，
/// 这相当于给定弦的初始位移。每个样本读出末端、过环路低通、乘环路增益后写回原处，
/// 高频衰减得比低频快，噪声于是逐渐变成乐音。
///
/// 这一路修掉了三个都会让高音「有波形、没音高」的坑，值得记下来：
///
/// 1. 环路里的任何衰减都是按「每绕一圈」计的，而每秒绕的圈数就等于基频。
///    同样比例在 220 Hz 上无伤大雅，在 2349 Hz 上每秒复利两千多次，基频瞬间归零。
///    所以环路低通的响应必须随基频缩放，而不是固定在某个绝对截止频率上。
///
/// 2. 分数延迟用线性插值会引入一个低通，它在基频处的衰减同样逃不过上面的复利。
///    改用一阶全通，幅度恒等于 1，只贡献相位延迟，不带来任何能量损失。
///
/// 3. 环路低通在直流处的增益恰好是 1，直流衰减得比基频慢几十倍，
///    只要激励的均值不为零，余音里最后只剩一团低频哼声。所以激励必须严格零均值。
final class PipaString {

    let sampleRate: Double

    /// 当前基频。改变它会平滑地改变音高，推拉弦的滑音靠这个实现。
    /// 推拉弦时只重算延迟，不动音色，避免滑音过程中音色跳变。
    var frequency: Double {
        didSet { updateDelay() }
    }

    /// 延迟线的存储区，容量按最低可能基频预留，实际生效长度由 length 决定。
    private var buffer: [Float] = [Float](repeating: 0, count: 4096)
    private let capacity = 4096

    /// 生效的延迟线长度，也就是延迟线本身贡献的样本延迟。
    private var length: Int = 2

    /// 当前读写头位置。读出与写回发生在同一格，环绕一圈即为 length 个样本。
    private var index: Int = 0

    /// 一阶全通的系数与两级状态，负责分数延迟那一部分。
    private var allpassCoeff: Float = 0
    private var allpassXPrev: Float = 0
    private var allpassYPrev: Float = 0

    /// 环路中与延迟线无关的那部分延迟：低通相位延迟加上全通相位延迟。
    private var extraDelaySamples: Double = 0

    private var loopState: Float = 0

    /// 一阶低通系数，越大越暗。y[n] = (1-a)·x[n] + a·y[n-1] 里的 a。
    private var loopCoeff: Float = 0.5

    /// 每绕行一圈保留的能量比例，决定余音长度。
    private var damping: Float = 0.996

    /// 记录的明亮程度与期望余音，音色或音高变化后用来重算。
    private var brightness: Double = 0.6
    private var requestedDecay: Double = 2.0


    /// 泄漏积分器估计的能量，用来判断余音是否散尽。
    private var energy: Float = 0

    private(set) var isRinging: Bool = false

    /// 实时安全的伪随机噪声源（xorshift32）：不分配内存、不加锁，用来生成拨弦激励。
    /// 每个弦独立持有一份状态，确定性可复现，适合在音频实时线程上调用。
    private var noiseState: UInt32 = 0x12345678

    init(sampleRate: Double, frequency: Double) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        updateDelay()
    }

    // MARK: - 调音

    private var omega: Double {
        2.0 * Double.pi * max(frequency, 20.0) / sampleRate
    }

    /// 环路一阶低通在角频率 w 上的幅度响应。
    private static func loopMagnitude(coeff s: Double, at w: Double) -> Double {
        let real = 1.0 - s * cos(w)
        let imag = s * sin(w)
        return (1.0 - s) / max(sqrt(real * real + imag * imag), 1e-12)
    }

    /// 一阶低通在角频率 w 上的相位延迟。
    private static func loopPhaseDelay(coeff s: Double, at w: Double) -> Double {
        atan2(s * sin(w), 1.0 - s * cos(w)) / w
    }

    /// 一阶全通 (a + z⁻¹)/(1 + a·z⁻¹) 在角频率 w 上的相位延迟。
    /// 它的幅度恒等于 1，这正是它能替代线性插值做分数延迟的原因。
    private static func allpassPhaseDelay(coeff a: Double, at w: Double) -> Double {
        let numerator = atan2(-sin(w), a + cos(w))
        let denominator = atan2(-a * sin(w), 1.0 + a * cos(w))
        return -(numerator - denominator) / w
    }

    /// 解出能让基频处幅度等于 targetGain 的环路低通系数。幅度随系数单调递减，二分是稳的。
    private func solveLoopCoefficient(targetGain: Double) -> Float {
        var low = 0.0
        var high = 0.9995
        for _ in 0..<36 {
            let middle = (low + high) * 0.5
            if Self.loopMagnitude(coeff: middle, at: omega) > targetGain {
                low = middle
            } else {
                high = middle
            }
        }
        return Float((low + high) * 0.5)
    }

    /// 解出能让相位延迟等于 targetDelay 的全通系数。延迟随系数单调递减，二分是稳的。
    private func solveAllpassCoefficient(targetDelay: Double) -> Float {
        var low = -0.6
        var high = 0.95
        for _ in 0..<36 {
            let middle = (low + high) * 0.5
            if Self.allpassPhaseDelay(coeff: middle, at: omega) > targetDelay {
                low = middle
            } else {
                high = middle
            }
        }
        return Float((low + high) * 0.5)
    }

    /// 明亮程度 0 到 1 映射到基频处每绕一圈保留的能量比例。
    /// 这个比例同时决定余音上限：亮弦余音长，暗弦余音短，真实乐器正是如此。
    private static func loopGainForBrightness(_ brightness: Double) -> Double {
        let b = min(max(brightness, 0.0), 1.0)
        return 0.990 + (0.99995 - 0.990) * b
    }

    private func updateDelay() {
        let w = omega
        let s = Double(loopCoeff)

        let lowpassDelay = Self.loopPhaseDelay(coeff: s, at: w)

        // 期望的总延迟是一个周期。延迟线承担整数部分，全通承担剩下的零头。
        let total = sampleRate / max(frequency, 20.0)
        let remaining = total - lowpassDelay

        // 留半个样本给全通，让它工作在响应最平缓的区间。
        let integerPart = max(2, Int(floor(remaining - 0.5)))
        length = min(max(integerPart, 2), capacity - 1)
        let fractional = remaining - Double(length)

        allpassCoeff = solveAllpassCoefficient(targetDelay: fractional)
        extraDelaySamples = lowpassDelay + Self.allpassPhaseDelay(coeff: Double(allpassCoeff), at: w)

        if index >= length { index = index % length }

        applyDecay()
    }

    /// 按当前环路增益算出每圈该保留多少能量，使基频处的余音达到期望长度。
    private func applyDecay() {
        let loopGain = Self.loopMagnitude(coeff: Double(loopCoeff), at: omega)
        let lossPerLoop = max(-log(loopGain), 1e-9)

        // 每圈损失 lossPerLoop 时，衰减 60 dB 所能达到的最长余音。
        // 超过它物理上做不到，硬要给只会让总环路增益大于 1 而自激。
        let maximumDecay = 6.9078 / (max(frequency, 20.0) * lossPerLoop)
        let effective = min(max(requestedDecay, 0.02), 0.85 * maximumDecay)

        let total = pow(0.001, 1.0 / (effective * max(frequency, 20.0)))
        damping = Float(min(total / max(loopGain, 1e-9), 0.99999))
    }

    /// 整音高时重算音色，让不同音高的音色特征保持一致。
    private func retune() {
        loopCoeff = solveLoopCoefficient(targetGain: Self.loopGainForBrightness(brightness))
        updateDelay()
    }

    // MARK: - 参数

    /// 弦实际发出的基频，等于采样率除以环路总延迟。
    /// 这个值用来校验音准，不依赖任何信号分析，因此不会像自相关那样在高音区误判。
    var actualFrequency: Double {
        sampleRate / max(Double(length) + extraDelaySamples, 1.0)
    }

    func setBrightness(_ value: Double) {
        brightness = min(max(value, 0.0), 1.0)
        retune()
    }

    /// 设置期望余音长度，即衰减 60 dB 需要的秒数。
    /// 实际余音会被夹在这个弦在这个音高能做到的范围内。
    func setDecayTime(_ seconds: Double) {
        requestedDecay = seconds
        applyDecay()
    }

    // MARK: - 演奏

    /// 实时安全的伪随机噪声：xorshift32，返回 [-1, 1]。不分配内存、不加锁。
    private func nextNoise() -> Float {
        var x = noiseState
        x ^= x << 13
        x ^= x >> 17
        x ^= x << 5
        if x == 0 { x = 0x9E3779B9 }   // 防止退化到全零状态
        noiseState = x
        return Float(Int32(bitPattern: x)) / Float(Int32.max)
    }

    /// 拨弦。
    ///
    /// 物理上，拨弦是给弦一个初始位移：拨点的位置决定了哪些谐波被抵消，
    /// 这里用梳状滤波复现。激励必须填满整个周期，只写进尾部会被回写覆盖掉。
    /// - Parameters:
    ///   - amplitude: 力度，0 到 1。
    ///   - position: 拨弦位置，0 为靠琴码，1 为靠相，0.5 为常规位置。
    func pluck(amplitude: Double, position: Double) {
        // 每次拨弦重新对齐音色与余音，保证同一个音在任何品位上都听着一致。
        retune()

        let gain = Float(min(max(amplitude, 0.0), 1.0))
        let pos = min(max(position, 0.06), 0.94)

        // 激励直接在延迟线里生成，全程不分配内存、不调用随机源运行时。
        // 实时音频回调里分配内存或调用带锁的随机源会触发内核锁，造成爆音甚至崩溃，必须避免。
        for i in 0..<length {
            buffer[i] = nextNoise()
        }

        // 拨点的梳状滤波：拨点处的谐波节点会被抵消，这是拨弦位置改变音色的原因。
        let combDelay = max(1, Int(Double(length) * pos))
        if combDelay < length {
            for i in stride(from: length - 1, through: combDelay, by: -1) {
                buffer[i] -= buffer[i - combDelay] * 0.7
            }
        }

        // 去掉直流分量。环路低通在直流处增益恰好为 1，直流衰减得比基频慢几十倍，
        // 不扣掉的话余音里最后只剩一团低频哼声。
        var mean: Float = 0
        for i in 0..<length { mean += buffer[i] }
        mean /= Float(length)

        // 归一化到单位峰值，再按力度缩放，让力度只改变音量不改变音色。
        var peak: Float = 0
        for i in 0..<length {
            buffer[i] -= mean
            peak = max(peak, abs(buffer[i]))
        }
        let scale = peak > 1e-9 ? gain / peak : 0
        for i in 0..<length { buffer[i] *= scale }

        index = 0
        loopState = 0
        allpassXPrev = 0
        allpassYPrev = 0
        energy = 1
        isRinging = true
    }

    /// 止弦，把余音快速收掉。
    func damp() {
        for i in 0..<length { buffer[i] *= 0.02 }
        loopState = 0
        allpassXPrev = 0
        allpassYPrev = 0
        energy = 0
        isRinging = false
    }

    /// 渲染一个样本。
    func renderSample() -> Float {
        let raw = buffer[index]

        // 一阶全通给出分数延迟，幅度恒为 1，不会像线性插值那样偷走基频的能量。
        let delayed = allpassCoeff * raw + allpassXPrev - allpassCoeff * allpassYPrev
        allpassXPrev = raw
        allpassYPrev = delayed

        // 环路低通：高频每绕一圈损失更多，这是弦振动的衰减规律。
        let filtered = (1 - loopCoeff) * delayed + loopCoeff * loopState
        loopState = filtered

        buffer[index] = filtered * damping
        index = (index + 1) % length

        let magnitude = abs(filtered)
        energy = energy * 0.9995 + magnitude * magnitude
        isRinging = energy > 1e-9

        return delayed
    }
}
