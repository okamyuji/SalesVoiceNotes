import AVFoundation
import Observation
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
    private var transcriptionTask: Task<Void, Never>?
    private var sampleConsumerTask: Task<Void, Never>?
    private var energyFrames: [EnergyFrame] = []

    private var sampleAccumulator: [Float] = []
    private var accumulatedSampleCount: Int = 0
    private var tapSampleRate: Double = 16000

    // MARK: - Constants

    private static let frameDuration: Double = 0.25
    private static let gapTolerance: TimeInterval = 0.6

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

            let transcriber = SpeechTranscriber(
                locale: Locale(identifier: "ja-JP"),
                preset: .timeIndexedProgressiveTranscription
            )
            let converter = try await createBufferConverter(
                inputFormat: inputFormat, transcriber: transcriber
            )
            bufferConverter = converter

            let (inputSequence, builder) = AsyncStream<AnalyzerInput>.makeStream()
            inputBuilder = builder

            let (sampleStream, sampleBuilder) = AsyncStream<[Float]>.makeStream()
            sampleContinuation = sampleBuilder

            analyzer = SpeechAnalyzer(
                inputSequence: inputSequence, modules: [transcriber]
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

        flushAccumulator()

        inputBuilder?.finish()
        inputBuilder = nil

        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil

        await transcriptionTask?.value
        transcriptionTask = nil

        bufferConverter = nil
        isRecording = false
        statusText = "完了"
    }

    // MARK: - Setup Helpers

    private func resetState() {
        segments = []
        energyFrames = []
        sampleAccumulator = []
        accumulatedSampleCount = 0
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
            do {
                for try await result in transcriber.results {
                    self?.processTranscriberResult(result)
                }
            } catch {
                self?.errorText = "文字起こしエラー: \(error.localizedDescription)"
            }
        }
    }

    private func startSampleConsumerTask(sampleStream: AsyncStream<[Float]>) {
        let sampleRate = tapSampleRate
        let frameSamples = Int(sampleRate * Self.frameDuration)
        sampleConsumerTask = Task { [weak self] in
            for await samples in sampleStream {
                self?.accumulateSamples(
                    samples, sampleRate: sampleRate, frameSamples: frameSamples
                )
            }
        }
    }

    private func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        analyzerBuilder: AsyncStream<AnalyzerInput>.Continuation,
        converter: BufferConverter,
        sampleBuilder: AsyncStream<[Float]>.Continuation
    ) {
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let converted = try? converter.convert(buffer) {
                analyzerBuilder.yield(AnalyzerInput(buffer: converted))
            }

            guard let floatData = buffer.floatChannelData else { return }
            let samples = Array(
                UnsafeBufferPointer(start: floatData[0], count: Int(buffer.frameLength))
            )
            sampleBuilder.yield(samples)
        }
    }

    // MARK: - Transcription Result Processing

    private func processTranscriberResult(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters)
        guard !text.isEmpty else { return }

        let startTime = result.range.start.seconds
        let endTime = result.range.end.seconds

        if result.isFinal {
            segments.removeAll { $0.isVolatile }

            let speaker = Self.classifySpeaker(
                start: startTime, end: endTime, energyFrames: energyFrames
            )
            let segment = TranscriptSegment(
                start: startTime, end: endTime,
                speaker: speaker, text: text, isVolatile: false
            )

            segments = Self.mergeAdjacent(
                segments: segments + [segment], gapTolerance: Self.gapTolerance
            )
        } else {
            segments.removeAll { $0.isVolatile }
            segments.append(
                TranscriptSegment(
                    start: startTime, end: endTime,
                    speaker: "...", text: text, isVolatile: true
                )
            )
        }
    }
}

// MARK: - Private Helpers

extension LiveTranscriptionService {
    private func downloadModel(locale: Locale) async throws {
        statusText = "日本語モデルをダウンロード中..."
        modelProgress = "ダウンロード中..."

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) else { return }

        let progress = request.progress
        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.modelProgress = String(
                    format: "ダウンロード中... %.0f%%",
                    progress.fractionCompleted * 100
                )
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        try await request.downloadAndInstall()
        progressTask.cancel()
    }

    private func accumulateSamples(
        _ samples: [Float], sampleRate: Double, frameSamples: Int
    ) {
        sampleAccumulator.append(contentsOf: samples)

        while sampleAccumulator.count >= frameSamples {
            let slice = Array(sampleAccumulator.prefix(frameSamples))
            sampleAccumulator.removeFirst(frameSamples)

            let energy = Self.computeEnergyFromSamples(slice)
            let frameIndex = accumulatedSampleCount
            accumulatedSampleCount += frameSamples

            let start = Double(frameIndex) / sampleRate
            let end = Double(frameIndex + frameSamples) / sampleRate
            energyFrames.append(EnergyFrame(start: start, end: end, energy: energy))
        }
    }

    private func flushAccumulator() {
        guard !sampleAccumulator.isEmpty else { return }
        let energy = Self.computeEnergyFromSamples(sampleAccumulator)
        let frameIndex = accumulatedSampleCount
        let count = sampleAccumulator.count
        accumulatedSampleCount += count

        let start = Double(frameIndex) / tapSampleRate
        let end = Double(frameIndex + count) / tapSampleRate
        energyFrames.append(EnergyFrame(start: start, end: end, energy: energy))
        sampleAccumulator.removeAll()
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
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
        analyzer = nil
        bufferConverter = nil
        isRecording = false
    }
}
