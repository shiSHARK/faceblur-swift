// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Drives the demo on a simulator with the pinned model and a registered public fixture. The model and the photo
/// reach the app through the debug-build launch hooks (the system pickers are out of process); a separate test taps
/// the real photo picker. Paths come from TEST_RUNNER_FACEBLUR_MODEL / _PHOTO; screenshots go to
/// TEST_RUNNER_FACEBLUR_SCREENSHOT_DIR when it is set.
@MainActor
final class SwiftUIDemoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }, "set TEST_RUNNER_\(name)")
    }

    private func launch(photo: Bool, model: Bool = true, arguments: [String] = []) throws -> XCUIApplication {
        let app = XCUIApplication()
        var environment: [String: String] = [:]
        if model { environment["FACEBLUR_DEMO_MODEL"] = try env("FACEBLUR_MODEL") }
        if photo { environment["FACEBLUR_DEMO_PHOTO"] = try env("FACEBLUR_PHOTO") }
        app.launchEnvironment = environment
        app.launchArguments = arguments
        app.launch()
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

    private func wait(_ element: XCUIElement, _ seconds: TimeInterval = 60, _ message: String = "") {
        XCTAssertTrue(element.waitForExistence(timeout: seconds), "missing: \(element) \(message)")
    }

    /// Scrolls until the element is on screen (lazy grids and long lists create their rows on demand).
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        if element.exists && element.isHittable { return element }
        for _ in 0..<10 {
            app.swipeUp()
            if element.exists && element.isHittable { return element }
        }
        for _ in 0..<20 {
            app.swipeDown()
            if element.exists && element.isHittable { return element }
        }
        XCTFail("cannot scroll to \(element)")
        return element
    }

    private func waitUntilEnabled(_ element: XCUIElement, _ seconds: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(seconds)
        while !(element.exists && element.isEnabled) && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(element.exists && element.isEnabled, "not enabled: \(element)")
    }

    func testStartScreenDisablesThePhotoStepUntilAModelIsLoaded() throws {
        let app = try launch(photo: false, model: false)
        wait(app.buttons["Choose model file"], 10)
        XCTAssertTrue(app.staticTexts["Choose a model first"].exists)
        XCTAssertFalse(app.buttons["Choose a photo"].isEnabled)
        shot("01-start")
    }

    func testModelConfirmationThenPhotoStep() throws {
        let app = try launch(photo: false)
        let use = app.buttons["Use this model"]
        wait(use, 30)
        XCTAssertTrue(app.staticTexts["SHA-256"].exists)
        XCTAssertFalse(app.buttons["Choose a photo"].isEnabled, "nothing is loaded before the confirmation")
        shot("02-model-confirmation")
        use.tap()
        let photoButton = app.buttons["Choose a photo"]
        waitUntilEnabled(photoButton)
        shot("03-photo-step")
    }

    func testReviewEditAndSave() throws {
        let app = try launch(photo: true)
        wait(app.buttons["Use this model"], 30)
        app.buttons["Use this model"].tap()
        wait(app.buttons["Apply masks and save JPEG"], 90, "review")
        XCTAssertTrue(app.staticTexts["1 face detected, 1 mask will be applied"].exists)
        XCTAssertTrue(app.buttons["Remove mask 1"].exists)
        shot("04-review")

        reveal(app.buttons["Add a mask"], in: app).tap()
        XCTAssertTrue(app.staticTexts["2 masks will be applied"].exists || app.staticTexts["1 face detected, 2 masks will be applied"].exists)
        reveal(app.buttons["Move mask 2 left"], in: app).tap()
        reveal(app.buttons["Make mask 2 larger"], in: app).tap()
        shot("05-added-mask")

        reveal(app.buttons["Remove mask 1"], in: app).tap()
        XCTAssertTrue(app.buttons["Restore mask 1"].exists)
        XCTAssertTrue(app.staticTexts["Off: this area stays uncovered"].exists, "state is also in words")
        reveal(app.buttons["Undo"], in: app).tap()
        XCTAssertTrue(app.buttons["Remove mask 1"].exists)

        reveal(app.buttons["Apply masks and save JPEG"], in: app).tap()
        wait(app.buttons["Save JPEG"], 90, "saved stage")
        sleep(2)
        shot("06-export-sheet")
        // Close the system exporter without saving anything.
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3) {
            cancel.tap()
        } else { // the iOS 18 exporter has no Cancel button: drag the sheet down from its header
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        wait(app.staticTexts["Not saved. Use Save JPEG to choose where to put the file."], 10)
        // Closing the exporter without saving leaves no staged copy in the app's storage either.
        XCTAssertEqual(AppContainer.leftovers(in: try containerRoot(), bundleID: Self.bundleID), [], "after cancelling the exporter")
        shot("07-result")
    }

    func testLargeTextAndAccessibilityAudit() throws {
        let app = try launch(photo: true, arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        wait(app.buttons["Use this model"], 30)
        app.buttons["Use this model"].tap()
        wait(app.buttons["Apply masks and save JPEG"], 90, "review")
        shot("08-review-largest-text")
        reveal(app.buttons["Apply masks and save JPEG"], in: app)
        try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .elementDetection, .sufficientElementDescription, .trait]) { issue in
            // Name the element so a finding can be fixed.
            XCTContext.runActivity(named: "audit: \(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0)") { _ in }
            // WCAG 2.2 SC 1.4.3 exempts inactive components: a disabled button (Undo with nothing to undo) may be dim.
            return issue.auditType == .contrast && issue.element?.isEnabled == false
        }
    }

    /// Loads the model through the confirmation step and picks the newest photo in the real system photo picker.
    private func pickWithTheRealPicker(_ app: XCUIApplication) {
        wait(app.buttons["Use this model"], 30)
        app.buttons["Use this model"].tap()
        let photoButton = app.buttons["Choose a photo"]
        waitUntilEnabled(photoButton)
        photoButton.tap()
        sleep(3)
        shot("09-system-photo-picker")
        // The simulator's library holds only what the test run added with simctl addmedia.
        // The photo added with simctl addmedia is the newest, which the picker lists first in its grid (below the
        // header and the privacy notice).
        let images = app.images
        _ = images.firstMatch.waitForExistence(timeout: 10)
        let grid = images.allElementsBoundByIndex.filter { $0.isHittable && $0.frame.minY > 300 }
        let newest = grid.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        XCTAssertNotNil(newest, "the picker grid shows the added photo")
        newest?.tap()
        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 3) { add.tap() }
        wait(app.buttons["Apply masks and save JPEG"], 90, "review after the real picker")
    }

    func testRealPhotoPickerOpens() throws {
        let app = try launch(photo: false)
        pickWithTheRealPicker(app)
        shot("10-review-from-picker")
    }

    // MARK: Nothing is left behind in the app's storage

    private static let bundleID = "io.github.shishark.faceblur.swiftuidemo"

    private func containerRoot() throws -> URL {
        try XCTUnwrap(AppContainer.root(bundleID: Self.bundleID), "the app's data container was not found on this simulator")
    }

    /// Prints names and sizes only (never content) so a run log shows what the container held at each step.
    private func record(_ step: String, _ root: URL) {
        let all = AppContainer.listing(of: root)
        let left = AppContainer.leftovers(in: root, bundleID: Self.bundleID)
        print("CONTAINER \(step): \(all.count) files, \(left.count) beyond the system's own")
        for entry in all { print("CONTAINER \(step):   \(entry)") }
    }

    /// A full cycle with the REAL system photo picker and the REAL system file exporter: pick, mask, save. The app's
    /// data container must hold no file but the system's own after the picker has delivered the photo, while the
    /// exporter is open and after the save; the only copy is the one the person exports (outside the container).
    func testNothingButTheExportIsLeftBehindAfterPickMaskAndSave() throws {
        let app = try launch(photo: false)
        let root = try containerRoot()
        AppContainer.removeEarlierExports(named: "masked-photo")
        defer { AppContainer.removeEarlierExports(named: "masked-photo") } // the export of this run is not kept either
        record("launch", root)
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "before the cycle")

        pickWithTheRealPicker(app)
        record("after pick", root)
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "after the picker delivered the photo")

        reveal(app.buttons["Apply masks and save JPEG"], in: app).tap()
        wait(app.buttons["Save JPEG"], 90, "saved stage")
        sleep(2)
        record("exporter open", root)
        // The system stages the JPEG it is exporting in tmp (tmp/<name>.jpeg, or tmp/<UUID>/<name>.jpeg on iOS 27)
        // for as long as the exporter is open: that one file is expected here and nothing else. It must be gone once
        // the exporter has closed (below).
        let staged = AppContainer.leftovers(in: root, bundleID: Self.bundleID)
        XCTAssertEqual(staged.count, 1, "while the exporter is open: \(staged)")
        XCTAssertTrue(staged.first.map { $0.path.hasPrefix("tmp/") && $0.path.hasSuffix("/masked-photo.jpeg") } ?? false,
                      "while the exporter is open: \(staged)")
        shot("11-exporter")

        // Save in the system exporter: the file goes where the system keeps "On My iPhone", outside the app container.
        let save = app.buttons.matching(NSPredicate(format: "label IN {'Save', 'Move'}")).firstMatch // named by iOS version
        wait(save, 10, "the exporter's Save button")
        save.tap()
        wait(app.staticTexts["Saved. 1 mask applied."], 30, "saved message")
        sleep(2)
        record("after save", root)
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "after the save")
        shot("12-saved")

        // Start over, as a person would: nothing stays either.
        reveal(app.buttons["Choose another photo"], in: app).tap()
        sleep(1)
        record("after start over", root)
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "after starting over")
    }

    /// The app can be ended while the exporter is open (swiped away, or killed by the system), which leaves the file
    /// the exporter staged in tmp. The next launch must delete it (SwiftUIDemoApp.init -> StagedFiles.removeExport).
    func testTheNextLaunchDeletesAnExportStagedByAnEndedApp() throws {
        let app = try launch(photo: true)
        let root = try containerRoot()
        wait(app.buttons["Use this model"], 30)
        app.buttons["Use this model"].tap()
        wait(app.buttons["Apply masks and save JPEG"], 90, "review")
        app.buttons["Apply masks and save JPEG"].tap()
        wait(app.buttons["Save JPEG"], 90, "saved stage")
        sleep(2)
        let staged = AppContainer.leftovers(in: root, bundleID: Self.bundleID)
        record("exporter open", root)
        XCTAssertEqual(staged.count, 1, "precondition: the exporter has staged its file: \(staged)")

        app.terminate() // the app ends while the exporter is open: nothing can delete the staged file now
        record("after terminate", root)

        let relaunched = try launch(photo: false, model: false)
        wait(relaunched.buttons["Choose model file"], 30)
        record("after relaunch", root)
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "after the next launch")
    }

    /// Control for the check above: a file planted in the container must be reported, a file in each place that
    /// matters (tmp, Documents, Library/Caches), so an empty result of the real test cannot come from a blind check.
    func testTheContainerCheckSeesAPlantedFile() throws {
        let app = try launch(photo: false, model: false)
        wait(app.buttons["Choose model file"], 10)
        let root = try containerRoot()
        let planted = ["tmp/planted-control.jpg", "Documents/planted-control.jpg", "Library/Caches/planted-control.jpg"]
        defer { for rel in planted { try? FileManager.default.removeItem(at: root.appendingPathComponent(rel)) } }
        XCTAssertEqual(AppContainer.leftovers(in: root, bundleID: Self.bundleID), [], "clean before planting")
        for rel in planted {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xFF, count: 16).write(to: url)
        }
        let found = AppContainer.leftovers(in: root, bundleID: Self.bundleID)
        XCTAssertEqual(found.map(\.path).sorted(), planted.sorted(), "the planted files are reported")
        XCTAssertEqual(found.map(\.size), [16, 16, 16])
    }
}
