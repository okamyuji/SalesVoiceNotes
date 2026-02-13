//
//  SalesVoiceNotesUITestsLaunchTests.swift
//  SalesVoiceNotesUITests
//
//  Created by okamyuji on 2025/12/12.
//

import XCTest

/// アプリの起動テスト
/// 各UIコンフィギュレーション（ライト/ダークモード、デバイスサイズなど）でテストを実行
final class SalesVoiceNotesUITestsLaunchTests: XCTestCase {
    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - 起動テスト

    @MainActor
    func testLaunch() {
        let app = XCUIApplication()
        app.launch()

        // スクリーンショットを撮影
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchWithMainViewVisible() {
        let app = XCUIApplication()
        app.launch()

        // メイン画面の要素が表示されていることを確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 5.0), "起動後にナビゲーションバーが表示される必要があります")

        // スクリーンショットを撮影
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Main View After Launch"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchWithAllButtonsVisible() {
        let app = XCUIApplication()
        app.launch()

        // 録音開始・録音終了（自動解析）ボタンが表示されていることを確認
        let recordButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音開始'")).firstMatch
        let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '録音終了'")).firstMatch
        let transcriptionButton = app.buttons.matching(NSPredicate(format: "label CONTAINS '話者分離'")).firstMatch

        XCTAssertTrue(recordButton.waitForExistence(timeout: 5.0), "録音開始ボタンが表示される必要があります")
        XCTAssertTrue(stopButton.exists, "録音終了（自動解析）ボタンが表示される必要があります")
        XCTAssertFalse(transcriptionButton.exists, "話者分離ボタンは表示されない必要があります")

        // スクリーンショットを撮影
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "All Buttons Visible"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - 画面方向テスト

    @MainActor
    func testLaunchInPortrait() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launch()

        // ポートレートモードでの表示を確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 5.0), "ポートレートモードで起動する必要があります")

        // スクリーンショットを撮影
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Portrait Orientation"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testLaunchInLandscape() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()

        // ランドスケープモードでの表示を確認
        let navBar = app.navigationBars["SalesVoiceNotes"]
        XCTAssertTrue(navBar.waitForExistence(timeout: 5.0), "ランドスケープモードで起動する必要があります")

        // スクリーンショットを撮影
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Landscape Orientation"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 元に戻す
        XCUIDevice.shared.orientation = .portrait
    }

    // MARK: - 起動パフォーマンステスト

    @MainActor
    func testLaunchPerformance() {
        // 各UIコンフィギュレーションで実行されるため、ポートレートモードのみでテスト
        // Landscape + Dark モードなど一部の組み合わせでメトリクス収集が不安定なため
        if XCUIDevice.shared.orientation.isLandscape {
            // Landscapeモードではスキップ（シミュレータの回転時にメトリクスが不安定）
            return
        }

        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
