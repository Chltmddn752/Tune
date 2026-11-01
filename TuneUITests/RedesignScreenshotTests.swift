import XCTest

/// 리디자인된 화면을 훑으며 스크린샷을 남긴다. 기능 검증은 다른 테스트가 맡는다.
final class RedesignScreenshotTests: XCTestCase {
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testCaptureRedesignScreens() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["홈"].waitForExistence(timeout: 40), app.debugDescription)
        sleep(1)
        capture(app, "01-home")

        app.tabBars.buttons["다운로드"].tap()
        sleep(1)
        capture(app, "02-downloads")

        app.tabBars.buttons["보관함"].tap()
        sleep(1)
        capture(app, "03-library")

        let albums = app.buttons.matching(NSPredicate(format: "label == '앨범'")).firstMatch
        if albums.waitForExistence(timeout: 5) {
            albums.tap()
            sleep(1)
            capture(app, "04-albums")

            let firstCard = app.scrollViews.buttons.firstMatch
            if firstCard.waitForExistence(timeout: 5) {
                firstCard.tap()
                sleep(1)
                capture(app, "05-album")

                let play = app.buttons.matching(NSPredicate(format: "label == '재생'")).firstMatch
                if play.waitForExistence(timeout: 5) {
                    play.tap()
                    sleep(2)
                    let mini = app.otherElements["미니 플레이어"]
                    if mini.waitForExistence(timeout: 5) {
                        mini.tap()
                        sleep(2)
                        capture(app, "06-now-playing")
                        let close = app.buttons["재생 화면 닫기"]
                        if close.waitForExistence(timeout: 5) { close.tap() }
                        sleep(1)
                    }
                }
            }
        }

        app.tabBars.buttons["검색"].tap()
        sleep(1)
        capture(app, "07-search-browse")

        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 10) {
            field.tap()
            field.typeText("newjeans")
            _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '음원'"))
                .firstMatch.waitForExistence(timeout: 45)
            sleep(2)
            capture(app, "08-search-results")
        }
    }
}
