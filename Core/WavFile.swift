import Foundation

/// WAV 文件的读写。写出的 24 bit 文件可以直接作为作品集素材提交。
enum WavFile {

    /// 把单声道浮点样本写成 24 bit PCM WAV。
    static func writeMono24Bit(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(44 + samples.count * 3)

        let dataSize = samples.count * 3
        bytes.append(contentsOf: Array("RIFF".utf8))
        bytes.append(contentsOf: littleEndian(UInt32(36 + dataSize)))
        bytes.append(contentsOf: Array("WAVE".utf8))

        bytes.append(contentsOf: Array("fmt ".utf8))
        bytes.append(contentsOf: littleEndian(UInt32(16)))          // fmt 块长度
        bytes.append(contentsOf: littleEndian(UInt16(1)))           // PCM
        bytes.append(contentsOf: littleEndian(UInt16(1)))           // 单声道
        bytes.append(contentsOf: littleEndian(UInt32(sampleRate)))
        bytes.append(contentsOf: littleEndian(UInt32(sampleRate * 3))) // 字节率
        bytes.append(contentsOf: littleEndian(UInt16(3)))           // 块对齐
        bytes.append(contentsOf: littleEndian(UInt16(24)))          // 位深

        bytes.append(contentsOf: Array("data".utf8))
        bytes.append(contentsOf: littleEndian(UInt32(dataSize)))

        for sample in samples {
            let clamped = min(max(sample, -1.0), 1.0)
            let value = Int32(round(clamped * 8_388_607.0))
            let magnitude = value < 0 ? value & 0xFFFFFF : value
            bytes.append(UInt8(magnitude & 0xFF))
            bytes.append(UInt8((magnitude >> 8) & 0xFF))
            bytes.append(UInt8((magnitude >> 16) & 0xFF))
        }

        try Data(bytes).write(to: url)
    }

    /// 读取 WAV 为单声道浮点样本，支持 16 / 24 / 32 bit 整数与 32 bit 浮点。
    static func readMono(_ url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let data = try Data(contentsOf: url)
        guard data.count > 44 else { throw WavError.fileTooShort }

        var offset = 12
        var format: UInt16 = 0
        var channels: UInt16 = 0
        var sampleRate: UInt32 = 0
        var bitsPerSample: UInt16 = 0
        var dataRange: Range<Int>? = nil

        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(readLittleEndian(UInt32.self, from: data, at: offset + 4))
            let bodyStart = offset + 8

            if id == "fmt " {
                format = readLittleEndian(UInt16.self, from: data, at: bodyStart)
                channels = readLittleEndian(UInt16.self, from: data, at: bodyStart + 2)
                sampleRate = readLittleEndian(UInt32.self, from: data, at: bodyStart + 4)
                bitsPerSample = readLittleEndian(UInt16.self, from: data, at: bodyStart + 14)
            } else if id == "data" {
                dataRange = bodyStart..<(bodyStart + size)
            }

            offset = bodyStart + size + (size % 2)
        }

        guard let range = dataRange, channels > 0, bitsPerSample > 0 else {
            throw WavError.missingChunks
        }
        guard range.upperBound <= data.count else { throw WavError.truncatedData }

        let bytesPerSample = Int(bitsPerSample) / 8
        let frameCount = (range.count) / (bytesPerSample * Int(channels))
        var output = [Float](repeating: 0, count: frameCount)

        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<Int(channels) {
                let base = range.lowerBound + (frame * Int(channels) + channel) * bytesPerSample
                sum += decodeSample(data, at: base, bits: Int(bitsPerSample), format: format)
            }
            output[frame] = sum / Float(channels)
        }

        return (output, Int(sampleRate))
    }

    private static func decodeSample(_ data: Data, at offset: Int, bits: Int, format: UInt16) -> Float {
        if format == 3 && bits == 32 {
            let bitsValue = readLittleEndian(UInt32.self, from: data, at: offset)
            return Float(bitPattern: bitsValue)
        }
        switch bits {
        case 16:
            let value = readLittleEndian(Int16.self, from: data, at: offset)
            return Float(value) / 32768.0
        case 24:
            let low = UInt32(data[offset])
            let mid = UInt32(data[offset + 1]) << 8
            let high = UInt32(data[offset + 2]) << 16
            var raw = high | mid | low
            if raw & 0x800000 != 0 { raw |= 0xFF000000 }
            return Float(Int32(bitPattern: raw)) / 8_388_608.0
        case 32:
            let value = readLittleEndian(Int32.self, from: data, at: offset)
            return Float(value) / 2_147_483_648.0
        default:
            return 0
        }
    }

    private static func readLittleEndian<T: FixedWidthInteger>(_ type: T.Type, from data: Data, at offset: Int) -> T {
        var value: T = 0
        for byte in 0..<MemoryLayout<T>.size {
            value |= T(data[offset + byte]) << (8 * byte)
        }
        return value
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var mutable = value.littleEndian
        return withUnsafeBytes(of: &mutable) { Array($0) }
    }

    enum WavError: Error, CustomStringConvertible {
        case fileTooShort
        case missingChunks
        case truncatedData

        var description: String {
            switch self {
            case .fileTooShort: return "文件过短，不是有效的 WAV"
            case .missingChunks: return "缺少 fmt 或 data 块"
            case .truncatedData: return "data 块被截断"
            }
        }
    }
}
