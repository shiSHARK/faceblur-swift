// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Accessibility behaviour of the review screen on a simulator: the photo stays on screen while a mask is moved,
/// buttons do not break a word at the largest text size, and the system accessibility audit finds nothing in dark
/// mode or in landscape. The model and the photo come through the debug launch hooks like in the other UI tests
/// (TEST_RUNNER_FACEBLUR_MODEL / _PHOTO; screenshots go to TEST_RUNNER_FACEBLUR_SCREENSHOT_DIR when it is set).
@MainActor
final class AccessibilityUITests: XCTestCase {
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUp() {
        continueAfterFailure = false
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.appearance = .light
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }, "set TEST_RUNNER_\(name)")
    }

    /// Launches with the model and the photo and waits for the review.
    private func reviewScreen(arguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment = ["FACEBLUR_DEMO_MODEL": try env("FACEBLUR_MODEL"), "FACEBLUR_DEMO_PHOTO": try env("FACEBLUR_PHOTO")]
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.buttons["Use this model"].waitForExistence(timeout: 30))
        app.buttons["Use this model"].tap()
        XCTAssertTrue(app.buttons["Apply masks and save JPEG"].waitForExistence(timeout: 90), "review")
        return app
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["FACEBLUR_SCREENSHOT_DIR"], !dir.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// Adds a mask and moves it once; the photo must be on screen at the same time as the button that was pressed.
    private func assertPhotoStaysVisibleWhileMoving(_ app: XCUIApplication, sideBySide: Bool) {
        app.reveal(app.buttons["Add a mask"]).tap()
        let move = app.reveal(app.buttons["Move mask 2 left"])
        move.tap()
        let preview = app.photoPreview
        XCTAssertTrue(preview.exists, "the photo preview is in the tree while a mask is edited")
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(screen.contains(preview.frame), "the preview is entirely on screen: \(preview.frame) in \(screen)")
        XCTAssertGreaterThan(preview.frame.height, 80, "a preview big enough to see an outline move")
        XCTAssertTrue(screen.contains(CGPoint(x: move.frame.midX, y: move.frame.midY)), "the pressed button is on screen: \(move.frame)")
        XCTAssertFalse(preview.frame.intersects(move.frame), "the preview does not hide the button")
        if sideBySide {
            XCTAssertLessThanOrEqual(preview.frame.maxX, move.frame.minX, "landscape: the photo is beside the list")
        } else {
            XCTAssertLessThanOrEqual(preview.frame.maxY, move.frame.minY, "portrait: the photo is pinned above the list")
        }
    }

    func testThePhotoStaysOnScreenWhileAMaskIsMoved() throws {
        let app = try reviewScreen()
        assertPhotoStaysVisibleWhileMoving(app, sideBySide: false)
        shot("a11y-01-preview-pinned")
    }

    func testThePhotoStaysOnScreenWhileAMaskIsMovedAtTheLargestTextSize() throws {
        let app = try reviewScreen(arguments: Self.largestText)
        assertPhotoStaysVisibleWhileMoving(app, sideBySide: false)
        shot("a11y-02-preview-pinned-largest-text")
    }

    /// In landscape the list never scrolls the photo away: the photo has its own pane beside the list.
    func testThePhotoIsBesideTheListInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try reviewScreen()
        shot("a11y-03a-landscape-review")
        let preview = app.photoPreview
        let list = app.scrollViews.firstMatch
        let screen = app.windows.firstMatch.frame
        XCTAssertTrue(preview.exists)
        XCTAssertTrue(screen.contains(preview.frame), "the preview is entirely on screen: \(preview.frame) in \(screen)")
        XCTAssertGreaterThan(preview.frame.height, 150, "a preview big enough to see an outline move")
        XCTAssertLessThanOrEqual(preview.frame.maxX, list.frame.minX, "the photo is beside the list, not above it")
        // Scrolling the list leaves the photo where it is.
        let before = preview.frame
        for _ in 0..<5 { list.swipeUp() }
        XCTAssertEqual(preview.frame, before, "the photo stays put while the list scrolls")
        shot("a11y-03b-landscape-scrolled")
        try app.audit()
    }

    func testTheAccessibilityAuditFindsNothingInLandscapeAtTheLargestTextSize() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try reviewScreen(arguments: Self.largestText)
        shot("a11y-03c-landscape-largest-text")
        XCTAssertTrue(app.photoPreview.exists)
        try app.audit()
    }

    func testButtonsStackAtTheLargestTextSizeAndShareARowOtherwise() throws {
        let normal = try reviewScreen()
        var add = normal.reveal(normal.buttons["Add a mask"])
        var undo = normal.buttons["Undo"]
        XCTAssertEqual(add.frame.minY, undo.frame.minY, accuracy: 1, "side by side while both fit")
        normal.terminate()

        let large = try reviewScreen(arguments: Self.largestText)
        add = large.reveal(large.buttons["Add a mask"])
        undo = large.buttons["Undo"]
        XCTAssertLessThanOrEqual(add.frame.maxY, undo.frame.minY, "stacked at the largest size, so no label is cut")
        XCTAssertEqual(add.frame.width, undo.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(undo.frame.height, 44)
    }

    /// A button label broken in the middle of a word ("Le" / "ft") makes a button much taller than wide.
    func testMoveButtonsAreWiderThanTallAtTheLargestTextSize() throws {
        let app = try reviewScreen(arguments: Self.largestText)
        app.reveal(app.buttons["Add a mask"]).tap()
        // The first buttons of the row: at this size each one is a full-width line, so one broken label shows here.
        for label in ["Move mask 2 left", "Move mask 2 right", "Move mask 2 up"] {
            let button = app.reveal(app.buttons[label])
            XCTAssertGreaterThan(button.frame.width, button.frame.height, "\(label) is not broken into letters: \(button.frame)")
        }
        shot("a11y-06-move-buttons-largest-text")
    }

    func testTheAccessibilityAuditFindsNothingInDarkMode() throws {
        XCUIDevice.shared.appearance = .dark
        let app = try reviewScreen()
        // Audit at the top of the list: text scrolled half under the pinned photo is cut by it on purpose and is
        // not a contrast failure of the text itself.
        shot("a11y-04-dark-review")
        try app.audit()
        app.reveal(app.buttons["Add a mask"]).tap()
        shot("a11y-05-dark-added-mask")
    }

    func testTheAccessibilityAuditFindsNothingOnTheFirstScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Choose model file"].waitForExistence(timeout: 10))
        try app.audit()
        // Full width, like "Choose a photo".
        let choose = app.buttons["Choose model file"], photo = app.buttons["Choose a photo"]
        XCTAssertEqual(choose.frame.width, photo.frame.width, accuracy: 1)
    }
}
