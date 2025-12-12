import Foundation
import AVFoundation
import Combine

@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published var isRecording: Bool = false
    @Published var lastSavedURL: URL? = nil
    @Published var statusText: String = "待機中"

    private var recorder: AVAudioRecorder?

    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    func startRecording() async {
        if isRecording { return }

        let granted = await requestMicPermission()
        guard granted else {
            statusText = "マイク権限がありません（設定アプリで許可してください）"
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .spokenAudio, options: [])
            try session.setActive(true)

            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let filename = "record_\(Int(Date().timeIntervalSince1970)).wav"
            let url = docs.appendingPathComponent(filename)
            lastSavedURL = url

            // 16kHz / mono / 16bit PCM WAV
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false
            ]

            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.prepareToRecord()
            recorder?.record()

            isRecording = true
            statusText = "録音中: \(filename)"
        } catch {
            statusText = "録音開始に失敗: \(error.localizedDescription)"
            isRecording = false
            recorder = nil
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        recorder?.stop()
        recorder = nil
        isRecording = false

        if let url = lastSavedURL {
            statusText = "録音停止: \(url.lastPathComponent)"
        } else {
            statusText = "録音停止"
        }
    }
}
