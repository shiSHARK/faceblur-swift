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

    /// True when the element's centre is on screen, clear of the home indicator and not under the pinned photo. The
    /// test does not ask for hittability: during a scroll the system cannot always compute a hit point, and the
    /// tap that follows checks it anyway.
    private func isShown(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        let screen = app.windows.firstMatch.frame
        let centre = CGPoint(x: element.frame.midX, y: element.frame.midY)
        guard screen.contains(centre), centre.y < screen.maxY - 40 else { return false }
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo preview'")).firstMatch
        return !(preview.exists && preview.frame.insetBy(dx: -12, dy: -12).contains(centre))
    }

    /// Scrolls until the element is on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if isShown(element, in: app) { return element }
        let list = app.scrollViews.firstMatch // beside the photo in landscape: swipe the list, not the screen centre
        for _ in 0..<30 {
            list.swipeUp()
            if isShown(element, in: app) { return element }
        }
        for _ in 0..<40 {
            list.swipeDown()
            if isShown(element, in: app) { return element }
        }
        shot("reveal-failed")
        XCTFail("cannot scroll to \(element)")
        return element
    }

    private func audit(_ app: XCUIApplication) throws {
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .elementDetection, .sufficientElementDescription, .trait]) { issue in
            XCTContext.runActivity(named: "audit: \(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0)") { _ in }
            guard issue.auditType == .contrast, let element = issue.element else { return false }
            // WCAG 2.2 SC 1.4.3 exempts inactive components: a disabled button (Undo with nothing to undo) may be dim.
            if !element.isEnabled { return true }
            // Text that is cut by the bottom edge of the screen has the system's home indicator drawn over it; the
            // audit measures that, not the text (the same text passes once it is scrolled up).
            return element.frame.maxY > app.windows.firstMatch.frame.maxY - 34 && element.frame.minY < app.windows.firstMatch.frame.maxY
        }
    }

    /// Adds a mask and moves it once; the photo must be on screen at the same time as the button that was pressed.
    private func assertPhotoStaysVisibleWhileMoving(_ app: XCUIApplication, sideBySide: Bool) {
        reveal(app.buttons["Add a mask"], in: app).tap()
        let move = reveal(app.buttons["Move mask 2 left"], in: app)
        move.tap()
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo preview'")).firstMatch
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
        let preview = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo preview'")).firstMatch
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
        try audit(app)
    }

    func testTheAccessibilityAuditFindsNothingInLandscapeAtTheLargestTextSize() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = try reviewScreen(arguments: Self.largestText)
        shot("a11y-03c-landscape-largest-text")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo preview'")).firstMatch.exists)
        try audit(app)
    }

    func testButtonsStackAtTheLargestTextSizeAndShareARowOtherwise() throws {
        let normal = try reviewScreen()
        var add = reveal(normal.buttons["Add a mask"], in: normal)
        var undo = normal.buttons["Undo"]
        XCTAssertEqual(add.frame.minY, undo.frame.minY, accuracy: 1, "side by side while both fit")
        normal.terminate()

        let large = try reviewScreen(arguments: Self.largestText)
        add = reveal(large.buttons["Add a mask"], in: large)
        undo = large.buttons["Undo"]
        XCTAssertLessThanOrEqual(add.frame.maxY, undo.frame.minY, "stacked at the largest size, so no label is cut")
        XCTAssertEqual(add.frame.width, undo.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(undo.frame.height, 44)
    }

    /// A button label broken in the middle of a word ("Le" / "ft") makes a button much taller than wide.
    func testMoveButtonsAreWiderThanTallAtTheLargestTextSize() throws {
        let app = try reviewScreen(arguments: Self.largestText)
        reveal(app.buttons["Add a mask"], in: app).tap()
        for label in ["Move mask 2 left", "Move mask 2 right", "Move mask 2 up", "Move mask 2 down",
                      "Make mask 2 smaller", "Make mask 2 larger"] {
            let button = reveal(app.buttons[label], in: app)
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
        try audit(app)
        reveal(app.buttons["Add a mask"], in: app).tap()
        shot("a11y-05-dark-added-mask")
    }

    func testTheAccessibilityAuditFindsNothingOnTheFirstScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Choose model file"].waitForExistence(timeout: 10))
        try audit(app)
        // Full width, like "Choose a photo".
        let choose = app.buttons["Choose model file"], photo = app.buttons["Choose a photo"]
        XCTAssertEqual(choose.frame.width, photo.frame.width, accuracy: 1)
    }
}
