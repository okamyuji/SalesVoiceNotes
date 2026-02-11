import SwiftUI

struct ContentView: View {
    @State private var service = LiveTranscriptionService()

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                statusSection
                recordingButton
                errorSection
                Divider().padding(.vertical, 4)
                transcriptSection
            }
            .padding()
            .navigationTitle("SalesVoiceNotes")
        }
        .task {
            await service.prepareModel()
        }
        .onDisappear {
            if service.isRecording {
                Task { await service.stopRecording() }
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("状態")
                .font(.headline)
            Text(service.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let progress = service.modelProgress {
                HStack {
                    ProgressView()
                        .padding(.trailing, 4)
                    Text(progress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    // MARK: - Recording Button

    private var recordingButton: some View {
        Button {
            Task {
                if service.isRecording {
                    await service.stopRecording()
                } else {
                    await service.startRecording()
                }
            }
        } label: {
            HStack {
                if service.isRecording {
                    Image(systemName: "stop.circle.fill")
                    Text("録音停止")
                } else {
                    Image(systemName: "mic.circle.fill")
                    Text("録音開始")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .background(service.isRecording ? Color.red : Color.blue)
        .foregroundColor(.white)
        .cornerRadius(10)
        .disabled(!service.isModelReady)
    }

    // MARK: - Error

    @ViewBuilder
    private var errorSection: some View {
        if let error = service.errorText {
            Text(error)
                .foregroundColor(.red)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        if service.segments.isEmpty {
            Spacer()
            Text("ここに結果が表示されます")
                .foregroundColor(.secondary)
            Spacer()
        } else {
            List(service.segments) { seg in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(seg.speaker)  [\(format(seg.start)) - \(format(seg.end))]")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(seg.text)
                        .font(.body)
                        .foregroundColor(seg.isVolatile ? .secondary : .primary)
                }
                .padding(.vertical, 4)
                .opacity(seg.isVolatile ? 0.6 : 1.0)
            }
        }
    }

    // MARK: - Helpers

    private func format(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = time - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }
}
