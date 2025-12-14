# SalesVoiceNotes

営業向けのボイスメモアプリです。話者分離と文字起こし機能を備え、オフラインでの音声認識に対応しています。

## 概要

SalesVoiceNotesは、営業活動中の会話を録音し、話者を自動的に識別しながら文字起こしを行うiOSアプリです。オンデバイスの音声認識エンジンを使用しているため、インターネット接続がなくても動作します。

## 主な機能

- リアルタイム録音と音声レベルの可視化
- 話者分離による複数人の会話の識別
- 日本語音声認識による文字起こし
- オフライン対応のオンデバイス音声認識
- バックグラウンド録音対応
- 画面ロック中も録音を継続
- カスタム語彙による認識精度の向上

## 動作要件

- iOS 16.0以上
- iPhone または iPad

## アーキテクチャ

### ファイル構成

| ファイル名 | 役割 |
|-----------|------|
| SalesVoiceNotesApp.swift | アプリのエントリーポイントとAppDelegate |
| ContentView.swift | メイン画面のUI |
| Recorder.swift | 録音機能を管理するクラス |
| AudioProcessingService.swift | 音声処理サービス（話者分離、文字起こし） |
| TranscriptSegment.swift | 文字起こし結果を表すモデル |
| VocabularyLoader.swift | カスタム語彙の読み込み |
| vocabulary.json | カスタム語彙データ |

### 技術スタック

- SwiftUI: UIフレームワーク
- AVFoundation: 音声録音
- Speech Framework: 音声認識（SFSpeechRecognizer）
- SwiftData: データ永続化

## 話者分離アルゴリズム

このアプリでは、以下の手法を組み合わせて話者分離を実現しています。

1. 音声特徴量の抽出
   - RMSエネルギー
   - ゼロ交差率

2. 発話区間の検出（VAD: Voice Activity Detection）
   - 適応的閾値を使用したエネルギーベースの検出
   - ヒステリシスによる安定した検出

3. 話者クラスタリング
   - 音声特徴量に基づくK-means風クラスタリング
   - 発話間の無音区間と特徴量変化による話者変更点の検出

## カスタム語彙

`vocabulary.json` ファイルにカスタム語彙を追加することで、音声認識の精度を向上させることができます。語彙は以下のカテゴリに分類されています。

- sales: 営業関連の用語
- technology: 技術関連の用語
- business: ビジネス一般の用語
- products: 製品・サービス関連の用語

## ビルド方法

1. Xcode 15.0以上をインストールしてください
2. プロジェクトをクローンします
3. `SalesVoiceNotes.xcodeproj` を開きます
4. ターゲットデバイスを選択してビルドします

## 権限設定

このアプリでは以下の権限が必要です。Info.plistに設定済みです。

- マイク使用権限（NSMicrophoneUsageDescription）
- 音声認識権限（NSSpeechRecognitionUsageDescription）
- バックグラウンドオーディオ（UIBackgroundModes）

## 使い方

1. アプリを起動します
2. 「録音開始」ボタンをタップして録音を開始します
3. 録音中は音声レベルメーターと波形アニメーションが表示されます
4. 「録音停止」ボタンをタップして録音を停止します
5. 「話者分離 + 文字起こし」ボタンをタップして解析を開始します
6. 解析結果が話者ごとに色分けされて表示されます

## テスト

### ユニットテスト

```bash
xcodebuild test -project SalesVoiceNotes.xcodeproj -scheme SalesVoiceNotes -destination 'platform=iOS Simulator,name=iPhone 16'
```

### UIテスト

```bash
xcodebuild test -project SalesVoiceNotes.xcodeproj -scheme SalesVoiceNotes -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:SalesVoiceNotesUITests
```

## ライセンス

MIT
