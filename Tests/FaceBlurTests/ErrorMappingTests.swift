// SPDX-License-Identifier: Apache-2.0
import CryptoKit
@testable import FaceBlur
import FaceBlurCore
import Foundation
import XCTest

/// ADR 0011 decision 5 / ST-031 AC4: each library error arrives as its Swift case. The library exceptions are
/// produced by real library calls (their constructors are not public); the cases the library cannot be made to throw
/// from Swift on the simulator are listed in the handoff as not run.
final class ErrorMappingTests: XCTestCase {
    // Before any NSTemporaryDirectory() call of this process (see PrivateTemp).
    override class func setUp() {
        super.setUp()
        PrivateTemp.install()
    }

    /// The error a direct library call throws, mapped by the facade's table.
    private func mapped(_ body: () throws -> Any) -> FaceMaskError? {
        do {
            _ = try body()
            return nil
        } catch {
            XCTAssertNotNil((error as NSError).kotlinException, "a library exception")
            return FaceMaskError.from(error)
        }
    }

    private func profile(sha: String) throws -> FaceBlurCore.DetectorProfile {
        try FaceBlurCore.DetectorProfile(format: FaceBlurCore.DetectionFormat.YuNetLayout(), inputWidth: 640,
                                         inputHeight: 640, scoreThreshold: 0.5, expectedSha256: sha,
                                         minMaskExpandX: 1.6, minMaskExpandY: 1.8)
    }

    private func source(_ data: Data) throws -> FaceBlurCore.ModelSource {
        try data.withUnsafeBytes {
            try FaceBlurIos.shared.modelSourceFromMemory(address: Int64(Int(bitPattern: $0.baseAddress)),
                                                         byteCount: Int64($0.count))
        }
    }

    private func load(_ data: Data, sha: String) throws -> FaceBlurCore.DetectorModel {
        try FaceBlurCore.DetectorModel.companion.load(source: try source(data), profile: try profile(sha: sha),
                                                      maxModelBytes: 52_428_800)
    }

    func testInvalidConfigurationCarriesTheParameter() {
        XCTAssertEqual(mapped {
            try FaceBlurCore.MaskingConfig(style: .gradientOval, shape: .ellipse, expandX: 1.0, expandY: 1.8,
                                           feather: 0.1, color: Int32(bitPattern: 0xFF7F_7F7F))
        }, .invalidConfiguration(parameter: "expandX"))
    }

    /// The library's own expansion defaults and floors (1.6 / 1.8) equal the facade's, bound by bound.
    func testLibraryMaskExpansionDefaultsAndFloorsMatchTheFacade() throws {
        let library = try FaceBlurCore.MaskingConfig.Builder().build()
        XCTAssertEqual(library.expandX, MaskingConfiguration.default.expandX)
        XCTAssertEqual(library.expandY, MaskingConfiguration.default.expandY)
        let libraryProfile = try FaceBlurCore.DetectorProfile.Builder()
            .format(value: FaceBlurCore.DetectionFormat.YuNetLayout())
            .inputSize(width: 640, height: 640)
            .scoreThreshold(value: 0.5)
            .expectedSha256(value: String(repeating: "a", count: 64))
            .build()
        XCTAssertEqual(libraryProfile.minMaskExpandX, 1.6)
        XCTAssertEqual(libraryProfile.minMaskExpandY, 1.8)
        let rows: [(Float, Float, String?)] = [
            (1.6, 1.8, nil), (1.59, 1.8, "X"), (Float(1.6).nextDown, 1.8, "X"), (1.35, 1.55, "X"),
            (1.6, Float(1.8).nextDown, "Y"),
        ]
        for (x, y, axis) in rows {
            XCTAssertEqual(mapped {
                try FaceBlurCore.MaskingConfig(style: .gradientOval, shape: .ellipse, expandX: x, expandY: y,
                                               feather: 0.1, color: Int32(bitPattern: 0xFF7F_7F7F))
            }, axis.map { FaceMaskError.invalidConfiguration(parameter: "expand" + $0) }, "masking \(x) \(y)")
            XCTAssertEqual(mapped {
                try FaceBlurCore.DetectorProfile(format: FaceBlurCore.DetectionFormat.YuNetLayout(), inputWidth: 640,
                                                 inputHeight: 640, scoreThreshold: 0.5,
                                                 expectedSha256: String(repeating: "a", count: 64),
                                                 minMaskExpandX: x, minMaskExpandY: y)
            }, axis.map { FaceMaskError.invalidConfiguration(parameter: "minMaskExpand" + $0) }, "profile \(x) \(y)")
        }
    }

    func testUnsupportedImage() {
        var px: [UInt8] = [10, 20, 30, 0] // colour above alpha in a premultiplied layout
        let result = px.withUnsafeMutableBytes { raw in
            mapped {
                try FaceBlurIos.shared.wrapRgba(address: Int64(Int(bitPattern: raw.baseAddress)), width: 1, height: 1,
                                                bytesPerRow: 4, layout: .rgbaPremultiplied)
            }
        }
        XCTAssertEqual(result, .unsupportedImage)
        XCTAssertEqual(px, [10, 20, 30, 0], "nothing written")
    }

    func testIoFailedForAMissingModelFile() {
        XCTAssertEqual(mapped {
            try FaceBlurCore.DetectorModel.companion.load(
                source: FaceBlurCore.ModelSource.companion.fromFile(path: NSTemporaryDirectory() + "missing-\(UUID())"),
                profile: try self.profile(sha: Fixture.yunetSha256), maxModelBytes: 52_428_800)
        }, .ioFailed)
    }

    func testModelIntegrityForAnotherHash() throws {
        let data = try Fixture.modelData()
        XCTAssertEqual(mapped { try self.load(data, sha: String(repeating: "0", count: 64)) }, .modelIntegrity)
    }

    func testModelRejectedCarriesTheFindings() throws {
        let junk = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sha = SHA256.hash(data: junk).map { String(format: "%02x", $0) }.joined()
        guard case let .modelRejected(findings)? = mapped({ try self.load(junk, sha: sha) }) else {
            return XCTFail("modelRejected expected")
        }
        XCTAssertFalse(findings.isEmpty)
    }

    // `runtimeUnavailable` had its real trigger here while iOS file mode was missing; with file mode in the library and
    // the glue registered, no library call raises it in this process (see the handoff), so the file-mode call now
    // checks a real `UnsupportedTarget` (an existing target without replaceExisting).
    func testUnsupportedTargetClosedCancelledAndMaskPlanMismatchFromALibraryMasker() throws {
        try Runtime.check() // the facade's registration of the glue, before any direct library masker
        let model = try load(try Fixture.modelData(), sha: Fixture.yunetSha256)
        let masker = try FaceBlurCore.FaceMasker(model: model, config: try FaceBlurCore.FaceMaskerConfig(
            masking: try FaceBlurCore.MaskingConfig(style: .gradientOval, shape: .ellipse, expandX: 1.6,
                                                    expandY: 1.8, feather: 0.1, color: Int32(bitPattern: 0xFF7F_7F7F)),
            onnxThreads: 0))
        var px = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        try px.withUnsafeMutableBytes { raw in
            let image = try FaceBlurIos.shared.wrapRgba(address: Int64(Int(bitPattern: raw.baseAddress)), width: 64,
                                                        height: 64, bytesPerRow: 256, layout: .rgbaNoneSkip)
            let fixture = try Fixture.url(Fixture.face).path
            let existing = NSTemporaryDirectory() + "faceblur-existing-\(UUID().uuidString).jpg"
            XCTAssertTrue(FileManager.default.createFile(atPath: existing, contents: Data([1])))
            defer { try? FileManager.default.removeItem(atPath: existing) }
            XCTAssertEqual(mapped {
                try masker.maskFile(source: fixture, target: FaceBlurCore.OutputTarget.NewFile(
                                        path: existing, replaceExisting: false),
                                    options: try FaceBlurCore.FileOptions.Builder().build(), plan: nil,
                                    cancellation: nil)
            }, .unsupportedTarget)
            XCTAssertEqual(FileManager.default.contents(atPath: existing), Data([1]), "the existing file is unchanged")
            let cancelled = TestToken()
            cancelled.isCancellationRequested = true
            XCTAssertEqual(mapped { try masker.detect(image: image, cancellation: cancelled) }, .cancelled)
            let wrongPlan = try FaceBlurCore.MaskPlan(width: 10, height: 10, masks: [])
            XCTAssertEqual(mapped { try masker.applyMasks(image: image, plan: wrongPlan, cancellation: nil) },
                           .maskPlanMismatch)
            masker.close()
            XCTAssertEqual(mapped { try masker.detect(image: image, cancellation: nil) }, .closed)
        }
    }

    /// `concurrentUse` cannot be reached through the facade: the actor runs its calls one after another (see
    /// `testEightTasksOnOneMaskerAreSerialised`). The mapping is checked with a direct library masker: a first call
    /// is held inside the library (its token's first poll waits) while a second call starts on this thread.
    func testConcurrentUseFromALibraryMaskerCalledFromTwoThreads() throws {
        try Runtime.check()
        let model = try load(try Fixture.modelData(), sha: Fixture.yunetSha256)
        let masker = KotlinRef(try FaceBlurCore.FaceMasker(model: model, config: try FaceBlurCore.FaceMaskerConfig(
            masking: try FaceBlurCore.MaskingConfig(style: .gradientOval, shape: .ellipse, expandX: 1.6,
                                                    expandY: 1.8, feather: 0.1, color: Int32(bitPattern: 0xFF7F_7F7F)),
            onnxThreads: 0)))
        defer { masker.value.close() }
        var px = [UInt8](repeating: 0xFF, count: 64 * 64 * 4)
        try px.withUnsafeMutableBytes { raw in
            let image = KotlinRef(try FaceBlurIos.shared.wrapRgba(
                address: Int64(Int(bitPattern: raw.baseAddress)), width: 64, height: 64, bytesPerRow: 256,
                layout: .rgbaNoneSkip))
            let held = HoldingToken(), done = DispatchSemaphore(value: 0), first = ErrorBox()
            DispatchQueue.global().async {
                do { _ = try masker.value.detect(image: image.value, cancellation: held) } catch { first.error = error }
                done.signal()
            }
            XCTAssertEqual(held.entered.wait(timeout: .now() + 60), .success, "the first call is inside the library")
            XCTAssertEqual(mapped { try masker.value.detect(image: image.value, cancellation: nil) }, .concurrentUse)
            held.release.signal()
            XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
            XCTAssertNil(first.error, "the first call completes")
        }
    }

    func testAsyncFormTurnsCancelledIntoCancellationError() {
        let cancelled = FaceBlurCore.KotlinException(message: "x").asError()
        XCTAssertEqual(FaceMaskError.forAsync(cancelled) as? FaceMaskError, .internal)
        XCTAssertTrue(FaceMaskError.forAsync(FaceMaskError.cancelled) is CancellationError)
        XCTAssertTrue(FaceMaskError.forAsync(CancellationError()) is CancellationError)
        XCTAssertEqual(FaceMaskError.forAsync(FaceMaskError.closed) as? FaceMaskError, .closed)
    }

    func testUnknownErrorsBecomeInternal() {
        XCTAssertEqual(FaceMaskError.from(NSError(domain: "other", code: 1)), .internal)
        XCTAssertEqual(FaceMaskError.from(FaceBlurCore.KotlinException(message: "not a FaceBlur error").asError()),
                       .internal)
        XCTAssertEqual(FaceMaskError.from(kotlin: NSObject()), .internal)
    }

    /// Messages are fixed text plus numbers: no path, no file name, no library text.
    func testDescriptionsCarryNoPathOrPixelData() {
        let all: [FaceMaskError] = [
            .invalidConfiguration(parameter: "expandX"), .imageTooLarge(width: 1, height: 2, limit: 3),
            .sourceTooLarge(limitBytes: 4), .notEnoughMemory, .unsupportedImage, .unsupportedTarget, .ioFailed,
            .outputValidationFailed(findings: ["A"]), .maskPlanMismatch, .sourceChanged, .maskWriteFailed,
            .modelIntegrity, .modelRejected(findings: ["B"]), .modelOutputInvalid(findings: ["C"]),
            .runtimeUnavailable, .concurrentUse, .closed, .cancelled, .internal,
        ]
        XCTAssertEqual(all.count, 19, "one case per library exception")
        XCTAssertEqual(Set(all.map(\.description)).count, 19)
        for e in all {
            XCTAssertFalse(e.description.replacingOccurrences(of: "I/O", with: "").contains("/"), e.description)
            XCTAssertFalse(e.description.isEmpty)
        }
    }
}

/// A library cancellation token for direct library calls in the tests.
final class TestToken: NSObject, CancellationToken, @unchecked Sendable {
    var isCancellationRequested: Bool = false
}

/// A token whose first poll signals `entered` and waits for `release` (it is polled on the library's calling thread).
final class HoldingToken: NSObject, CancellationToken, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private var polled = false
    var isCancellationRequested: Bool {
        if !polled {
            polled = true
            entered.signal()
            release.wait()
        }
        return false
    }
}

/// The first call's error, written on its thread before `done` is signalled and read after the wait.
final class ErrorBox: @unchecked Sendable {
    var error: (any Error)?
}
