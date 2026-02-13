@preconcurrency import AVFoundation
import Synchronization

/// マイク入力フォーマットからSpeechAnalyzer要求フォーマットへ音声バッファを変換する。
/// `Mutex`で`AVAudioConverter`へのアクセスを直列化し、スレッド安全性を保証する。
final class BufferConverter: @unchecked Sendable {
    private let converter: Mutex<AVAudioConverter>

    let outputFormat: AVAudioFormat

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw BufferConverterError.converterCreationFailed
        }
        self.converter = Mutex(converter)
        self.outputFormat = outputFormat
    }

    nonisolated func convert(_ inputBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        try converter.withLock { converter in
            let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(
                ceil(Double(inputBuffer.frameLength) * ratio)
            )
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputFrameCount
            ) else {
                throw BufferConverterError.outputBufferCreationFailed
            }

            var error: NSError?
            let hasProvidedInput = Mutex(false)
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                let shouldReturnInput = hasProvidedInput.withLock { hasProvided in
                    if hasProvided {
                        return false
                    }
                    hasProvided = true
                    return true
                }
                if shouldReturnInput {
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                outStatus.pointee = .endOfStream
                return nil
            }
            if let error {
                throw BufferConverterError.conversionFailed(error.localizedDescription)
            }
            return outputBuffer
        }
    }
}

enum BufferConverterError: LocalizedError {
    case converterCreationFailed
    case outputBufferCreationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            "音声コンバータの作成に失敗しました。"
        case .outputBufferCreationFailed:
            "出力バッファの作成に失敗しました。"
        case let .conversionFailed(msg):
            "音声変換に失敗しました: \(msg)"
        }
    }
}
