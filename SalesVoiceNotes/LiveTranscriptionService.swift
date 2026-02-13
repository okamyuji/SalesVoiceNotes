import AVFoundation
import CoreMedia
import Observation
import os
import Speech

/// 録音＋リアルタイム文字起こし＋話者分離を統合するサービス。
///
/// プロジェクト設定 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` により暗黙的に `@MainActor`。
@Observable
final class LiveTranscriptionService {
    // MARK: - Published State

    var segments: [TranscriptSegment] = []
    var statusText: String = "待機中"
    var isRecording: Bool = false
    var isModelReady: Bool = false
    var modelProgress: String?
    var errorText: String?

    // MARK: - Private Properties

    private var audioEngine: AVAudioEngine?
    private var bufferConverter: BufferConverter?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var sampleContinuation: AsyncStream<[Float]>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var analyzerTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var sampleConsumerTask: Task<Void, Never>?
    private var energyFrames: [EnergyFrame] = []
    private var reservedLocale: Locale?

    private var tapSampleRate: Double = 16000

    // MARK: - Constants

    private static let frameDuration: Double = 0.25
    private static let gapTolerance: TimeInterval = 0.6
    private nonisolated static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "SalesVoiceNotes",
        category: "LiveTranscription"
    )

    // MARK: - Model Preparation

    func prepareModel() async {
        statusText = "モデルを確認中..."
        modelProgress = "確認中..."

        do {
            let locale = Locale(identifier: "ja-JP")
            let supported = await SpeechTranscriber.supportedLocales
            guard supported.contains(where: { $0.identifier.hasPrefix("ja") }) else {
                errorText = "日本語はこのデバイスでサポートされていません。"
                modelProgress = nil
                return
            }

            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.identifier.hasPrefix("ja") }) {
                try await downloadModel(locale: locale)
            }
            try await ensureLocaleReserved(locale: locale)

            isModelReady = true
            statusText = "準備完了"
            modelProgress = nil
        } catch {
            errorText = "モデル準備に失敗: \(error.localizedDescription)"
            modelProgress = nil
        }
    }

    // MARK: - Recording Control

    func startRecording() async {
        guard !isRecording else { return }
        errorText = nil

        let locale = Locale(identifier: "ja-JP")
        do {
            try await ensureLocaleReserved(locale: locale)
        } catch {
            errorText = "音声認識ロケールの確保に失敗: \(error.localizedDescription)"
            return
        }

        guard await requestMicPermission() else {
            errorText = "マイク権限がありません（設定アプリで許可してください）"
            return
        }
        guard await requestSpeechAuthorization() else {
            errorText = "音声認識の権限がありません（設定アプリで許可してください）"
            return
        }

        do {
            resetState()
            try configureAudioSession()

            let engine = AVAudioEngine()
            let inputFormat = engine.inputNode.outputFormat(forBus: 0)
            tapSampleRate = inputFormat.sampleRate

            let transcriber = makeRealtimeTranscriber(locale: locale)
            let converter = try await createBufferConverter(
                inputFormat: inputFormat, transcriber: transcriber
            )
            bufferConverter = converter

            let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            inputBuilder = builder

            let (sampleStream, sampleBuilder) = AsyncStream<[Float]>.makeStream()
            sampleContinuation = sampleBuilder

            let speechAnalyzer = SpeechAnalyzer(modules: [transcriber])
            analyzer = speechAnalyzer
            startAnalyzerTask(
                analyzer: speechAnalyzer,
                inputSequence: inputSequence,
                format: converter.outputFormat
            )

            startTranscriptionTask(transcriber: transcriber)
            startSampleConsumerTask(sampleStream: sampleStream)
            installAudioTap(
                on: engine.inputNode, format: inputFormat,
                analyzerBuilder: builder, converter: converter,
                sampleBuilder: sampleBuilder
            )

            engine.prepare()
            try engine.start()

            audioEngine = engine
            isRecording = true
            statusText = "録音中（リアルタイム文字起こし）"
        } catch {
            errorText = "録音開始に失敗: \(error.localizedDescription)"
            await cleanup()
        }
    }

    func stopRecording() async {
        guard isRecording else { return }
        statusText = "最終処理中..."

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        sampleContinuation?.finish()
        sampleContinuation = nil
        await sampleConsumerTask?.value
        sampleConsumerTask = nil

        inputBuilder?.finish()
        inputBuilder = nil

        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                Self.logger.error("最終処理に失敗: \(error.localizedDescription)")
                errorText = "最終処理に失敗: \(error.localizedDescription)"
            }
        }
        analyzer = nil
        await analyzerTask?.value
        analyzerTask = nil

        await transcriptionTask?.value
        transcriptionTask = nil

        bufferConverter = nil
        segments = Self.mergeAdjacent(segments: segments, gapTolerance: Self.gapTolerance)
        energyFrames = []
        isRecording = false
        deactivateAudioSession()
        statusText = "完了"
    }

    // MARK: - Setup Helpers

    private func resetState() {
        segments = []
        energyFrames = []
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true)
    }

    private func createBufferConverter(
        inputFormat: AVAudioFormat, transcriber: SpeechTranscriber
    ) async throws -> BufferConverter {
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber], considering: inputFormat
        ) else {
            throw BufferConverterError.converterCreationFailed
        }
        return try BufferConverter(inputFormat: inputFormat, outputFormat: analyzerFormat)
    }

    private func startTranscriptionTask(transcriber: SpeechTranscriber) {
        transcriptionTask = Task { [weak self] in
            Self.logger.info("文字起こし結果ストリームの監視を開始")
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    Self.logger.info(
                        "文字起こし結果受信 final=\(result.isFinal, privacy: .public) len=\(text.count, privacy: .public)"
                    )
                    self?.processTranscriberResult(result)
                }
            } catch is CancellationError {
                Self.logger.info("文字起こしタスクがキャンセルされました")
                return
            } catch {
                Self.logger.error("文字起こし結果ストリームエラー: \(error.localizedDescription)")
                self?.errorText = "文字起こしエラー: \(error.localizedDescription)"
            }
        }
    }

    private func startAnalyzerTask(
        analyzer: SpeechAnalyzer,
        inputSequence: AsyncStream<AnalyzerInput>,
        format: AVAudioFormat
    ) {
        analyzerTask = Task { [weak self] in
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: inputSequence)
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("SpeechAnalyzer起動失敗: \(error.localizedDescription)")
                self?.errorText = "SpeechAnalyzer起動失敗: \(error.localizedDescription)"
            }
        }
    }

    private func startSampleConsumerTask(sampleStream: AsyncStream<[Float]>) {
        let sampleRate = tapSampleRate
        let frameSamples = Int(sampleRate * Self.frameDuration)
        let compactThreshold = frameSamples * 4
        sampleConsumerTask = Task.detached(priority: .utility) { [weak self] in
            var accumulator: [Float] = []
            var readOffset = 0
            var totalSampleCount = 0

            for await samples in sampleStream {
                accumulator.append(contentsOf: samples)

                var newFrames: [EnergyFrame] = []
                while readOffset + frameSamples <= accumulator.count {
                    let slice = accumulator[readOffset ..< readOffset + frameSamples]
                    let energy = LiveTranscriptionService.computeEnergyFromSamples(slice)
                    let start = Double(totalSampleCount) / sampleRate
                    totalSampleCount += frameSamples
                    let end = Double(totalSampleCount) / sampleRate
                    newFrames.append(EnergyFrame(start: start, end: end, energy: energy))
                    readOffset += frameSamples
                }
                // 消費済み領域が閾値を超えたら圧縮（頻度を抑えシフト回数を削減）
                if readOffset > compactThreshold {
                    accumulator.removeSubrange(..<readOffset)
                    readOffset = 0
                }
                if !newFrames.isEmpty {
                    await self?.appendEnergyFrames(newFrames)
                }
            }

            // フレーム未満の残余サンプルをフラッシュ
            let remaining = accumulator[readOffset...]
            if !remaining.isEmpty {
                let energy = LiveTranscriptionService.computeEnergyFromSamples(remaining)
                let start = Double(totalSampleCount) / sampleRate
                let end = Double(totalSampleCount + remaining.count) / sampleRate
                await self?.appendEnergyFrames(
                    [EnergyFrame(start: start, end: end, energy: energy)]
                )
            }
        }
    }

    private func appendEnergyFrames(_ frames: [EnergyFrame]) {
        energyFrames.append(contentsOf: frames)
    }

    private nonisolated func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        analyzerBuilder: AsyncStream<AnalyzerInput>.Continuation,
        converter: BufferConverter,
        sampleBuilder: AsyncStream<[Float]>.Continuation
    ) {
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            bufferCount += 1
            do {
                let converted = try converter.convert(buffer)
                analyzerBuilder.yield(
                    self.makeAnalyzerInput(buffer: converted, bufferTime: time)
                )
                if bufferCount % 40 == 0 {
                    Self.logger.debug("オーディオ入力を供給中 count=\(bufferCount, privacy: .public)")
                }
            } catch {
                Self.logger.warning("バッファ変換失敗: \(error.localizedDescription)")
            }

            guard let floatData = buffer.floatChannelData else { return }
            let samples = Array(
                UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength))
            )
            sampleBuilder.yield(samples)
        }
    }

    private nonisolated func makeAnalyzerInput(
        buffer: AVAudioPCMBuffer,
        bufferTime: AVAudioTime
    ) -> AnalyzerInput {
        if bufferTime.isSampleTimeValid {
            let startTime = CMTime(
                value: CMTimeValue(bufferTime.sampleTime),
                timescale: CMTimeScale(buffer.format.sampleRate)
            )
            return AnalyzerInput(buffer: buffer, bufferStartTime: startTime)
        }
        return AnalyzerInput(buffer: buffer)
    }
}

// MARK: - Private Helpers

extension LiveTranscriptionService {
    // MARK: - Transcription Result Processing

    private func processTranscriberResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.isEmpty else { return }

        let startTime = result.range.start.seconds
        let endTime = result.range.end.seconds

        if segments.last?.isVolatile == true { segments.removeLast() }

        if result.isFinal {
            let speaker = Self.classifySpeaker(
                start: startTime, end: endTime, energyFrames: energyFrames
            )
            let segment = TranscriptSegment(
                start: startTime, end: endTime,
                speaker: speaker, text: text, isVolatile: false
            )

            if let last = segments.last,
               !last.isVolatile,
               last.speaker == segment.speaker,
               (segment.start - last.end) <= Self.gapTolerance
            {
                segments[segments.count - 1] = TranscriptSegment(
                    id: last.id,
                    start: last.start, end: segment.end,
                    speaker: last.speaker,
                    text: last.text + segment.text, isVolatile: false
                )
            } else {
                segments.append(segment)
            }
        } else {
            segments.append(
                TranscriptSegment(
                    start: startTime, end: endTime,
                    speaker: "...", text: text, isVolatile: true
                )
            )
        }
    }

    private func downloadModel(locale: Locale) async throws {
        statusText = "日本語モデルをダウンロード中..."
        modelProgress = "ダウンロード中..."

        let transcriber = makeRealtimeTranscriber(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }

        let progress = request.progress
        let progressTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                modelProgress = String(
                    format: "ダウンロード中... %.0f%%",
                    progress.fractionCompleted * 100
                )
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { progressTask.cancel() }
        try await request.downloadAndInstall()
    }

    private nonisolated func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private nonisolated func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func makeRealtimeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private func ensureLocaleReserved(locale: Locale) async throws {
        if let current = reservedLocale, current.identifier == locale.identifier {
            return
        }
        let reserved = try await AssetInventory.reserve(locale: locale)
        if reserved {
            reservedLocale = locale
        } else {
            throw NSError(
                domain: "LiveTranscriptionService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ロケール \(locale.identifier) を確保できませんでした。"]
            )
        }
    }

    private func cleanup() async {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        inputBuilder?.finish()
        inputBuilder = nil
        sampleContinuation?.finish()
        sampleContinuation = nil
        transcriptionTask?.cancel()
        await transcriptionTask?.value
        transcriptionTask = nil
        sampleConsumerTask?.cancel()
        await sampleConsumerTask?.value
        sampleConsumerTask = nil
        analyzerTask?.cancel()
        await analyzerTask?.value
        analyzerTask = nil
        analyzer = nil
        bufferConverter = nil
        energyFrames = []
        isRecording = false
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        } catch {
            Self.logger.warning("オーディオセッション無効化に失敗: \(error.localizedDescription)")
        }
    }
}
