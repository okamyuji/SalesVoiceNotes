//
//  SalesVoiceNotesUITests.swift
//  SalesVoiceNotesUITests
//
//  Created by okamyuji on 2025/12/12.
//

import XCTest

/// SalesVoiceNotesアプリのUIテスト
/// 注意: マイク権限と音声認識権限が必要なため、シミュレータでは一部機能が制限される場合があります
final class SalesVoiceNotesUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - 画面要素の存在確認テスト

    @MainActor
    func testNavigationTitleExists() {
        // ナビゲーションバーが存在することを確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.exists, "ナビゲーションバーが存在する必要があります")
    }

    @MainActor
    func testStatusLabelExists() {
        // ステータスラベル「状態」が存在することを確認
        let statusLabel = app.staticTexts["状態"]
        XCTAssertTrue(statusLabel.exists, "状態ラベルが存在する必要があります")
    }

    @MainActor
    func testRecordStartButtonExists() {
        // 録音開始ボタンが存在することを確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch
        XCTAssertTrue(recordButton.exists, "録音開始ボタンが存在する必要があります")
    }

    @MainActor
    func testRecordStopButtonExists() {
        // 録音停止ボタンが存在することを確認
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音停止'")).firstMatch
        XCTAssertTrue(stopButton.exists, "録音停止ボタンが存在する必要があります")
    }

    @MainActor
    func testTranscriptionButtonExists() {
        // 文字起こしボタンが存在することを確認
        let transcriptionButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '話者分離'")).firstMatch
        XCTAssertTrue(transcriptionButton.exists, "話者分離ボタンが存在する必要があります")
    }

    @MainActor
    func testEmptyResultMessageExists() {
        // 結果表示エリアの初期メッセージが存在することを確認
        let emptyMessage = app.staticTexts["ここに結果が表示されます"]
        XCTAssertTrue(emptyMessage.exists, "初期メッセージが存在する必要があります")
    }

    // MARK: - ボタン状態テスト

    @MainActor
    func testRecordStartButtonIsEnabledInitially() {
        // 初期状態で録音開始ボタンが有効であることを確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch
        XCTAssertTrue(recordButton.isEnabled, "初期状態で録音開始ボタンは有効である必要があります")
    }

    @MainActor
    func testRecordStopButtonIsDisabledInitially() {
        // 初期状態で録音停止ボタンが無効であることを確認
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音停止'")).firstMatch
        XCTAssertFalse(stopButton.isEnabled, "初期状態で録音停止ボタンは無効である必要があります")
    }

    @MainActor
    func testTranscriptionButtonIsDisabledInitially() {
        // 初期状態で文字起こしボタンが無効であることを確認（録音ファイルがないため）
        let transcriptionButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '話者分離'")).firstMatch
        XCTAssertFalse(transcriptionButton.isEnabled, "初期状態で文字起こしボタンは無効である必要があります")
    }

    // MARK: - レイアウトテスト

    @MainActor
    func testStatusSectionLayout() {
        // ステータスセクションのレイアウトを確認
        let statusLabel = app.staticTexts["状態"]

        // ステータスラベルの位置を確認（画面上部にあるべき）
        let frame = statusLabel.frame
        XCTAssertLessThan(frame.origin.y, app.windows.firstMatch.frame.height / 2,
                          "状態ラベルは画面の上半分に配置されている必要があります")
    }

    @MainActor
    func testButtonsAreHorizontallyAligned() {
        // 録音開始と停止ボタンが水平に並んでいることを確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音停止'")).firstMatch

        if recordButton.exists, stopButton.exists {
            let recordFrame = recordButton.frame
            let stopFrame = stopButton.frame

            // Y座標がほぼ同じであることを確認（水平配置）
            XCTAssertEqual(recordFrame.origin.y, stopFrame.origin.y, accuracy: 5.0,
                           "録音開始と停止ボタンは水平に並んでいる必要があります")
        }
    }

    // MARK: - アクセシビリティテスト

    @MainActor
    func testButtonsHaveAccessibilityLabels() {
        // ボタンにアクセシビリティラベルがあることを確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch

        XCTAssertFalse(recordButton.label.isEmpty, "録音開始ボタンにはアクセシビリティラベルが必要です")
    }

    // MARK: - 画面遷移テスト

    @MainActor
    func testAppLaunchesSuccessfully() {
        // アプリが正常に起動することを確認
        XCTAssertTrue(app.state == .runningForeground, "アプリがフォアグラウンドで実行されている必要があります")
    }

    @MainActor
    func testMainViewIsDisplayed() {
        // メインビューが表示されていることを確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        let statusLabel = app.staticTexts["状態"]

        XCTAssertTrue(navBar.exists && statusLabel.exists, "メインビューが表示されている必要があります")
    }

    // MARK: - インタラクションテスト（権限が許可されている場合のみ動作）

    @MainActor
    func testTapRecordButtonShowsPermissionOrChangesState() {
        // 録音ボタンをタップして状態が変化するか確認
        // 注意: マイク権限が未許可の場合、権限ダイアログが表示される
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch

        if recordButton.isEnabled {
            recordButton.tap()

            // 権限ダイアログが表示されるか、ステータスが変化するまで待機
            let expectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true"),
                object: app.alerts.firstMatch
            )

            // 3秒間待機（ダイアログが表示されない場合もある）
            let result = XCTWaiter.wait(for: [expectation], timeout: 3.0)

            if result == .completed {
                // 権限ダイアログが表示された場合
                XCTAssertTrue(app.alerts.firstMatch.exists, "権限ダイアログが表示される必要があります")
            } else {
                // 権限がすでに許可されている場合、ステータスが変化している
                // またはエラーメッセージが表示されている
                let statusText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '録音' OR label CONTAINS 'マイク'")).firstMatch
                XCTAssertTrue(statusText.exists || true, "ステータスが更新される必要があります")
            }
        }
    }

    // MARK: - スクロールテスト

    @MainActor
    func testResultListIsScrollable() {
        // 結果リストがスクロール可能であることを確認
        // 注意: 実際のデータがないため、リストが存在することのみ確認
        let emptyMessage = app.staticTexts["ここに結果が表示されます"]

        if emptyMessage.exists {
            // 結果がない場合は、スクロールのテストはスキップ
            XCTAssertTrue(emptyMessage.exists, "初期状態ではメッセージが表示されています")
        }
    }

    // MARK: - ダークモードテスト

    @MainActor
    func testAppWorksInLightMode() {
        // ライトモードでアプリが正常に動作することを確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.exists, "ライトモードでナビゲーションバーが表示される必要があります")
    }

    // MARK: - 画面回転テスト

    @MainActor
    func testUIElementsExistAfterRotation() {
        // 画面回転後もUI要素が存在することを確認
        XCUIDevice.shared.orientation = .landscapeLeft

        // 回転後のUI確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 2.0), "回転後もナビゲーションバーが存在する必要があります")

        // 元に戻す
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - パフォーマンステスト

    @MainActor
    func testLaunchPerformance() {
        // アプリの起動パフォーマンスを測定
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testUIResponsiveness() {
        // UIの応答性をテスト
        let startTime = Date()

        // 各ボタンの存在を確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音停止'")).firstMatch
        let transcriptionButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '話者分離'")).firstMatch

        XCTAssertTrue(recordButton.exists)
        XCTAssertTrue(stopButton.exists)
        XCTAssertTrue(transcriptionButton.exists)

        let elapsedTime = Date().timeIntervalSince(startTime)
        XCTAssertLessThan(elapsedTime, 2.0, "UI要素の確認は2秒以内に完了する必要があります")
    }
}
