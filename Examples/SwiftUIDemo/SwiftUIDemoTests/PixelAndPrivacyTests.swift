// SPDX-License-Identifier: Apache-2.0
import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import SwiftUIDemo

final class PhotoPixelsTests: XCTestCase {
    /// 40 x 20 pixels: the left half red, the right half blue.
    private func twoColourImage(width: Int = 40, height: Int = 20) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try XCTUnwrap(ctx.makeImage())
    }

    /// The (red, blue) channel values of the pixel at (x, y), top-left origin.
    private func redBlue(_ image: CGImage, x: Int, y: Int) throws -> (UInt8, UInt8) {
        let ctx = try XCTUnwrap(PhotoPixels.makeContext(from: image))
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        let offset = y * ctx.bytesPerRow + x * 4
        return (data[offset + 2], data[offset]) // BGRA
    }

    func testUprightDrawingAppliesTheOrientationThatCGImageDrops() throws {
        let source = try twoColourImage()
        let photo = UIImage(cgImage: source, scale: 1, orientation: .right) // displayed rotated clockwise
        XCTAssertEqual(photo.cgImage?.width, 40, "UIImage.cgImage keeps the stored grid")
        let upright = try XCTUnwrap(PhotoPixels.uprightImage(from: photo))
        let pixels = try XCTUnwrap(upright.cgImage)
        XCTAssertEqual(pixels.width, 20)
        XCTAssertEqual(pixels.height, 40)
        let top = try redBlue(pixels, x: 10, y: 5)
        let bottom = try redBlue(pixels, x: 10, y: 35)
        XCTAssertGreaterThan(top.0, 200, "the left half of the stored grid is at the top once upright")
        XCTAssertGreaterThan(bottom.1, 200)
    }

    func testLargePhotosAreDrawnAtTheWorkingSize() throws {
        let photo = UIImage(cgImage: try twoColourImage(width: 4_000, height: 2_000), scale: 1, orientation: .up)
        let upright = try XCTUnwrap(PhotoPixels.uprightImage(from: photo)?.cgImage)
        XCTAssertEqual(upright.width, 3_500)
        XCTAssertEqual(upright.height, 1_750)
    }

    func testAnEmptyPhotoIsRefused() {
        XCTAssertNil(PhotoPixels.uprightImage(from: UIImage()))
    }

    /// The file holds the fixed JFIF header and an Exif block with Orientation = 1 only, no XMP, IPTC, colour profile,
    /// comment, thumbnail or second image, and nothing after the end marker.
    static func assertNoMetadata(_ data: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetCount(source), 1, "no auxiliary or secondary image", file: file, line: line)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                                       file: file, line: line)
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyMakerAppleDictionary, kCGImagePropertyExifAuxDictionary] {
            XCTAssertNil(properties[key], "\(key) must be absent", file: file, line: line)
        }
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 1, "upright, written as 1", file: file, line: line)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertEqual(Set(tiff.keys.map { $0 as String }), [kCGImagePropertyTIFFOrientation as String],
                       "IFD0 holds only the orientation", file: file, line: line)
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(2)), [0xFF, 0xD8], file: file, line: line)
        XCTAssertEqual(Array(bytes[2..<20]), PhotoPixels.fixedJFIF, file: file, line: line)
        XCTAssertEqual(Array(bytes[20..<(20 + PhotoPixels.fixedExif.count)]), PhotoPixels.fixedExif, file: file, line: line)
        var offset = 20 + PhotoPixels.fixedExif.count
        var sawScan = false
        while offset + 4 <= bytes.count {
            XCTAssertEqual(bytes[offset], 0xFF, file: file, line: line)
            let marker = bytes[offset + 1]
            if marker == 0xDA { sawScan = true; break }
            if (0xE0...0xEF).contains(marker) || marker == 0xFE {
                XCTFail("segment \(marker) must be absent", file: file, line: line)
            }
            offset += 2 + (Int(bytes[offset + 2]) << 8) + Int(bytes[offset + 3])
        }
        XCTAssertTrue(sawScan, file: file, line: line)
        let soi = (0..<(bytes.count - 2)).filter { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }
        XCTAssertEqual(soi.count, 1, "no embedded thumbnail", file: file, line: line)
        XCTAssertNil(data.range(of: Data("ns.adobe.com/xap".utf8)), "no XMP", file: file, line: line)
        XCTAssertNil(data.range(of: Data("ICC_PROFILE".utf8)), "no colour profile", file: file, line: line)
        XCTAssertEqual(Array(bytes.suffix(2)), [0xFF, 0xD9], "nothing after the end marker", file: file, line: line)
    }

    func testRebuildingKeepsTheImageAndDropsInjectedMetadata() throws {
        let clean = try XCTUnwrap(PhotoPixels.jpegData(from: try twoColourImage()))
        // Plant a GPS-bearing Exif block, an IPTC block, a comment and a thumbnail-bearing JFIF header after SOI.
        func segment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
            [0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload
        }
        var planted: [UInt8] = [0xFF, 0xD8]
        planted += segment(0xE0, Array("JFIF".utf8) + [0, 1, 1, 0, 0, 1, 0, 1, 2, 2, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6])
        planted += segment(0xE1, Array("Exif".utf8) + [0, 0] + Array("GPS-ish".utf8))
        planted += segment(0xED, Array("Photoshop 3.0".utf8) + [0])
        planted += segment(0xFE, Array("comment".utf8))
        planted += [UInt8](clean.dropFirst(2 + PhotoPixels.fixedJFIF.count + PhotoPixels.fixedExif.count))
        let rebuilt = try XCTUnwrap(PhotoPixels.rebuilt(Data(planted)))
        XCTAssertNil(rebuilt.range(of: Data("GPS-ish".utf8)))
        XCTAssertNil(rebuilt.range(of: Data("Photoshop".utf8)))
        XCTAssertNil(rebuilt.range(of: Data("comment".utf8)))
        XCTAssertNil(rebuilt.range(of: Data([0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6])), "a header with a thumbnail is dropped")
        XCTAssertEqual(rebuilt, clean, "what is left is exactly the clean output")
        XCTAssertEqual(UIImage(data: rebuilt)?.cgImage?.width, 40, "the image still decodes")
    }

    func testBrokenJPEGsAreRefused() {
        XCTAssertNil(PhotoPixels.rebuilt(Data()))
        XCTAssertNil(PhotoPixels.rebuilt(Data([0xFF, 0xD8, 0xFF, 0xD9])))
        XCTAssertNil(PhotoPixels.rebuilt(Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x00, 0xFF, 0xD9])))
        XCTAssertNil(PhotoPixels.rebuilt(Data([0x00, 0x01, 0x02, 0x03, 0x04, 0xFF, 0xD9])))
    }

    func testTheEncodedJPEGHasNoMetadata() throws {
        let data = try XCTUnwrap(PhotoPixels.jpegData(from: try twoColourImage()))
        try Self.assertNoMetadata(data)
    }
}

final class ModelCandidateTests: XCTestCase {
    func testHashIsShownInFourLinesOfSixteenDigits() {
        let sha = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
        let candidate = ModelCandidate(url: URL(fileURLWithPath: "/m.onnx"), fileName: "m.onnx", sizeBytes: 1, sha256: sha)
        XCTAssertEqual(candidate.hashLines, ["8f2383e4dd3cfbb4", "553ea8718107fc04", "23210dc964f9f428", "0604804ed2552fa4"])
        XCTAssertEqual(candidate.hashLines.joined(), sha)
    }
}

final class WordingTests: XCTestCase {
    func testOnlyTheThreeClaimsAndNoForbiddenWords() {
        let all = [Copy.title, Copy.intro, Copy.confirmHint, Copy.choosePhotoHint, Copy.reviewHint, Copy.noFaces,
                   Copy.notSaved, Copy.tooLateToCancel, Copy.cancelled, Copy.modelLoadingNoCancel,
                   Copy.facesAndMasks(faces: 1, masks: 1), Copy.saved(masks: 2)]
            + [DemoFailure.other, .modelDoesNotMatch, .notEnoughMemory, .outputCheckFailed].map(Copy.message)
        let text = all.joined(separator: " ").lowercased()
        for word in ["anonym", "gdpr", "compliant", "guarantee", "secure", "100 %", "ms ", "seconds", "blur the", "pixelat"] {
            XCTAssertFalse(text.contains(word), "forbidden wording: \(word)")
        }
        XCTAssertTrue(Copy.intro.contains("opaque masks"))
        XCTAssertTrue(Copy.intro.contains("without metadata"))
        XCTAssertTrue(Copy.intro.contains("no network code"))
        XCTAssertTrue(Copy.intro.contains("can miss"))
    }
}

@MainActor
final class PrivacyTests: XCTestCase {
    func testTheAppSwitcherCoverFollowsTheScenePhase() {
        let shield = PrivacyShield()
        shield.update(for: .inactive)
        XCTAssertTrue(shield.isCovering, "inactive: cover before the system takes the snapshot")
        shield.update(for: .background)
        XCTAssertTrue(shield.isCovering)
        shield.update(for: .active)
        XCTAssertFalse(shield.isCovering)
    }

    func testTheBundleDeclaresNoNetworkAccessLocationOrTracking() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNil(info["NSAppTransportSecurity"])
        XCTAssertFalse(info.keys.contains { $0.contains("Location") }, "no location usage string")
        XCTAssertNil(info["NSUserTrackingUsageDescription"])
        XCTAssertNil(info["UIBackgroundModes"])
        let purpose = try XCTUnwrap(info["NSPhotoLibraryUsageDescription"] as? String)
        XCTAssertFalse(purpose.isEmpty)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        let manifest = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0)
        XCTAssertEqual((manifest["NSPrivacyTrackingDomains"] as? [Any])?.count, 0)
    }
}
