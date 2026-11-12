// SPDX-License-Identifier: Apache-2.0
import ImageIO
import UIKit
import XCTest
@testable import SwiftUIDemo

/// The real engine (FaceBlur public API) against the pinned model and a registered public fixture. The paths come
/// from the test environment (TEST_RUNNER_FACEBLUR_MODEL and TEST_RUNNER_FACEBLUR_TESTDATA, as in the package's
/// own tests); without them these tests fail and name the missing variable.
final class EngineIntegrationTests: XCTestCase {
    private static let pinnedSHA = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"

    private func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 },
                      "set TEST_RUNNER_\(name)")
    }

    private func fixtureData() throws -> Data {
        let folder = try env("FACEBLUR_TESTDATA")
        return try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("pd/pd-p06-single-face-s100-x00200-y01600.png"))
    }

    private func loadedEngine() async throws -> FaceBlurEngine {
        let engine = FaceBlurEngine()
        let candidate = try await engine.inspectModel(at: URL(fileURLWithPath: try env("FACEBLUR_MODEL")))
        XCTAssertEqual(candidate.sha256, Self.pinnedSHA, "the hash shown to the person is the file's SHA-256")
        XCTAssertEqual(candidate.hashLines.count, 4)
        try await engine.loadModel(candidate)
        return engine
    }

    func testDetectMaskAndEncodeWithTheRealLibrary() async throws {
        let engine = try await loadedEngine()
        let info = try await engine.preparePhoto(try fixtureData())
        XCTAssertGreaterThan(info.width, 0)
        let found = try await engine.detect()
        XCTAssertGreaterThanOrEqual(found.faces.count, 1)
        XCTAssertEqual(found.faces.count, found.masks.count)
        let face = try XCTUnwrap(found.faces.first)
        XCTAssertGreaterThan(face.box.width, 10)

        let specs = found.masks.indices.map { MaskSpec.detected(planIndex: $0) }
        let out = try await engine.maskAndEncode(specs)
        XCTAssertEqual(out.maskCount, specs.count)
        try PhotoPixelsTests.assertNoMetadata(out.data)

        // The masked photo differs from the plain one inside the face and matches it far outside the mask.
        let plain = try XCTUnwrap(PhotoPixels.jpegData(from: try XCTUnwrap(info.preview.cgImage)))
        let masked = try XCTUnwrap(UIImage(data: out.data)?.cgImage)
        let original = try XCTUnwrap(UIImage(data: plain)?.cgImage)
        XCTAssertEqual(masked.width, original.width)
        let mid = (x: Int(face.box.centerX), y: Int(face.box.centerY))
        XCTAssertGreaterThan(try Self.difference(masked, original, around: mid, radius: 6), 12, "the face is covered")

        if let dir = ProcessInfo.processInfo.environment["FACEBLUR_DEMO_OUT_DIR"], !dir.isEmpty {
            try out.data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("engine-output.jpg"))
        }
    }

    func testAPhotoWithoutMasksComesOutUnchangedInTheMaskedArea() async throws {
        let engine = try await loadedEngine()
        let info = try await engine.preparePhoto(try fixtureData())
        let found = try await engine.detect()
        let face = try XCTUnwrap(found.faces.first)
        let out = try await engine.maskAndEncode([])
        XCTAssertEqual(out.maskCount, 0)
        let masked = try XCTUnwrap(UIImage(data: out.data)?.cgImage)
        let original = try XCTUnwrap(info.preview.cgImage)
        let mid = (x: Int(face.box.centerX), y: Int(face.box.centerY))
        XCTAssertLessThan(try Self.difference(masked, original, around: mid, radius: 6), 12,
                          "without masks the face stays as it was (JPEG loss only)")
    }

    func testEditingDoesNotStackOnMaskedPixels() async throws {
        let engine = try await loadedEngine()
        _ = try await engine.preparePhoto(try fixtureData())
        let found = try await engine.detect()
        let first = try await engine.maskAndEncode(found.masks.indices.map { .detected(planIndex: $0) })
        let none = try await engine.maskAndEncode([])
        XCTAssertNotEqual(first.data, none.data, "each save starts from the upright photo, not from masked pixels")
    }

    func testARotatedPhotoIsDetectedAfterDrawingItUpright() async throws {
        // A non-square upright photo, stored a quarter turn clockwise, shown with the orientation that undoes it.
        let base = try Self.padded(try XCTUnwrap(UIImage(data: try fixtureData())?.cgImage), width: 720)
        let stored = try Self.rotatedClockwise(base)
        let photo = UIImage(cgImage: stored, scale: 1, orientation: .left) // .left: shown turned back counter-clockwise
        let jpegData = try XCTUnwrap(photo.jpegData(compressionQuality: 0.95))
        let engine = try await loadedEngine()
        let info = try await engine.preparePhoto(jpegData)
        XCTAssertEqual(info.width, 720, "the orientation is applied")
        XCTAssertEqual(info.height, 640)
        let preview = try XCTUnwrap(info.preview.cgImage)
        XCTAssertLessThan(try Self.difference(preview, base, around: (x: 360, y: 320), radius: 6), 15,
                          "the upright pixels equal the original, not a turned copy")
        let found = try await engine.detect()
        XCTAssertGreaterThanOrEqual(found.faces.count, 1, "the upright face is found")
    }

    func testAModelWithAnotherHashIsRefused() async throws {
        let engine = FaceBlurEngine()
        let real = try await engine.inspectModel(at: URL(fileURLWithPath: try env("FACEBLUR_MODEL")))
        let wrong = ModelCandidate(url: real.url, fileName: real.fileName, sizeBytes: real.sizeBytes,
                                   sha256: String(repeating: "0", count: 64))
        do {
            try await engine.loadModel(wrong)
            XCTFail("a different hash must not load")
        } catch {
            XCTAssertEqual(error as? DemoFailure, .modelDoesNotMatch)
        }
    }

    func testNotAPhotoAndNotAModelAreRefused() async throws {
        let engine = try await loadedEngine()
        do {
            _ = try await engine.preparePhoto(Data([1, 2, 3]))
            XCTFail("not an image")
        } catch {
            XCTAssertEqual(error as? DemoFailure, .photoUnreadable)
        }
        let notAModel = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-model-\(UUID().uuidString)")
        try Data().write(to: notAModel)
        defer { try? FileManager.default.removeItem(at: notAModel) }
        do {
            _ = try await engine.inspectModel(at: notAModel)
            XCTFail("an empty file is not a model")
        } catch {
            XCTAssertEqual(error as? DemoFailure, .modelFileUnsuitable)
        }
    }

    // MARK: Helpers

    /// Mean absolute difference of the colour channels in a square around a point.
    private static func difference(_ a: CGImage, _ b: CGImage, around p: (x: Int, y: Int), radius: Int) throws -> Double {
        let ca = try XCTUnwrap(PhotoPixels.makeContext(from: a)), cb = try XCTUnwrap(PhotoPixels.makeContext(from: b))
        let da = try XCTUnwrap(ca.data).assumingMemoryBound(to: UInt8.self)
        let db = try XCTUnwrap(cb.data).assumingMemoryBound(to: UInt8.self)
        var total = 0.0, count = 0.0
        for y in max(0, p.y - radius)...min(a.height - 1, p.y + radius) {
            for x in max(0, p.x - radius)...min(a.width - 1, p.x + radius) {
                for c in 0..<3 {
                    total += abs(Double(da[y * ca.bytesPerRow + x * 4 + c]) - Double(db[y * cb.bytesPerRow + x * 4 + c]))
                    count += 1
                }
            }
        }
        return total / count
    }

    /// The image centred on a grey canvas `width` pixels wide (same height).
    private static func padded(_ image: CGImage, width: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: image.height))
        ctx.draw(image, in: CGRect(x: (width - image.width) / 2, y: 0, width: image.width, height: image.height))
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func rotatedClockwise(_ image: CGImage) throws -> CGImage {
        let w = image.width, h = image.height
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return try XCTUnwrap(ctx.makeImage())
    }
}
