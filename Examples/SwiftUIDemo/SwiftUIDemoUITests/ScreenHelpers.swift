// SPDX-License-Identifier: Apache-2.0
import XCTest

/// Helpers shared by the UI tests. The review screen pins the photo above (or, in landscape, beside) the list, so
/// "on screen" means: the element's centre is on the screen, clear of the home indicator and not under the photo.
extension XCUIApplication {
    /// The pinned photo preview of the review screen (it carries the summary as its value).
    var photoPreview: XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label == 'Photo preview'")).firstMatch
    }

    /// The list's visible area is what the screen shows minus the pinned photo; this is the test for a tap target.
    func isShown(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let screen = windows.firstMatch.frame
        let centre = CGPoint(x: element.frame.midX, y: element.frame.midY)
        // The frame is checked before anything else: asking for hittability of an element that is not laid out (or
        // is moving) raises a failure in XCTest.
        guard screen.contains(centre), centre.y < screen.maxY - 40 else { return false }
        return !pinnedPhotoArea.contains(centre)
    }

    /// Everything the pinned photo covers: in portrait the band from the top of the screen to the bottom of the
    /// photo (the bar behind it hides the list there, status bar included), in landscape the pane on the left.
    var pinnedPhotoArea: CGRect {
        let preview = photoPreview
        guard preview.exists else { return .null }
        let screen = windows.firstMatch.frame
        let margin: CGFloat = 12
        if screen.width > screen.height {
            return CGRect(x: 0, y: 0, width: preview.frame.maxX + margin, height: screen.height)
        }
        return CGRect(x: 0, y: 0, width: screen.width, height: preview.frame.maxY + margin)
    }

    /// Scrolls the list until the element is on screen. Beside the photo in landscape the list is not the screen
    /// centre, so the swipes go to the list itself.
    @discardableResult
    func reveal(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        if isShown(element) { return element }
        let list = scrollViews.firstMatch
        for _ in 0..<30 {
            list.swipeUp()
            if isShown(element) { return element }
        }
        for _ in 0..<40 {
            list.swipeDown()
            if isShown(element) { return element }
        }
        XCTFail("cannot scroll to \(element)", file: file, line: line)
        return element
    }

    /// The system accessibility audit. Only contrast findings are ever skipped, and each skip is written to the test
    /// log as "audit waived: <reason> | <label>", so none is silent. The three reasons, one line each:
    /// - disabled control: WCAG 2.2 SC 1.4.3 exempts inactive components (seen: "Choose a photo" before a model is
    ///   chosen, "Undo" with nothing to undo); a dim label there is the platform's disabled style, not a text colour
    ///   the app picked, so there is nothing to fix;
    /// - bottom edge: the audit measures the system home indicator that overlaps the element, not the text (the same
    ///   text passes once it is scrolled into the free area);
    /// - under the pinned photo: the audit measures the photo bar that overlaps the element, not the text (same).
    func audit() throws {
        try performAccessibilityAudit(for: [.contrast, .hitRegion, .elementDetection, .sufficientElementDescription, .trait]) { issue in
            // Name the element so a finding can be fixed.
            XCTContext.runActivity(named: "audit: \(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0)") { _ in }
            guard issue.auditType == .contrast, let element = issue.element else { return false }
            let screen = self.windows.firstMatch.frame
            let reason: String
            if !element.isEnabled {
                reason = "disabled control"
            } else if element.frame.maxY > screen.maxY - 34 && element.frame.minY < screen.maxY {
                reason = "bottom edge"
            } else if element.frame.intersects(self.pinnedPhotoArea) {
                reason = "under the pinned photo"
            } else {
                return false
            }
            XCTContext.runActivity(named: "audit waived: \(reason) | \(element.label)") { _ in }
            return true
        }
    }
}
