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

    /// The system accessibility audit. Two cases are not findings of the app and are skipped:
    /// - a disabled control (WCAG 2.2 SC 1.4.3 exempts inactive components; Undo with nothing to undo may be dim);
    /// - text that the pinned photo or the system's home indicator cuts: the audit measures the overlapping bar
    ///   or indicator, not the text (the same text passes once it is scrolled into the free area).
    func audit() throws {
        try performAccessibilityAudit(for: [.contrast, .hitRegion, .elementDetection, .sufficientElementDescription, .trait]) { issue in
            // Name the element so a finding can be fixed.
            XCTContext.runActivity(named: "audit: \(issue.compactDescription) | \(issue.element?.label ?? "-") | \(issue.element?.elementType.rawValue ?? 0)") { _ in }
            guard issue.auditType == .contrast, let element = issue.element else { return false }
            if !element.isEnabled { return true }
            let screen = self.windows.firstMatch.frame
            if element.frame.maxY > screen.maxY - 34 && element.frame.minY < screen.maxY { return true }
            return element.frame.intersects(self.pinnedPhotoArea)
        }
    }
}
