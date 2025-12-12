import Foundation
import AVFoundation
import Speech

enum AudioProcessingError: LocalizedError {
    case fileNotFound
    case unsupportedAudioFormat
    case speechAuthDenied
    case recognizerUnavailable
    case onDeviceNotSupported
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "音声ファイルが見つかりません。"
        case .unsupportedAudioFormat:
            return "音声フォーマットが未対応です。"
        case .speechAuthDenied:
            return "音声認識の権限がありません（設定アプリで許可してください）。"
        case .recognizerUnavailable:
            return "音声認識が利用できません。"
        case .onDeviceNotSupported:
            return "この端末/設定ではオンデバイス認識が利用できません。"
        case .recognitionFailed(let msg):
            return "認識に失敗しました: \(msg)"
        }
    }
}

final class AudioProcessingService {

    // Speech 側の単語セグメント（自前）
    private struct WordUnit {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    /// 録音後にまとめて処理
    func process(url: URL) async throws -> [TranscriptSegment] {
        // 権限
        let speechAuth = await requestSpeechAuthorization()
        guard speechAuth else { throw AudioProcessingError.speechAuthDenied }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioProcessingError.fileNotFound
        }

        // 1) エネルギーフレーム作成（簡易VADのため）
        let (energyFrames, _) = try loadEnergyFrames(url: url, frameDuration: 0.25)

        // 2) VADしきい値（平均 * 1.2 + 下限）
        let energies = energyFrames.map { $0.energy }
        let mean = energies.reduce(0, +) / Float(max(energies.count, 1))
        let vadThreshold = max(0.008, mean * 1.2)

        let voiced = energyFrames.filter { $0.energy >= vadThreshold }
        let voicedMean = voiced.map { $0.energy }.reduce(0, +) / Float(max(voiced.count, 1))

        // 3) ASR（オンデバイス日本語）
        let words = try await recognizeJapaneseOnDevice(url: url)

        // 4) 単語ごとに近傍エネルギーを参照して「営業/顧客」ラベル付け
        var raw: [TranscriptSegment] = []
        raw.reserveCapacity(words.count)

        for w in words {
            let e = energyNear(time: w.start, in: energyFrames)
            let speaker = (e >= voicedMean) ? "営業" : "顧客"
            raw.append(TranscriptSegment(start: w.start, end: w.end, speaker: speaker, text: w.text))
        }

        // 5) 見やすいように隣接同話者を結合
        return mergeAdjacent(segments: raw, gapTolerance: 0.6)
    }

    // MARK: - Speech Authorization

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - Speech Recognition (On-device)

    private func recognizeJapaneseOnDevice(url: URL) async throws -> [WordUnit] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")) else {
            throw AudioProcessingError.recognizerUnavailable
        }
        guard recognizer.isAvailable else {
            throw AudioProcessingError.recognizerUnavailable
        }

        if recognizer.supportsOnDeviceRecognition == false {
            throw AudioProcessingError.onDeviceNotSupported
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false

            let task = recognizer.recognitionTask(with: request) { result, error in
                if resumed { return }

                if let error {
                    resumed = true
                    cont.resume(throwing: AudioProcessingError.recognitionFailed(error.localizedDescription))
                    return
                }

                guard let result else { return }

                if result.isFinal {
                    resumed = true
                    let units = result.bestTranscription.segments.map { s in
                        WordUnit(
                            start: s.timestamp,
                            end: s.timestamp + s.duration,
                            text: s.substring
                        )
                    }
                    cont.resume(returning: units)
                }
            }

            // 強参照（念のため）
            _ = task
        }
    }

    // MARK: - Energy / VAD helpers

    /// 音声を float で読み込み、frameDuration秒ごとの平均絶対値(energy)を作る
    private func loadEnergyFrames(url: URL, frameDuration: Double) throws
    -> ([(start: Double, end: Double, energy: Float)], sampleRate: Double) {

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate

        guard let mono = readMonoFloatSamples(file: file) else {
            throw AudioProcessingError.unsupportedAudioFormat
        }

        let frameSize = Int(sampleRate * frameDuration)
        if frameSize <= 0 { throw AudioProcessingError.unsupportedAudioFormat }

        var frames: [(start: Double, end: Double, energy: Float)] = []
        frames.reserveCapacity(max(1, mono.count / frameSize))

        var i = 0
        while i < mono.count {
            let end = min(i + frameSize, mono.count)
            var energy: Float = 0
            let n = end - i
            if n > 0 {
                for j in i..<end {
                    energy += abs(mono[j])
                }
                energy /= Float(n)
            }
            frames.append((
                start: Double(i) / sampleRate,
                end: Double(end) / sampleRate,
                energy: energy
            ))
            i = end
        }

        return (frames, sampleRate)
    }

    /// AVAudioFile を AVAudioPCMBuffer に読み込んで mono の Float 配列にする
    private func readMonoFloatSamples(file: AVAudioFile) -> [Float]? {
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }

        guard let floatData = buffer.floatChannelData else {
            return nil
        }

        // monoなら [0]、stereoでも左ch [0] を使う
        let ch = floatData[0]
        let n = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: ch, count: n))
    }

    private func energyNear(time: TimeInterval,
                            in frames: [(start: Double, end: Double, energy: Float)]) -> Float {
        var best: Float = 0
        var bestDist = Double.greatestFiniteMagnitude
        for f in frames {
            let center = (f.start + f.end) / 2
            let d = abs(center - time)
            if d < bestDist {
                bestDist = d
                best = f.energy
            }
        }
        return best
    }

    // MARK: - Merge for readability

    private func mergeAdjacent(segments: [TranscriptSegment],
                               gapTolerance: TimeInterval) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return [] }

        var merged: [TranscriptSegment] = []
        merged.reserveCapacity(segments.count / 2)

        var cur = segments[0]

        for s in segments.dropFirst() {
            let sameSpeaker = (s.speaker == cur.speaker)
            let closeInTime = (s.start - cur.end) <= gapTolerance

            if sameSpeaker && closeInTime {
                cur = TranscriptSegment(
                    start: cur.start,
                    end: s.end,
                    speaker: cur.speaker,
                    text: cur.text + s.text
                )
            } else {
                merged.append(cur)
                cur = s
            }
        }
        merged.append(cur)
        return merged
    }
}
