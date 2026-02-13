import AVFoundation
import SwiftUI

#if os(iOS)
    import UIKit

    /// アプリ起動時にAudioSessionを事前設定するためのAppDelegate
    /// バックグラウンド録音対応 + AVAudioRecorder事前初期化
    final class AppDelegate: NSObject, UIApplicationDelegate {
        /// 事前初期化用のダミーレコーダー（初期化コストを事前に支払う）
        private var warmupRecorder: AVAudioRecorder?

        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            // アプリ起動時にAudioSessionを事前設定（録音開始を高速化 + バックグラウンド対応）
            setupAudioSession()

            // バックグラウンドでAVAudioRecorderを事前初期化（UIをブロックしない）
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.performWarmupRecording()
            }

            return true
        }

        /// AudioSessionをバックグラウンド録音用に設定
        private func setupAudioSession() {
            do {
                let session = AVAudioSession.sharedInstance()

                // .playAndRecord カテゴリを使用（バックグラウンド録音に必須）
                // mode: .voiceChat - 音声通話/録音に最適化
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
                )

                // セッションをアクティブ化
                try session.setActive(true)
            } catch {
                // エラーは無視
            }
        }

        /// ダミー録音を実行してAVAudioRecorderを事前初期化
        /// これにより初回の録音開始時の遅延を解消
        private func performWarmupRecording() {
            let tempDir = FileManager.default.temporaryDirectory
            let warmupURL = tempDir.appendingPathComponent("warmup_\(UUID().uuidString).wav")

            // 実際の録音と同じ設定を使用
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsFloatKey: false,
            ]

            do {
                // AVAudioRecorderを作成（ここで初期化コストが発生）
                warmupRecorder = try AVAudioRecorder(url: warmupURL, settings: settings)

                // prepareToRecordを呼び出してさらに初期化
                warmupRecorder?.prepareToRecord()

                // 実際に録音を開始して停止（オーディオハードウェアを完全に初期化）
                warmupRecorder?.record()

                // 少し待ってから停止
                Thread.sleep(forTimeInterval: 0.1)

                warmupRecorder?.stop()
                warmupRecorder = nil

                // ダミーファイルを削除
                try? FileManager.default.removeItem(at: warmupURL)
            } catch {
                // エラーは無視
            }
        }

        // MARK: - App Lifecycle for Background Recording

        func applicationDidEnterBackground(_: UIApplication) {
            // バックグラウンドに移行
        }

        func applicationWillEnterForeground(_: UIApplication) {
            ensureAudioSessionActive()
        }

        private func ensureAudioSessionActive() {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setActive(true)
            } catch {
                // エラーは無視
            }
        }
    }
#endif

@main
struct SalesVoiceNotesApp: App {
    #if os(iOS)
        @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            #if os(iOS)
                ContentView()
            #else
                Text("This app is iOS only")
            #endif
        }
    }
}
