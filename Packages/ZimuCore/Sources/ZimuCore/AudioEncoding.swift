import Foundation

/// 把单声道 Float 采样编码为 16-bit PCM WAV
public enum WAVEncoder {
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func appendString(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func appendUInt32(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        appendString("RIFF")
        appendUInt32(UInt32(36 + dataSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32(16)                       // fmt chunk size
        appendUInt16(1)                        // PCM
        appendUInt16(1)                        // 单声道
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * 2))   // byte rate
        appendUInt16(2)                        // block align
        appendUInt16(16)                       // bits per sample
        appendString("data")
        appendUInt32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, sample) in samples.enumerated() {
            let clamped = sample.isNaN ? 0 : max(-1, min(1, sample))
            pcm[i] = Int16(clamped * 32767).littleEndian
        }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

/// multipart/form-data 请求体
public struct MultipartFormData: Sendable {
    public let boundary: String
    private var body = Data()

    public init(boundary: String = "ZimuBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append("\(value)\r\n")
    }

    public mutating func addFile(name: String, filename: String, mimeType: String, data: Data) {
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    public func finalized() -> Data {
        var result = body
        result.append(contentsOf: Array("--\(boundary)--\r\n".utf8))
        return result
    }

    private mutating func append(_ string: String) {
        body.append(contentsOf: Array(string.utf8))
    }
}
