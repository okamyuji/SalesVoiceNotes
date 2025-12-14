import Foundation
import AVFoundation
import Combine

#if os(iOS)
import UIKit

/// 録音機能を提供するクラス
/// - 音声レベルのリアルタイム監視機能付き
/// - バックグラウンド録音対応
/// - 画面ロック時も録音継続
@MainActor
final class Recorder: NSObject, ObservableObject {
    // MARK: - Published Properties
    
    /// 録音中かどうか
    @Published var isRecording: Bool = false
    /// 最後に保存した録音ファイルのURL
    @Published var lastSavedURL: URL? = nil
    /// ステータステキスト
    @Published var statusText: String = "待機中"
    /// 現在の音声レベル（0.0〜1.0）- UIでメーター表示用
    @Published var audioLevel: Float = 0.0
    /// 録音時間（秒）
    @Published var recordingDuration: TimeInterval = 0.0
    /// 録音準備完了
    @Published var isReady: Bool = false
    
    // MARK: - Private Properties
    
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var startTime: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        
        // 初期化時に録音の準備を開始
        Task {
            await prepareForRecording()
        }
        
        // バックグラウンド移行の通知を監視
        setupNotifications()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Notifications
    
    private func setupNotifications() {
        // アプリがバックグラウンドに移行する際の通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        
        // アプリがフォアグラウンドに戻る際の通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        
        // オーディオセッションの中断通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }
    
    @objc private func handleAppDidEnterBackground() {
        if isRecording {
            // バックグラウンドタスクを開始して録音を継続
            beginBackgroundTask()
        }
    }
    
    @objc private func handleAppWillEnterForeground() {
        // バックグラウンドタスクを終了
        endBackgroundTask()
        
        // 録音が継続しているか確認
        if isRecording {
            if let recorder = recorder, !recorder.isRecording {
                // 録音が停止していた場合は再開を試みる
                recorder.record()
            }
        }
    }
    
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }
        
        switch type {
        case .began:
            // 電話着信などで中断された - 録音は自動的に一時停止される
            break
            
        case .ended:
            // 中断が終了した
            // 中断オプションを確認
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) && isRecording {
                    // 録音を再開
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        recorder?.record()
                    } catch {
                        // エラーは無視
                    }
                }
            }
            
        @unknown default:
            break
        }
    }
    
    // MARK: - Background Task
    
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Recording") { [weak self] in
            // タイムアウト時のクリーンアップ
            self?.endBackgroundTask()
        }
    }
    
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
    
    // MARK: - Permission
    
    /// マイク権限をリクエスト
    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }
    
    // MARK: - Pre-warming
    
    /// 録音の事前準備（アプリ起動時に呼ばれる）
    /// AppDelegateでAVAudioRecorderのウォームアップが行われるため、
    /// ここではマイク権限の確認のみを行う
    func prepareForRecording() async {
        let granted = await requestMicPermission()
        
        guard granted else {
            statusText = "マイク権限がありません（設定アプリで許可してください）"
            return
        }
        
        // AppDelegateでウォームアップが完了するのを待つ必要はない
        // 権限があれば即座に録音準備完了とする
        isReady = true
        statusText = "録音準備完了"
    }
    
    // MARK: - Recording Control
    
    /// 録音を開始
    func startRecording() async {
        if isRecording { return }

        // まず録音中フラグを立てて、連続タップを防ぐ
        isRecording = true
        statusText = "録音準備中..."

        let granted = await requestMicPermission()
        
        guard granted else {
            statusText = "マイク権限がありません（設定アプリで許可してください）"
            isRecording = false
            return
        }

        // 重い処理をバックグラウンドで実行
        let (recorderResult, errorMsg) = await Task.detached(priority: .userInitiated) { () -> (AVAudioRecorder?, String?) in
            do {
                // AudioSessionをバックグラウンド録音用に設定
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
                )
                try session.setActive(true)

                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let filename = "record_\(Int(Date().timeIntervalSince1970)).wav"
                let url = docs.appendingPathComponent(filename)
                
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 48000.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsFloatKey: false
                ]

                let newRecorder = try AVAudioRecorder(url: url, settings: settings)
                newRecorder.isMeteringEnabled = true
                newRecorder.prepareToRecord()
                
                return (newRecorder, nil)
            } catch {
                return (nil, error.localizedDescription)
            }
        }.value
        
        guard let newRecorder = recorderResult else {
            statusText = "録音開始に失敗: \(errorMsg ?? "unknown")"
            isRecording = false
            return
        }
        
        recorder = newRecorder
        recorder?.delegate = self
        lastSavedURL = newRecorder.url
        
        recorder?.record()
        
        startTime = Date()
        let filename = newRecorder.url.lastPathComponent
        statusText = "録音中: \(filename)"
        
        // 録音中は画面ロックを防止
        UIApplication.shared.isIdleTimerDisabled = true
        
        startLevelMonitoring()
    }
    
    /// 録音を停止
    func stopRecording() {
        guard isRecording else { return }
        
        stopLevelMonitoring()
        endBackgroundTask()
        
        recorder?.stop()
        recorder = nil
        isRecording = false
        audioLevel = 0.0
        recordingDuration = 0.0
        startTime = nil
        
        // 画面ロック防止を解除
        UIApplication.shared.isIdleTimerDisabled = false
        
        // AudioSessionを非アクティブにして次回の録音に備える
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // エラーは無視
        }

        if let url = lastSavedURL {
            statusText = "録音停止: \(url.lastPathComponent)"
        } else {
            statusText = "録音停止"
        }
    }
    
    // MARK: - Level Monitoring
    
    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor [weak self] in
                self?.updateLevels()
            }
        }
        
        // バックグラウンドでもタイマーが動作するようにRunLoopに追加
        if let timer = levelTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }
    
    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }
    
    private func updateLevels() {
        guard let recorder = recorder, recorder.isRecording else { return }
        
        recorder.updateMeters()
        
        let averagePower = recorder.averagePower(forChannel: 0)
        
        let minDb: Float = -60.0
        let normalizedLevel: Float
        if averagePower < minDb {
            normalizedLevel = 0.0
        } else {
            normalizedLevel = (averagePower - minDb) / (-minDb)
        }
        
        audioLevel = audioLevel * 0.3 + normalizedLevel * 0.7
        
        if let startTime = startTime {
            recordingDuration = Date().timeIntervalSince(startTime)
        }
    }
}

// MARK: - AVAudioRecorderDelegate

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                self.statusText = "録音が予期せず終了しました"
            }
        }
    }
    
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if let error = error {
                self.statusText = "録音エラー: \(error.localizedDescription)"
            }
        }
    }
}
#endif
