// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import FaceBlurCore
@testable import FaceBlur
import FaceBlurOnnxRuntime
import Foundation
import ImageIO
import XCTest

/// A model run that never returns, inside the Swift glue. The library's own tests block in a Kotlin fake glue; here the
/// glue is Swift code behind the real `OnnxBridge` protocol (a wrapper around the production glue that waits on a
/// semaphore inside `run`, with no CPU, and goes on only when the test lets it). The tests check that
///  1. the masking call ends with the run-timeout error (`ModelOutputInvalid`, finding `RUN_TIMEOUT`, which the facade
///     maps to `FaceMaskError.modelOutputInvalid`) at the per-pass limit, not earlier and not much later;
///  2. nothing was written (the caller's buffer, or the folder in file mode), and the stuck glue is not closed under
///     its running call (the glue's `close()` waits for a stuck `run`, so a close from the calling thread would hang
///     the call past its limit);
///  3. the next call on the same masker runs on a new glue and gives the output of a normal masker;
///  4. when the stuck run returns, the library closes the abandoned glue itself.
/// The model and the fixture are not part of the package; their paths come from the test environment
/// (TEST_RUNNER_FACEBLUR_MODEL: the pinned YuNet file; TEST_RUNNER_FACEBLUR_TESTDATA: the faceblur `testdata` folder
/// with the registered public fixtures). The simulator reads them from the host.
///
/// Coverage limit: the tests drive the library's `FaceBlurCore.FaceMasker` and map the error with `FaceMaskError.from`
/// (the function the facade uses), not the public async `FaceBlur.FaceMasker`: the facade refuses every glue but its own,
/// so it cannot be driven with this test glue without a test seam. The facade's queue layer is therefore not covered in
/// the stuck case.
final class BlockingGlueTests: XCTestCase {
    private static let yunetSha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
    private static let fixture = "pd/pd-p01-s025-x00938-y00610.png"
    /// The smallest per-pass limit; the library takes the larger of this and twenty times the contract run.
    private static let minimumLimitMillis = 2_000.0
    private static let limitFactor = 20.0
    /// The library's own margin for "ended at the limit". It has to absorb the work before the pass starts and the
    /// garbage collection after the call (184 to 282 ms of it on the gate), so it is the likeliest source of a flaky
    /// upper bound on a loaded machine.
    private static let marginMillis = 1_000.0
    /// Allowance for the part of the contract run that the glue does not see (input fill, hand-over, decoding). It is
    /// multiplied by the limit factor, so once the contract run is above this value the upper bound loosens by up to
    /// about two seconds.
    private static let contractSlackMillis = 50.0

    private static let registered: Bool = {
        PrivateTemp.install() // before any NSTemporaryDirectory() call of this process
        return FaceBlurIos.shared.registerOnnxRuntime(factory: BlockingGlueFactory.shared)
    }()

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(Self.registered, "the blocking test glue is the process's registered glue")
        PrivateTemp.assertActive()
        BlockingGlueFactory.shared.reset()
        continueAfterFailure = false
    }

    // MARK: Fixtures

    private func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name], "set TEST_RUNNER_\(name)")
    }

    private func fixtureURL() throws -> URL {
        URL(fileURLWithPath: try env("FACEBLUR_TESTDATA")).appendingPathComponent(Self.fixture)
    }

    private func loadModel() throws -> FaceBlurCore.DetectorModel {
        let profile = try FaceBlurCore.DetectorProfile.Builder()
            .format(value: FaceBlurCore.DetectionFormat.YuNetLayout())
            .inputSize(width: 640, height: 640)
            .scoreThreshold(value: 0.5)
            .expectedSha256(value: Self.yunetSha256)
            .build()
        let data = try Data(contentsOf: URL(fileURLWithPath: try env("FACEBLUR_MODEL")))
        let source = try data.withUnsafeBytes { raw in
            try FaceBlurIos.shared.modelSourceFromMemory(
                address: Int64(Int(bitPattern: raw.baseAddress)), byteCount: Int64(raw.count))
        }
        return try FaceBlurCore.DetectorModel.companion.load(
            source: source, profile: profile,
            maxModelBytes: FaceBlurCore.DetectorModel.companion.DEFAULT_MAX_MODEL_BYTES)
    }

    private func newMasker(_ model: FaceBlurCore.DetectorModel) throws -> FaceBlurCore.FaceMasker {
        try FaceBlurCore.FaceMasker(model: model, config: try FaceBlurCore.FaceMaskerConfig.Builder().build())
    }

    /// The public fixture drawn into a new BGRA bitmap context (a typical app buffer).
    private func bitmap() throws -> CGContext {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(try fixtureURL() as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx
    }

    private func bytes(_ ctx: CGContext) throws -> Data {
        Data(bytes: try XCTUnwrap(ctx.data), count: ctx.bytesPerRow * ctx.height)
    }

    private func maskInPlace(_ masker: FaceBlurCore.FaceMasker, _ ctx: CGContext) throws -> Int {
        let image = try FaceBlurIos.shared.wrapRgba(
            address: Int64(Int(bitPattern: try XCTUnwrap(ctx.data))), width: Int32(ctx.width), height: Int32(ctx.height),
            bytesPerRow: Int32(ctx.bytesPerRow), layout: .bgraPremultiplied)
        return Int(try masker.maskInPlace(image: image, cancellation: nil).faces.count)
    }

    /// A new folder in the process's private temporary folder, with the fixture as `in.jpg` (a JPEG without metadata).
    private func folderWithJpeg() throws -> String {
        PrivateTemp.assertActive()
        let dir = NSTemporaryDirectory() + "faceblur-blocking-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = try bitmap()
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: dir + "/in.jpg") as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return dir
    }

    private func fileOptions() throws -> FaceBlurCore.FileOptions {
        try FaceBlurCore.FileOptions(
            maxLongSide: 3_500, maxOutputLongSide: 0, maxDecodedPixels: 25_000_000,
            format: try FaceBlurCore.OutputFormat.Jpeg(quality: 90), metadata: FaceBlurCore.MetadataPolicy.StripAll.shared)
    }

    private func maskFile(_ masker: FaceBlurCore.FaceMasker, _ dir: String, to target: FaceBlurCore.OutputTarget) throws {
        _ = try masker.maskFile(source: dir + "/in.jpg", target: target, options: try fileOptions(), plan: nil,
                                cancellation: nil)
    }

    private func names(_ dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    }

    // MARK: The stuck run

    /// Arms the next glue, makes the masker (creation and its contract run go through), and registers the teardown that
    /// lets the stuck run go on and closes the masker.
    private func stuckMasker(_ model: FaceBlurCore.DetectorModel) throws -> (FaceBlurCore.FaceMasker, StuckRun) {
        let stuck = StuckRun()
        BlockingGlueFactory.shared.arm(stuck)
        let masker = try newMasker(model)
        let handle = KotlinRef(masker)
        addTeardownBlock {
            stuck.letGo()
            handle.value.close()
        }
        XCTAssertEqual(stuck.runCount, 1, "creation ran the contract run only")
        XCTAssertEqual(BlockingGlueFactory.shared.gluesMade, 1)
        return (masker, stuck)
    }

    /// The limit window of the call that follows, from the glue's own measurement of the contract run.
    private func limitWindow(_ stuck: StuckRun) -> (lower: Double, upper: Double) {
        let lower = max(Self.minimumLimitMillis, Self.limitFactor * stuck.contractMillis.rounded(.down))
        let upper = max(Self.minimumLimitMillis, Self.limitFactor * (stuck.contractMillis + Self.contractSlackMillis))
        return (lower, upper + Self.marginMillis)
    }

    /// Runs `body`, which must throw; returns how long it took (milliseconds) and what it threw as the facade maps it.
    private func timedFailure(_ body: () throws -> Void) -> (millis: Double, error: FaceMaskError?, kotlin: Bool) {
        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try body()
            return (Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000, nil, false)
        } catch {
            let millis = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let isKotlin = (error as NSError).kotlinException is FaceBlurCore.FaceMaskException.ModelOutputInvalid
            return (millis, FaceMaskError.from(error), isKotlin)
        }
    }

    private func assertTimedOut(_ result: (millis: Double, error: FaceMaskError?, kotlin: Bool), _ stuck: StuckRun,
                                _ what: String) {
        let window = limitWindow(stuck)
        print("BLOCKING-GLUE \(what): contract run \(stuck.contractMillis) ms, call took \(result.millis) ms, "
              + "window \(window.lower) to \(window.upper) ms")
        XCTAssertEqual(result.error, .modelOutputInvalid(findings: ["RUN_TIMEOUT"]), what)
        XCTAssertTrue(result.kotlin, "the library threw FaceMaskException.ModelOutputInvalid")
        XCTAssertGreaterThanOrEqual(result.millis, window.lower, "\(what): not before the limit")
        XCTAssertLessThanOrEqual(result.millis, window.upper, "\(what): at the limit, not later")
        XCTAssertEqual(stuck.runCount, 2, "the stuck glue got one pass")
        XCTAssertEqual(stuck.closeAttempts, 0,
                       "nobody called close() on the stuck glue while its run holds the lock (a call from the calling "
                       + "thread would wait for the lock and the call could not end at its limit)")
        XCTAssertEqual(BlockingGlueFactory.shared.gluesMade, 1, "no replacement glue yet")
    }

    /// The stuck run goes on; the library closes the abandoned glue on its pass thread, exactly once.
    private func releaseAndExpectTheLibraryClosesTheGlue(_ stuck: StuckRun) {
        stuck.letGo()
        XCTAssertEqual(stuck.closed.wait(timeout: .now() + 10), .success,
                       "the abandoned glue is closed by the library once its run returned")
        XCTAssertEqual(stuck.closeAttempts, 1)
        XCTAssertEqual(stuck.closesFinished, 1)
    }

    // MARK: Tests

    func testAStuckSwiftRunEndsAnInPlaceCallAtItsLimitAndTheNextCallIsCorrect() throws {
        let model = try loadModel()
        let normal = try bitmap()
        let normalMasker = try newMasker(model)
        let normalFaces = try maskInPlace(normalMasker, normal)
        normalMasker.close()
        XCTAssertGreaterThanOrEqual(normalFaces, 1)
        XCTAssertNotEqual(try bytes(normal), try bytes(try bitmap()), "the normal masker changed the pixels")
        BlockingGlueFactory.shared.reset()

        let (masker, stuck) = try stuckMasker(model)
        let ctx = try bitmap()
        let before = try bytes(ctx)
        let first = timedFailure { _ = try maskInPlace(masker, ctx) }
        assertTimedOut(first, stuck, "in-place call")
        XCTAssertEqual(try bytes(ctx), before, "nothing was written into the caller's buffer")

        // The next call on the same masker: a new glue, the output of a normal masker.
        let faces = try maskInPlace(masker, ctx)
        XCTAssertEqual(BlockingGlueFactory.shared.gluesMade, 2, "the next call opened a new glue")
        XCTAssertEqual(stuck.runCount, 2, "the stuck glue never ran again")
        XCTAssertEqual(faces, normalFaces)
        XCTAssertEqual(try bytes(ctx), try bytes(normal), "the same pixels as a normal masker")

        releaseAndExpectTheLibraryClosesTheGlue(stuck)
        masker.close()
    }

    func testAStuckSwiftRunLeavesNoFileInNewFileModeAndTheNextCallWritesTheNormalFile() throws {
        let model = try loadModel()
        let dir = try folderWithJpeg()
        let input = try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg"))
        let normalMasker = try newMasker(model)
        try maskFile(normalMasker, dir, to: FaceBlurCore.OutputTarget.NewFile(path: dir + "/normal.jpg", replaceExisting: false))
        normalMasker.close()
        let normal = try Data(contentsOf: URL(fileURLWithPath: dir + "/normal.jpg"))
        try FileManager.default.removeItem(atPath: dir + "/normal.jpg")
        XCTAssertNotEqual(normal, input)
        BlockingGlueFactory.shared.reset()

        let (masker, stuck) = try stuckMasker(model)
        let before = FileSnapshot.take(extra: [dir])
        let first = timedFailure {
            try maskFile(masker, dir, to: FaceBlurCore.OutputTarget.NewFile(path: dir + "/out.jpg", replaceExisting: false))
        }
        assertTimedOut(first, stuck, "file call, new file")
        XCTAssertEqual(try names(dir), ["in.jpg"], "no output and no temporary file")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg")), input, "the source is unchanged")
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [dir])), [],
                       "nothing created, removed or resized anywhere the process could write")

        try maskFile(masker, dir, to: FaceBlurCore.OutputTarget.NewFile(path: dir + "/next.jpg", replaceExisting: false))
        XCTAssertEqual(BlockingGlueFactory.shared.gluesMade, 2, "the next call opened a new glue")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/next.jpg")), normal,
                       "the same file as a normal masker")
        XCTAssertEqual(try names(dir), ["in.jpg", "next.jpg"], "no temporary file after the next call")

        let beforeRelease = FileSnapshot.take(extra: [dir])
        releaseAndExpectTheLibraryClosesTheGlue(stuck)
        XCTAssertEqual(try names(dir), ["in.jpg", "next.jpg"], "the abandoned pass's late return wrote no file")
        XCTAssertEqual(FileSnapshot.difference(beforeRelease, FileSnapshot.take(extra: [dir])), [],
                       "nothing written after the stuck run was released")
        masker.close()
        try FileSnapshot.assertSeesHostFolders(extra: [dir])
    }

    func testAStuckSwiftRunLeavesTheSourceAloneInOverwriteMode() throws {
        let model = try loadModel()
        let dir = try folderWithJpeg()
        let input = try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg"))
        let normalMasker = try newMasker(model)
        try maskFile(normalMasker, dir, to: FaceBlurCore.OutputTarget.NewFile(path: dir + "/normal.jpg", replaceExisting: false))
        normalMasker.close()
        let normal = try Data(contentsOf: URL(fileURLWithPath: dir + "/normal.jpg"))
        try FileManager.default.removeItem(atPath: dir + "/normal.jpg")
        XCTAssertNotEqual(normal, input, "a normal masker changes the file, so \"source unchanged\" below is not vacuous")
        BlockingGlueFactory.shared.reset()

        let (masker, stuck) = try stuckMasker(model)
        let before = FileSnapshot.take(extra: [dir])
        let first = timedFailure { try maskFile(masker, dir, to: FaceBlurCore.OutputTarget.OverwriteSource.shared) }
        assertTimedOut(first, stuck, "file call, overwrite source")
        XCTAssertEqual(try names(dir), ["in.jpg"], "no temporary file next to the source")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg")), input,
                       "the source is unchanged: no partial output replaced it")
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [dir])), [], "nothing written anywhere")

        // The next call on the same masker overwrites the source with the masked output of a normal masker.
        try maskFile(masker, dir, to: FaceBlurCore.OutputTarget.OverwriteSource.shared)
        XCTAssertEqual(BlockingGlueFactory.shared.gluesMade, 2, "the next call opened a new glue")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg")), normal,
                       "the same file as a normal masker")
        XCTAssertEqual(try names(dir), ["in.jpg"], "no temporary file after the next call")

        let beforeRelease = FileSnapshot.take(extra: [dir])
        releaseAndExpectTheLibraryClosesTheGlue(stuck)
        XCTAssertEqual(try names(dir), ["in.jpg"], "the abandoned pass's late return left no temporary file")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/in.jpg")), normal,
                       "the source still holds the normal masker's output after the release")
        XCTAssertEqual(FileSnapshot.difference(beforeRelease, FileSnapshot.take(extra: [dir])), [],
                       "nothing written after the stuck run was released")
        masker.close()
    }
}
