import AVFoundation
import Foundation
import Speech

#if os(iOS)

    // MARK: - Error Types

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
            case let .recognitionFailed(msg):
                return "認識に失敗しました: \(msg)"
            }
        }
    }

    // MARK: - Audio Processing Service

    final class AudioProcessingService {
        // MARK: - Internal Types

        /// 音声認識で取得した単語単位の情報
        private struct WordUnit {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
        }

        /// 発話区間（Voice Activity Detection結果）
        private struct SpeechSegment {
            let start: TimeInterval
            let end: TimeInterval
            var speakerLabel: String = ""
        }

        /// エネルギーフレーム
        private struct EnergyFrame {
            let start: Double
            let end: Double
            let energy: Float
            let zeroCrossingRate: Float // ゼロ交差率（音声特徴量）
        }

        // MARK: - Main Processing

        /// 録音後にまとめて処理（話者分離 + 文字起こし）
        func process(url: URL) async throws -> [TranscriptSegment] {
            // 権限チェック
            let speechAuth = await requestSpeechAuthorization()
            guard speechAuth else { throw AudioProcessingError.speechAuthDenied }

            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AudioProcessingError.fileNotFound
            }

            // 1) 音声特徴量フレーム作成（エネルギー + ゼロ交差率）
            let (energyFrames, _) = try loadEnergyFrames(url: url, frameDuration: 0.1)

            // 2) 改良版VADで発話区間を検出
            let speechSegments = detectSpeechSegments(frames: energyFrames)

            // 3) 話者変更点を検出して話者ラベルを割り当て
            let labeledSegments = assignSpeakerLabels(segments: speechSegments, frames: energyFrames)

            // 4) ASR（日本語）で文字起こし
            let words = try await recognizeJapanese(url: url)

            // 5) 単語を発話区間にマッピングして話者ラベルを付与
            var result: [TranscriptSegment] = []
            result.reserveCapacity(words.count)

            for word in words {
                let speaker = findSpeakerForTime(time: word.start, segments: labeledSegments)
                result.append(TranscriptSegment(
                    start: word.start,
                    end: word.end,
                    speaker: speaker,
                    text: word.text
                ))
            }

            // 6) 隣接する同一話者のセグメントを結合（ギャップ許容値を拡大）
            return mergeAdjacent(segments: result, gapTolerance: 3.0)
        }

        // MARK: - Speech Authorization

        private func requestSpeechAuthorization() async -> Bool {
            await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        }

        // MARK: - Speech Recognition

        private func recognizeJapanese(url: URL) async throws -> [WordUnit] {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")) else {
                throw AudioProcessingError.recognizerUnavailable
            }
            guard recognizer.isAvailable else {
                throw AudioProcessingError.recognizerUnavailable
            }

            let request = SFSpeechURLRecognitionRequest(url: url)
            // オンデバイス認識を強制しない（サーバーベース認識も許可）
            request.requiresOnDeviceRecognition = false
            request.shouldReportPartialResults = false

            // カスタム語彙を追加（認識のヒントとして使用）
            // vocabulary.json から読み込み
            let vocabulary = VocabularyLoader.loadAll()
            if !vocabulary.isEmpty {
                request.contextualStrings = vocabulary
            }

            // 句読点を自動的に追加（iOS 16+）
            request.addsPunctuation = true

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

                // 強参照保持
                _ = task
            }
        }

        // MARK: - Feature Extraction

        /// 音声を読み込み、フレームごとの特徴量（エネルギー + ゼロ交差率）を計算
        private func loadEnergyFrames(url: URL, frameDuration: Double) throws
            -> ([EnergyFrame], sampleRate: Double)
        {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let sampleRate = format.sampleRate

            guard let samples = readMonoFloatSamples(file: file) else {
                throw AudioProcessingError.unsupportedAudioFormat
            }

            let frameSize = Int(sampleRate * frameDuration)
            if frameSize <= 0 { throw AudioProcessingError.unsupportedAudioFormat }

            var frames: [EnergyFrame] = []
            frames.reserveCapacity(max(1, samples.count / frameSize))

            var i = 0
            while i < samples.count {
                let endIdx = min(i + frameSize, samples.count)
                let n = endIdx - i

                if n > 0 {
                    // エネルギー（RMS）
                    var sumSquares: Float = 0
                    for j in i ..< endIdx {
                        sumSquares += samples[j] * samples[j]
                    }
                    let rmsEnergy = sqrt(sumSquares / Float(n))

                    // ゼロ交差率
                    var zeroCrossings = 0
                    for j in (i + 1) ..< endIdx {
                        if (samples[j] >= 0) != (samples[j - 1] >= 0) {
                            zeroCrossings += 1
                        }
                    }
                    let zcr = Float(zeroCrossings) / Float(n)

                    frames.append(EnergyFrame(
                        start: Double(i) / sampleRate,
                        end: Double(endIdx) / sampleRate,
                        energy: rmsEnergy,
                        zeroCrossingRate: zcr
                    ))
                }
                i = endIdx
            }

            return (frames, sampleRate)
        }

        /// AVAudioFile を mono の Float 配列として読み込む
        private func readMonoFloatSamples(file: AVAudioFile) -> [Float]? {
            let processingFormat = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)

            // Float32形式でバッファを作成（processingFormatがFloatでない場合も対応）
            guard let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: processingFormat.sampleRate, channels: 1, interleaved: false) else {
                return nil
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: frameCount) else {
                return nil
            }

            // ファイルフォーマットからFloat32への変換コンバーター
            guard let converter = AVAudioConverter(from: processingFormat, to: floatFormat) else {
                return nil
            }

            // 元のフォーマットでバッファを読み込む
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: frameCount) else {
                return nil
            }

            do {
                try file.read(into: inputBuffer)
            } catch {
                return nil
            }

            // 変換
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return inputBuffer
            }

            converter.convert(to: buffer, error: &error, withInputFrom: inputBlock)

            if error != nil {
                return nil
            }

            guard let floatData = buffer.floatChannelData else {
                return nil
            }

            let ch = floatData[0]
            let n = Int(buffer.frameLength)
            return Array(UnsafeBufferPointer(start: ch, count: n))
        }

        // MARK: - Voice Activity Detection (VAD)

        /// 改良版VAD：エネルギーとゼロ交差率を使って発話区間を検出
        private func detectSpeechSegments(frames: [EnergyFrame]) -> [SpeechSegment] {
            guard !frames.isEmpty else { return [] }

            // 適応的閾値計算
            let energies = frames.map { $0.energy }
            let sortedEnergies = energies.sorted()

            // 下位10%を背景ノイズとして扱う（より低いノイズフロア）
            let noiseFloorIndex = sortedEnergies.count / 10
            let noiseFloor = sortedEnergies[max(0, noiseFloorIndex)]

            // 閾値 = ノイズフロア * 1.5 または最大値の5%のいずれか大きい方（より低い閾値）
            let maxEnergy = sortedEnergies.last ?? 0.001
            let threshold = max(noiseFloor * 1.5, maxEnergy * 0.05)

            // ヒステリシス付き検出（開始は高閾値、終了は低閾値）
            let highThreshold = threshold
            let lowThreshold = threshold * 0.5

            var segments: [SpeechSegment] = []
            var inSpeech = false
            var segmentStart: Double = 0

            // ハングオーバー（発話終了後の猶予）
            var hangoverFrames = 0
            let maxHangover = 3 // 0.3秒の猶予

            for (index, frame) in frames.enumerated() {
                if !inSpeech {
                    // 発話開始検出
                    if frame.energy > highThreshold {
                        inSpeech = true
                        segmentStart = frame.start
                        hangoverFrames = 0
                    }
                } else {
                    // 発話終了検出
                    if frame.energy < lowThreshold {
                        hangoverFrames += 1
                        if hangoverFrames >= maxHangover {
                            // 発話終了
                            let prevFrame = frames[max(0, index - maxHangover)]
                            segments.append(SpeechSegment(
                                start: segmentStart,
                                end: prevFrame.end
                            ))
                            inSpeech = false
                            hangoverFrames = 0
                        }
                    } else {
                        hangoverFrames = 0
                    }
                }
            }

            // 最後の発話が終わっていない場合
            if inSpeech {
                segments.append(SpeechSegment(
                    start: segmentStart,
                    end: frames.last!.end
                ))
            }

            // 短すぎる発話区間を除去（0.3秒未満）
            segments = segments.filter { $0.end - $0.start >= 0.3 }

            // 近い発話区間をマージ（0.5秒以内）
            return mergeSpeechSegments(segments, gapThreshold: 0.5)
        }

        /// 近接する発話区間をマージ
        private func mergeSpeechSegments(_ segments: [SpeechSegment], gapThreshold: TimeInterval) -> [SpeechSegment] {
            guard !segments.isEmpty else { return [] }

            var merged: [SpeechSegment] = []
            var current = segments[0]

            for segment in segments.dropFirst() {
                if segment.start - current.end <= gapThreshold {
                    // マージ
                    current = SpeechSegment(start: current.start, end: segment.end)
                } else {
                    merged.append(current)
                    current = segment
                }
            }
            merged.append(current)

            return merged
        }

        // MARK: - Speaker Diarization (Multi-Speaker Support)

        /// 発話区間に話者ラベルを割り当て（複数話者対応）
        /// - K-means風のクラスタリングで話者を自動検出
        /// - 発話間の無音区間とエネルギー特徴量を使用
        private func assignSpeakerLabels(segments: [SpeechSegment], frames: [EnergyFrame]) -> [SpeechSegment] {
            guard !segments.isEmpty else { return [] }

            var labeled = segments

            // 1) 各発話区間の特徴量を計算
            var segmentFeatures: [SpeakerFeature] = []

            for (index, segment) in segments.enumerated() {
                let relevantFrames = frames.filter { $0.start >= segment.start && $0.end <= segment.end }

                if relevantFrames.isEmpty {
                    segmentFeatures.append(SpeakerFeature(index: index, avgEnergy: 0, avgZcr: 0, duration: segment.end - segment.start))
                    continue
                }

                let avgEnergy = relevantFrames.map { $0.energy }.reduce(0, +) / Float(relevantFrames.count)
                let avgZcr = relevantFrames.map { $0.zeroCrossingRate }.reduce(0, +) / Float(relevantFrames.count)
                let duration = segment.end - segment.start

                segmentFeatures.append(SpeakerFeature(index: index, avgEnergy: avgEnergy, avgZcr: avgZcr, duration: duration))
            }

            // 2) 話者変更点を検出
            var changePoints = [0] // 最初のセグメントは常に変更点

            for i in 1 ..< segments.count {
                let gap = segments[i].start - segments[i - 1].end
                let currentFeature = segmentFeatures[i]
                let prevFeature = segmentFeatures[i - 1]

                let isSpeakerChange = detectSpeakerChange(
                    gap: gap,
                    currentFeature: currentFeature,
                    prevFeature: prevFeature
                )

                if isSpeakerChange {
                    changePoints.append(i)
                }
            }

            // 3) 特徴量ベースのクラスタリングで話者を割り当て
            let speakerAssignments = clusterSpeakers(features: segmentFeatures, changePoints: changePoints)

            // 4) 話者ラベルを適用
            for i in 0 ..< labeled.count {
                let speakerId = speakerAssignments[i]
                labeled[i].speakerLabel = speakerLabel(for: speakerId)
            }

            return labeled
        }

        /// 話者特徴量構造体
        private struct SpeakerFeature {
            let index: Int
            let avgEnergy: Float
            let avgZcr: Float
            let duration: TimeInterval

            /// 正規化された特徴ベクトルを返す
            func normalizedVector(energyRange: (min: Float, max: Float), zcrRange: (min: Float, max: Float)) -> (Float, Float) {
                let normEnergy = (avgEnergy - energyRange.min) / max(energyRange.max - energyRange.min, 0.001)
                let normZcr = (avgZcr - zcrRange.min) / max(zcrRange.max - zcrRange.min, 0.001)
                return (normEnergy, normZcr)
            }
        }

        /// 話者変更を検出
        private func detectSpeakerChange(gap: TimeInterval, currentFeature: SpeakerFeature, prevFeature: SpeakerFeature) -> Bool {
            // 話者変更の判定は、間隔だけでなく音声特徴量の変化も考慮
            // 1人で話している場合、間があいても同じ話者として扱う

            let energyRatio = currentFeature.avgEnergy / max(prevFeature.avgEnergy, 0.001)
            let zcrRatio = currentFeature.avgZcr / max(prevFeature.avgZcr, 0.001)

            // 特徴量の変化が小さい場合は同じ話者
            let isEnergyStable = energyRatio >= 0.3 && energyRatio <= 3.0
            let isZcrStable = zcrRatio >= 0.4 && zcrRatio <= 2.5

            // 両方の特徴量が安定している場合は、間隔に関係なく同じ話者
            if isEnergyStable && isZcrStable {
                return false
            }

            // 特徴量が大きく変化した場合のみ話者変更と判定
            // 1) 非常に大きなエネルギー変化（0.2倍未満 or 5倍以上）
            if energyRatio < 0.2 || energyRatio > 5.0 {
                // ただし、間隔が短すぎる場合（0.3秒未満）は無視
                if gap >= 0.3 {
                    return true
                }
            }

            // 2) エネルギーとゼロ交差率の両方が大きく変化
            if (energyRatio < 0.4 || energyRatio > 2.5) && (zcrRatio < 0.5 || zcrRatio > 2.0) {
                if gap >= 0.5 {
                    return true
                }
            }

            return false
        }

        /// 特徴量ベースで話者をクラスタリング
        private func clusterSpeakers(features: [SpeakerFeature], changePoints: [Int]) -> [Int] {
            guard !features.isEmpty else { return [] }

            // 特徴量の範囲を計算（正規化用）
            let energies = features.map { $0.avgEnergy }
            let zcrs = features.map { $0.avgZcr }
            let energyRange = (min: energies.min() ?? 0, max: energies.max() ?? 1)
            let zcrRange = (min: zcrs.min() ?? 0, max: zcrs.max() ?? 1)

            // 各セグメントの正規化特徴量
            let normalizedFeatures = features.map { $0.normalizedVector(energyRange: energyRange, zcrRange: zcrRange) }

            // 変更点ごとにグループ化
            var segments: [[Int]] = []
            var currentGroup: [Int] = []
            let changePointSet = Set(changePoints)

            for i in 0 ..< features.count {
                if changePointSet.contains(i), !currentGroup.isEmpty {
                    segments.append(currentGroup)
                    currentGroup = []
                }
                currentGroup.append(i)
            }
            if !currentGroup.isEmpty {
                segments.append(currentGroup)
            }

            // 各グループの代表特徴量を計算
            var groupCentroids: [(energy: Float, zcr: Float)] = []
            for group in segments {
                let avgEnergy = group.map { normalizedFeatures[$0].0 }.reduce(0, +) / Float(group.count)
                let avgZcr = group.map { normalizedFeatures[$0].1 }.reduce(0, +) / Float(group.count)
                groupCentroids.append((avgEnergy, avgZcr))
            }

            // グループを特徴量の類似度でクラスタリング
            var speakerIds = [Int](repeating: 0, count: features.count)
            var clusterCentroids: [(energy: Float, zcr: Float)] = []
            var groupToCluster: [Int] = []

            for (groupIndex, centroid) in groupCentroids.enumerated() {
                var bestCluster = -1
                var bestDistance = Float.greatestFiniteMagnitude

                // 既存のクラスタとの距離を計算
                for (clusterIndex, clusterCentroid) in clusterCentroids.enumerated() {
                    let distance = sqrt(
                        pow(centroid.energy - clusterCentroid.energy, 2) +
                            pow(centroid.zcr - clusterCentroid.zcr, 2)
                    )

                    // 距離が閾値以下なら同じ話者
                    if distance < 0.4, distance < bestDistance {
                        bestDistance = distance
                        bestCluster = clusterIndex
                    }
                }

                if bestCluster == -1 {
                    // 新しい話者として登録
                    bestCluster = clusterCentroids.count
                    clusterCentroids.append(centroid)
                } else {
                    // クラスタの重心を更新
                    let existingCentroid = clusterCentroids[bestCluster]
                    let groupsInCluster = groupToCluster.filter { $0 == bestCluster }.count + 1
                    clusterCentroids[bestCluster] = (
                        (existingCentroid.energy * Float(groupsInCluster - 1) + centroid.energy) / Float(groupsInCluster),
                        (existingCentroid.zcr * Float(groupsInCluster - 1) + centroid.zcr) / Float(groupsInCluster)
                    )
                }

                groupToCluster.append(bestCluster)

                // グループ内の全セグメントに話者IDを割り当て
                for segmentIndex in segments[groupIndex] {
                    speakerIds[segmentIndex] = bestCluster
                }
            }

            return speakerIds
        }

        /// 話者IDからラベル文字列を生成
        private func speakerLabel(for speakerId: Int) -> String {
            // 最初の話者は「話者1」、2番目は「話者2」...
            // 営業会話の場合、話者1を営業、話者2以降を顧客として扱うことも可能
            let labels = ["話者1", "話者2", "話者3", "話者4", "話者5", "話者6", "話者7", "話者8"]
            if speakerId < labels.count {
                return labels[speakerId]
            }
            return "話者\(speakerId + 1)"
        }

        /// 指定時刻の話者を検索
        private func findSpeakerForTime(time: TimeInterval, segments: [SpeechSegment]) -> String {
            // 時刻が含まれる発話区間を探す
            for segment in segments {
                if time >= segment.start && time <= segment.end {
                    return segment.speakerLabel
                }
            }

            // 含まれない場合は最も近い発話区間の話者を返す
            var closestSegment: SpeechSegment?
            var minDistance = Double.greatestFiniteMagnitude

            for segment in segments {
                let distance = min(abs(time - segment.start), abs(time - segment.end))
                if distance < minDistance {
                    minDistance = distance
                    closestSegment = segment
                }
            }

            return closestSegment?.speakerLabel ?? "営業"
        }

        // MARK: - Merge for Readability

        /// 隣接する同一話者のセグメントを結合
        /// - gapTolerance: この時間以内なら同一話者として結合
        /// - 同一話者が連続する限り、ギャップに関係なく結合する
        private func mergeAdjacent(segments: [TranscriptSegment], gapTolerance _: TimeInterval) -> [TranscriptSegment] {
            guard !segments.isEmpty else { return [] }

            var merged: [TranscriptSegment] = []
            merged.reserveCapacity(segments.count / 2)

            var cur = segments[0]

            for s in segments.dropFirst() {
                let sameSpeaker = (s.speaker == cur.speaker)

                // 同じ話者なら常にマージ（間があいても同一話者なら結合）
                if sameSpeaker {
                    // テキストを結合する際、句読点があれば改行を挿入
                    let combinedText = combineTextWithLineBreaks(cur.text, s.text)
                    cur = TranscriptSegment(
                        start: cur.start,
                        end: s.end,
                        speaker: cur.speaker,
                        text: combinedText
                    )
                } else {
                    // 話者が変わった場合のみ新しいセグメントを開始
                    merged.append(cur)
                    cur = s
                }
            }
            merged.append(cur)

            // 最終的なテキストをフォーマット
            return merged.map { segment in
                TranscriptSegment(
                    start: segment.start,
                    end: segment.end,
                    speaker: segment.speaker,
                    text: formatTextWithPunctuation(segment.text)
                )
            }
        }

        /// テキストを結合する際に、句読点で適切に区切る
        private func combineTextWithLineBreaks(_ text1: String, _ text2: String) -> String {
            let t1 = text1.trimmingCharacters(in: .whitespaces)
            let t2 = text2.trimmingCharacters(in: .whitespaces)

            // text1が句読点で終わっている場合は改行を挿入
            if t1.hasSuffix("。") || t1.hasSuffix("？") || t1.hasSuffix("！") ||
                t1.hasSuffix(".") || t1.hasSuffix("?") || t1.hasSuffix("!")
            {
                return t1 + "\n" + t2
            }

            return t1 + t2
        }

        /// テキストを句読点で整形（句点の後に改行を挿入）
        private func formatTextWithPunctuation(_ text: String) -> String {
            var result = text

            // 句点（。）の後に改行を挿入（既に改行がない場合）
            result = result.replacingOccurrences(of: "。", with: "。\n")
            result = result.replacingOccurrences(of: "？", with: "？\n")
            result = result.replacingOccurrences(of: "！", with: "！\n")

            // 連続する改行を1つに
            while result.contains("\n\n") {
                result = result.replacingOccurrences(of: "\n\n", with: "\n")
            }

            // 末尾の改行を削除
            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
#endif
