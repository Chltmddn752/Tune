import XCTest

final class MetadataSearchUITests: XCTestCase {
    func testMetadataExtensionIsSearchableAndCanBatchDownload() {
        let app = XCUIApplication()
        app.launch()

        let searchTab = app.tabBars.buttons["검색"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("newjeans")

        let picker = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '음원'")
        ).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20), app.debugDescription)
        picker.tap()

        // 정보만 주는 확장도 검색 목록에 있어야 한다.
        let spotify = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Spotify Web'")
        ).firstMatch
        XCTAssertTrue(spotify.waitForExistence(timeout: 10), app.debugDescription)

        let apple = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Apple Music'")
        ).firstMatch
        XCTAssertTrue(apple.waitForExistence(timeout: 10), app.debugDescription)
        apple.tap()

        let album = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '앨범 ·'")
        ).firstMatch
        XCTAssertTrue(album.waitForExistence(timeout: 60), app.debugDescription)
        album.tap()

        // 정보 전용 확장의 앨범도 전체 받기 버튼을 제공하고, 곡마다 찾기 버튼을 둔다.
        let downloadAll = app.buttons["앨범 전체 받기"]
        XCTAssertTrue(downloadAll.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue(app.staticTexts["정보 전용"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["다운로드 확장에서 찾기"].firstMatch.exists)

        downloadAll.tap()

        let outcome = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '대기열' OR label CONTAINS '찾지 못했'")
        ).firstMatch
        XCTAssertTrue(outcome.waitForExistence(timeout: 180), app.debugDescription)
    }
}
