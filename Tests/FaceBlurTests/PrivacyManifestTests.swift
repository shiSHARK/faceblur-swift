// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// The privacy manifest of the FaceBlur target is a package resource. This test reads it from the BUILT resource
/// bundle (not from the source tree) and pins its values: no tracking, no tracking domains, no collected data, and the
/// file-timestamp required-reason API with the two reasons the code needs.
final class PrivacyManifestTests: XCTestCase {
    /// The resource bundle SwiftPM builds for the FaceBlur target, found next to the test bundle (or anywhere in the
    /// loaded bundles).
    private func facadeResourceBundle() -> Bundle? {
        let testBundle = Bundle(for: PrivacyManifestTests.self)
        var folders = [testBundle.bundleURL.deletingLastPathComponent(), testBundle.bundleURL, testBundle.resourceURL]
        folders.append(Bundle.main.bundleURL)
        for folder in folders.compactMap({ $0 }) {
            let url = folder.appendingPathComponent("FaceBlur_FaceBlur.bundle")
            if let bundle = Bundle(url: url) { return bundle }
        }
        if let bundle = (Bundle.allBundles + Bundle.allFrameworks).first(where: {
            $0.bundleURL.lastPathComponent == "FaceBlur_FaceBlur.bundle"
        }) { return bundle }
        return nil
    }

    func testTheBuiltResourceBundleHoldsThePrivacyManifest() throws {
        guard let bundle = facadeResourceBundle() else {
            XCTFail("the FaceBlur resource bundle was not found next to the test bundle")
            return
        }
        guard let url = bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") else {
            XCTFail("PrivacyInfo.xcprivacy is not in the built resource bundle")
            return
        }
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let manifest = plist as? [String: Any] else {
            XCTFail("the privacy manifest is not a dictionary")
            return
        }
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        let apis = manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        XCTAssertEqual(apis.count, 1)
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPIType"] as? String, "NSPrivacyAccessedAPICategoryFileTimestamp")
        XCTAssertEqual(apis.first?["NSPrivacyAccessedAPITypeReasons"] as? [String], ["C617.1", "3B52.1"])
        XCTAssertEqual(Set(manifest.keys), [
            "NSPrivacyTracking", "NSPrivacyTrackingDomains", "NSPrivacyCollectedDataTypes", "NSPrivacyAccessedAPITypes",
        ])
    }
}
