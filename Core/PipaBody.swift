import Foundation
import Accelerate

/// Pipa 琴体的声学模型。
///
/// Pipa 是半梨形木箱，桐木面板、硬木背板，内部有一个明显的空气腔共振，
/// 面板本身还有若干阶振动模式。这里用五个 peaking 滤波器去逼近这些共振峰，
/// 它们决定了「这是 Pipa 而不是吉他」的音色骨架。
final class PipaBody {

    private var filters: [Biquad] = []

    /// 琴体尺寸缩放，1.0 为标准。数值越小琴体越大，共振越低。
    private let sizeScale: Double

    init(sampleRate: Double, sizeScale: Double = 1.0) {
        self.sizeScale = sizeScale
        let peaks: [(frequency: Double, q: Double, gainDB: Double)] = [
            (205, 3.5, 9.0),    // 空气腔共振，低音区厚度主要来自这里
            (420, 3.0, 6.0),    // 面板第一阶弯曲模式
            (760, 2.6, 4.5),
            (1350, 2.2, 3.5),
            (2600, 1.8, 2.5),   // 高频亮度，决定金属弦的颗粒感
        ]
        filters = peaks.map { peak in
            Biquad.peaking(
                sampleRate: sampleRate,
                frequency: peak.frequency * sizeScale,
                q: peak.q,
                gainDB: peak.gainDB
            )
        }
    }

    /// 逐样本处理，用于 Commuted Synthesis 之外的直接滤波。
    func process(_ input: Float) -> Float {
        var value = input
        for index in filters.indices {
            value = filters[index].process(value)
        }
        return value
    }

    /// 重置内部状态，切换音符前调用。
    func reset() {
        for index in filters.indices { filters[index].reset() }
    }

    // MARK: - Commuted Synthesis

    /// 把短激励与琴体脉冲响应卷积，得到「预卷积激励」。
    ///
    /// Commuted Synthesis 的关键在于交换运算顺序：琴体响应是时不变的，
    /// 与其对每个输出样本做一次长卷积，不如先把很短的激励信号与脉冲响应卷积一次，
    /// 再用结果去驱动弦模型，音色等效但计算量下降两三个数量级。
    /// - Parameters:
    ///   - excitation: 原始激励，通常只有几毫秒。
    ///   - impulseResponse: 琴体脉冲响应，可以是实测的，也可以由本类合成。
    /// - Returns: 预卷积后的激励，长度约为两者之和。
    static func commute(excitation: [Float], impulseResponse: [Float]) -> [Float] {
        guard !excitation.isEmpty, !impulseResponse.isEmpty else { return excitation }

        let filterLength = vDSP_Length(impulseResponse.count)
        let resultLength = vDSP_Length(excitation.count) + filterLength - 1
        var result = [Float](repeating: 0, count: Int(resultLength))

        excitation.withUnsafeBufferPointer { inputPointer in
            impulseResponse.withUnsafeBufferPointer { irPointer in
                result.withUnsafeMutableBufferPointer { outputPointer in
                    vDSP_conv(
                        inputPointer.baseAddress!, 1,
                        irPointer.baseAddress!, 1,
                        outputPointer.baseAddress!, 1,
                        resultLength,
                        filterLength
                    )
                }
            }
        }

        // 归一化，避免换了脉冲响应之后音量失控。
        var peak: Float = 0
        var scalar: Float = 0
        vDSP_maxmgv(result, 1, &peak, vDSP_Length(result.count))
        if peak > 1e-9 {
            scalar = 1 / peak
            vDSP_vsmul(result, 1, &scalar, &result, 1, vDSP_Length(result.count))
        }
        return result
    }

    /// 合成一个近似的琴体脉冲响应，用于没有实测录音时兜底。
    ///
    /// 做法是让一段极短的脉冲通过琴体滤波器组，再叠上指数衰减包络，
    /// 得到的响应保留了共振峰位置，但比实测的粗糙。
    static func synthesizeImpulseResponse(sampleRate: Double, lengthSeconds: Double = 0.25, sizeScale: Double = 1.0) -> [Float] {
        let body = PipaBody(sampleRate: sampleRate, sizeScale: sizeScale)
        let count = Int(sampleRate * lengthSeconds)
        var response = [Float](repeating: 0, count: count)

        // 让单位脉冲通过琴体滤波器组，滤波器自身的振铃就是脉冲响应的主体，
        // 再乘一个指数包络把尾巴收干净。
        for index in 0..<count {
            let input: Float = index == 0 ? 1.0 : 0.0
            let filtered = body.process(input)
            let decay = Float(exp(-Double(index) / (sampleRate * 0.06)))
            response[index] = filtered * decay
        }
        return response
    }
}

/// 双二阶滤波器，转置直接 II 型实现，数值上比直接 I 型稳定。
struct Biquad {
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }

    /// peaking EQ，按 Robert Bristow-Johnson 的音频滤波器手册构造。
    static func peaking(sampleRate: Double, frequency: Double, q: Double, gainDB: Double) -> Biquad {
        let amplitude = pow(10.0, gainDB / 40.0)
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let cosOmega = cos(omega)

        let b0 = Float(1 + alpha * amplitude)
        let b1 = Float(-2 * cosOmega)
        let b2 = Float(1 - alpha * amplitude)
        let a0 = Float(1 + alpha / amplitude)
        let a1 = Float(-2 * cosOmega)
        let a2 = Float(1 - alpha / amplitude)

        var filter = Biquad()
        filter.b0 = b0 / a0
        filter.b1 = b1 / a0
        filter.b2 = b2 / a0
        filter.a1 = a1 / a0
        filter.a2 = a2 / a0
        return filter
    }
}
