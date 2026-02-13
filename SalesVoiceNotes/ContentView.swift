import Speech
import SwiftUI

#if os(iOS)
    struct ContentView: View {
        @StateObject private var recorder = Recorder()
        @State private var segments: [TranscriptSegment] = []
        @State private var isProcessing: Bool = false
        @State private var errorText: String? = nil

        private let processor = AudioProcessingService()

        var body: some View {
            NavigationView {
                VStack(spacing: 0) {
                    // MARK: - 固定ヘッダー部分（スクロールしない）

                    VStack(spacing: 14) {
                        // MARK: - ステータス表示

                        VStack(alignment: .leading, spacing: 6) {
                            Text("状態")
                                .font(.headline)
                            Text(recorder.statusText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)

                            if let url = recorder.lastSavedURL {
                                Text("保存先: \(url.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)

                        // MARK: - 録音中の音声レベルメーター

                        if recorder.isRecording {
                            VStack(spacing: 8) {
                                // 録音時間表示
                                Text(formatDuration(recorder.recordingDuration))
                                    .font(.system(size: 32, weight: .medium, design: .monospaced))
                                    .foregroundColor(.red)

                                // 音声レベルバー
                                AudioLevelMeterView(level: recorder.audioLevel)
                                    .frame(height: 24)

                                // 波形アニメーション
                                WaveformAnimationView(level: recorder.audioLevel)
                                    .frame(height: 60)
                            }
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.red.opacity(0.1))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                                    )
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        // MARK: - 録音ボタン

                        HStack(spacing: 12) {
                            Button {
                                Task { await recorder.startRecording() }
                            } label: {
                                HStack {
                                    Image(systemName: "mic.fill")
                                    Text("録音開始")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                            .background(recorder.isRecording ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(recorder.isRecording)

                            Button {
                                recorder.stopRecording()
                            } label: {
                                HStack {
                                    Image(systemName: "stop.fill")
                                    Text("録音停止")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }
                            .background(recorder.isRecording ? Color.red : Color.gray)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                            .disabled(!recorder.isRecording)
                        }

                        // MARK: - 文字起こしボタン

                        Button {
                            Task { await runProcessing() }
                        } label: {
                            HStack {
                                if isProcessing { ProgressView().padding(.trailing, 6) }
                                Text(isProcessing ? "解析中..." : "話者分離 + 文字起こし（オフライン）")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                        }
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .disabled(isProcessing || recorder.isRecording || recorder.lastSavedURL == nil)

                        if let errorText {
                            Text(errorText)
                                .foregroundColor(.red)
                                .font(.footnote)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }
                    }
                    .padding()

                    Divider()

                    // MARK: - 結果表示（スクロール可能）

                    if segments.isEmpty {
                        Spacer()
                        Text("ここに結果が表示されます")
                            .foregroundColor(.secondary)
                        Spacer()
                    } else {
                        List(segments) { seg in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    // 話者アイコン（複数話者対応）
                                    Image(systemName: speakerIcon(for: seg.speaker))
                                        .foregroundColor(speakerColor(for: seg.speaker))

                                    Text(seg.speaker)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(speakerColor(for: seg.speaker))

                                    Spacer()

                                    Text("[\(format(seg.start)) - \(format(seg.end))]")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(seg.text)
                                    .font(.body)
                            }
                            .padding(.vertical, 4)
                        }
                        .listStyle(.plain)
                    }
                }
                .navigationTitle("SalesVoiceNotes")
                .navigationBarTitleDisplayMode(.inline)
                .animation(.easeInOut(duration: 0.3), value: recorder.isRecording)
            }
            .navigationViewStyle(.stack)
        }

        private func runProcessing() async {
            errorText = nil
            segments = []
            guard let url = recorder.lastSavedURL else {
                errorText = "録音ファイルがありません。"
                return
            }

            isProcessing = true
            do {
                let result = try await processor.process(url: url)
                segments = result
            } catch {
                errorText = error.localizedDescription
            }
            isProcessing = false
        }

        private func format(_ t: TimeInterval) -> String {
            let m = Int(t) / 60
            let s = t - Double(m * 60)
            return String(format: "%02d:%04.1f", m, s)
        }

        private func formatDuration(_ t: TimeInterval) -> String {
            let m = Int(t) / 60
            let s = Int(t) % 60
            return String(format: "%02d:%02d", m, s)
        }

        /// 話者ラベルに対応するアイコンを返す
        private func speakerIcon(for speaker: String) -> String {
            // 話者番号を抽出して対応するアイコンを返す
            if speaker.contains("1") {
                return "person.fill"
            } else if speaker.contains("2") {
                return "person"
            } else if speaker.contains("3") {
                return "person.2.fill"
            } else if speaker.contains("4") {
                return "person.2"
            } else if speaker.contains("5") {
                return "person.3.fill"
            } else if speaker.contains("6") {
                return "person.3"
            } else {
                return "person.crop.circle"
            }
        }

        /// 話者ラベルに対応する色を返す
        private func speakerColor(for speaker: String) -> Color {
            // 話者番号を抽出して対応する色を返す
            let colors: [Color] = [
                .blue, // 話者1
                .orange, // 話者2
                .green, // 話者3
                .purple, // 話者4
                .pink, // 話者5
                .teal, // 話者6
                .indigo, // 話者7
                .mint, // 話者8
            ]

            // 話者番号を抽出
            if let match = speaker.firstMatch(of: /\d+/), let num = Int(match.output) {
                let index = (num - 1) % colors.count
                return colors[index]
            }
            return .gray
        }
    }

    // MARK: - 音声レベルメータービュー

    /// 横棒グラフ形式の音声レベルメーター
    struct AudioLevelMeterView: View {
        let level: Float

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))

                    // レベルバー（グラデーション）
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: levelColors),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * CGFloat(level))
                        .animation(.linear(duration: 0.05), value: level)
                }
            }
        }

        /// レベルに応じたグラデーションカラー
        private var levelColors: [Color] {
            if level > 0.8 {
                return [.green, .yellow, .red]
            } else if level > 0.5 {
                return [.green, .yellow]
            } else {
                return [.green]
            }
        }
    }

    // MARK: - 波形アニメーションビュー

    /// 録音中を示す波形アニメーション
    struct WaveformAnimationView: View {
        let level: Float

        private let barCount = 20

        var body: some View {
            HStack(spacing: 3) {
                ForEach(0 ..< barCount, id: \.self) { index in
                    WaveformBar(
                        level: level,
                        index: index,
                        totalBars: barCount
                    )
                }
            }
        }
    }

    /// 個別の波形バー
    struct WaveformBar: View {
        let level: Float
        let index: Int
        let totalBars: Int

        @State private var animatedHeight: CGFloat = 0.2

        var body: some View {
            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 8)
                .frame(height: max(4, animatedHeight * 50))
                .animation(
                    .easeInOut(duration: 0.1 + Double(index % 5) * 0.02),
                    value: animatedHeight
                )
                .onChange(of: level) { _, newLevel in
                    // ランダム性を加えてより自然な波形に
                    let randomFactor = Float.random(in: 0.7 ... 1.3)
                    let centerDistance = abs(Float(index) - Float(totalBars) / 2) / Float(totalBars) * 2
                    let heightFactor = (1.0 - centerDistance * 0.5) * newLevel * randomFactor
                    animatedHeight = CGFloat(max(0.1, min(1.0, heightFactor)))
                }
        }

        private var barColor: Color {
            let normalizedIndex = Float(index) / Float(totalBars)
            if normalizedIndex < 0.3 {
                return .green
            } else if normalizedIndex < 0.7 {
                return .yellow
            } else {
                return .red
            }
        }
    }
#endif
