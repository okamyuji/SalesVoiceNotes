import SwiftUI
import Speech

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @State private var segments: [TranscriptSegment] = []
    @State private var isProcessing: Bool = false
    @State private var errorText: String? = nil

    private let processor = AudioProcessingService()

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {

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

                HStack(spacing: 12) {
                    Button {
                        Task { await recorder.startRecording() }
                    } label: {
                        Text("録音開始")
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
                        Text("録音停止")
                            .frame(maxWidth: .infinity)
                            .padding()
                    }
                    .background(recorder.isRecording ? Color.red : Color.gray)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .disabled(!recorder.isRecording)
                }

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

                Divider().padding(.vertical, 4)

                if segments.isEmpty {
                    Spacer()
                    Text("ここに結果が表示されます")
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List(segments) { seg in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(seg.speaker)  [\(format(seg.start)) - \(format(seg.end))]")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(seg.text)
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding()
            .navigationTitle("SalesVoiceNotes")
        }
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
}
