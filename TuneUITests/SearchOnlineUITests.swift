import XCTest

final class SearchOnlineUITests: XCTestCase {
    func testOnlineSearchShowsCollections() {
        let app = XCUIApplication()
        app.launch()

        let searchTab = app.tabBars.buttons["검색"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("newjeans")

        let artistRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'NewJeans' AND label CONTAINS '아티스트'")
        ).firstMatch
        XCTAssertTrue(artistRow.waitForExistence(timeout: 60), app.debugDescription)
        artistRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let downloadAll = app.buttons["모든 앨범 받기"]
        XCTAssertTrue(downloadAll.waitForExistence(timeout: 120), app.debugDescription)
        downloadAll.tap()
        let confirm = app.alerts["모든 앨범을 받을까요?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        confirm.buttons["취소"].tap()

        let albumCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'NewJeans' AND NOT label CONTAINS '아티스트' AND NOT label CONTAINS '받기'")
        ).firstMatch
        XCTAssertTrue(albumCard.waitForExistence(timeout: 30), app.debugDescription)
        albumCard.tap()

        XCTAssertTrue(
            app.buttons["앨범 전체 받기"].waitForExistence(timeout: 90),
            app.debugDescription
        )
    }

    func testOnlineSearchShowsPlaylists() {
        let app = XCUIApplication()
        app.launch()

        let searchTab = app.tabBars.buttons["검색"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("newjeans")

        let playlistRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '플레이리스트 ·'")
        ).firstMatch

        // "상위 결과"는 아티스트·앨범 다음에 플레이리스트가 나오므로 아래로 내려 찾는다.
        for _ in 0..<8 where !playlistRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 90), app.debugDescription)
        playlistRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["플레이리스트 전체 받기"].waitForExistence(timeout: 120),
            app.debugDescription
        )
    }

    func testAppleMusicSearchShowsPlaylists() {
        let app = XCUIApplication()
        app.launch()

        let searchTab = app.tabBars.buttons["검색"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10))
        searchTab.tap()

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("kpop")

        let providerButton = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '음원'")
        ).firstMatch
        XCTAssertTrue(providerButton.waitForExistence(timeout: 60), app.debugDescription)
        providerButton.tap()
        let appleMusic = app.buttons["Apple Music · 정보"].firstMatch
        XCTAssertTrue(appleMusic.waitForExistence(timeout: 15), app.debugDescription)
        appleMusic.tap()

        let playlistRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '플레이리스트 ·'")
        ).firstMatch
        for _ in 0..<8 where !playlistRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(playlistRow.waitForExistence(timeout: 120), app.debugDescription)
        playlistRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(
            app.buttons["플레이리스트 전체 받기"].waitForExistence(timeout: 120),
            app.debugDescription
        )
        XCTAssertTrue(
            app.staticTexts["다른 확장에서 같은 곡을 찾아 받아요"].waitForExistence(timeout: 10),
            app.debugDescription
        )
    }
}
