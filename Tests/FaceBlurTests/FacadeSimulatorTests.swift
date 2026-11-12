// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
@testable import FaceBlur
import Foundation
import ImageIO
import XCTest

/// ST-031 / ADR 0011 on the simulator through the real ONNX Runtime 1.20.0: masking, the alpha rules of decision 4a,
/// cancellation, serialisation, lifetime, "only FaceMaskError crosses" and the nothing-written snapshot.
final class FacadeSimulatorTests: XCTestCase {
    // Before any NSTemporaryDirectory() call of this process (see PrivateTemp).
    override class func setUp() {
        super.setUp()
        PrivateTemp.install()
    }

    // ST-031 AC2 (in-memory) and ADR 0011 decision 4 (model from Data in one copy); privacy by construction.
    func testModelFromDataInOneCopyMasksInPlaceAndWritesNoFile() async throws {
        let before = FileSnapshot.take()
        let copies = Hooks.modelCopies
        let masker = try await Fixture.masker()
        XCTAssertEqual(Hooks.modelCopies - copies, 1, "the model crosses in one copy")
        XCTAssertEqual(masker.modelInfo.runtimeVersion, "1.20.0")
        XCTAssertEqual(masker.modelInfo.faceBlurVersion, Runtime.expectedLibraryVersion)
        XCTAssertEqual(masker.modelInfo.model.sha256, Fixture.yunetSha256)

        let image = try Fixture.image()
        let ctx = try Fixture.context(image)
        let original = Fixture.bytes(ctx)
        let detection = try await masker.detect(try Fixture.context(image))
        let result = try await masker.maskInPlace(ctx)
        // The caller still owns the context and can draw into it after the call (compile and run check).
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)

        XCTAssertGreaterThanOrEqual(result.faces.count, 1)
        XCTAssertEqual(result.faces, detection.faces, "async detect and maskInPlace see the same faces")
        XCTAssertEqual(result.masks.count, result.faces.count)
        let after = Fixture.bytes(ctx)
        XCTAssertNotEqual(after, original, "the caller's buffer holds the masks")
        for m in result.masks {
            let o = Int(m.centerY) * ctx.bytesPerRow + Int(m.centerX) * 4
            XCTAssertEqual(after[o + 3], 0xFF, "opaque mask interior")
            XCTAssertNotEqual(after.subdata(in: o..<(o + 3)), original.subdata(in: o..<(o + 3)), "covered")
        }
        // The same plan through applyMasks on a fresh copy gives the same pixels.
        let again = try Fixture.context(image)
        let plan = try detection.toMaskPlan()
        _ = try await masker.applyMasks(plan, to: again)
        XCTAssertEqual(Fixture.bytes(again), after, "applyMasks(detect plan) == maskInPlace")
        masker.close()

        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take()), [], "no file created, removed or resized")
        try FileSnapshot.assertSeesHostFolders()
    }

    func testModelFromFileURLAndRefusals() async throws {
        let started = Hooks.scopesStarted, stopped = Hooks.scopesStopped
        let model = try await DetectorModel(source: .file(try Fixture.modelURL()), profile: try Fixture.profile())
        XCTAssertEqual(model.info.sha256, Fixture.yunetSha256)
        XCTAssertEqual(Hooks.scopesStarted - started, Hooks.scopesStopped - stopped, "every started scope stopped")
        await assertThrows(.invalidConfiguration(parameter: "source")) {
            try await DetectorModel(source: .file(URL(string: "https://example.invalid/model.onnx")!),
                                    profile: try Fixture.profile())
        }
        await assertThrows(.invalidConfiguration(parameter: "maxModelBytes")) {
            try await DetectorModel(source: .data(try Fixture.modelData()), profile: try Fixture.profile(),
                                    maxModelBytes: 0)
        }
        await assertThrows(.invalidConfiguration(parameter: "maxModelBytes")) {
            try await DetectorModel(source: .data(try Fixture.modelData()), profile: try Fixture.profile(),
                                    maxModelBytes: 1_000)
        }
        await assertThrows(.ioFailed) {
            try await DetectorModel(source: .file(URL(fileURLWithPath: NSTemporaryDirectory() + "no-\(UUID())")),
                                    profile: try Fixture.profile())
        }
        await assertThrows(.modelIntegrity) {
            try await DetectorModel(source: .data(try Fixture.modelData()), profile: try DetectorProfile(
                format: .yuNetLayout, inputWidth: 640, inputHeight: 640, scoreThreshold: 0.5,
                expectedSHA256: String(repeating: "a", count: 64)))
        }
    }

    // Decision 4a rule 1a (alpha rule of 2026-11-11): only opaque pixel buffers are masked; alpha 0 everywhere, one
    // byte of 128 or one byte of 254 -> unsupportedImage, buffer unchanged.
    func testPixelBufferThatIsNotOpaqueIsRefusedUntouched() async throws {
        let masker = try await Fixture.masker()
        let image = try Fixture.image()
        let opaque = try Fixture.pixelBuffer(image, alpha: 0xFF)
        let masked = try await masker.maskInPlace(opaque)
        XCTAssertGreaterThanOrEqual(masked.faces.count, 1, "an opaque buffer is masked")

        let zero = try Fixture.pixelBuffer(image, alpha: 0)
        var buffers = [("alpha 0 everywhere", zero)]
        for value: UInt8 in [128, 254] {
            let pb = try Fixture.pixelBuffer(image, alpha: 0xFF)
            CVPixelBufferLockBaseAddress(pb, [])
            let px = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            px[CVPixelBufferGetBytesPerRow(pb) * 300 + 300 * 4 + 3] = value
            CVPixelBufferUnlockBaseAddress(pb, [])
            buffers.append(("one alpha byte \(value)", pb))
        }
        for (name, pb) in buffers {
            let before = Fixture.bytes(pb)
            await assertThrows(.unsupportedImage) { try await masker.maskInPlace(pb) }
            await assertThrows(.unsupportedImage) { try await masker.detect(pb) }
            await assertThrows(.unsupportedImage) { try await masker.maskInPlace(pb, orientation: .right) }
            XCTAssertEqual(Fixture.bytes(pb), before, name)
        }
        var other: CVPixelBuffer?
        CVPixelBufferCreate(nil, 8, 8, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &other)
        await assertThrows(.unsupportedImage) { try await masker.maskInPlace(other!) }
    }

    // Decision 4a rule 2: a premultiplied context with pixels that are not opaque (here alpha 0, colour above it) is
    // refused, unchanged.
    func testInvalidPremultipliedContextIsRefusedUntouched() async throws {
        let masker = try await Fixture.masker()
        let ctx = try Fixture.context(try Fixture.image())
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<ctx.height { for x in 0..<ctx.width { px[y * ctx.bytesPerRow + x * 4 + 3] = 0 } }
        let before = Fixture.bytes(ctx)
        await assertThrows(.unsupportedImage) { try await masker.maskInPlace(ctx) }
        await assertThrows(.unsupportedImage) { try await masker.detect(ctx) }
        XCTAssertEqual(Fixture.bytes(ctx), before)
        // Unsupported declarations fail before any pixel is touched.
        let gray = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        await assertThrows(.unsupportedImage) { try await masker.maskInPlace(gray) }
        let swapped = try Fixture.context(try Fixture.image(), alpha: .premultipliedLast, order: .byteOrder32Little)
        await assertThrows(.unsupportedImage) { try await masker.maskInPlace(swapped) }
    }

    // Decision 4a rule 1: premultiplied and skip contexts in both byte orders are masked.
    func testEveryAcceptedContextFormIsMasked() async throws {
        let masker = try await Fixture.masker()
        let image = try Fixture.image()
        let forms: [(CGImageAlphaInfo, CGBitmapInfo)] = [
            (.premultipliedFirst, .byteOrder32Little), (.premultipliedLast, .byteOrder32Big),
            (.noneSkipFirst, .byteOrder32Little), (.noneSkipLast, .byteOrder32Big),
        ]
        var counts: [Int] = []
        for (alpha, order) in forms {
            let ctx = try Fixture.context(image, alpha: alpha, order: order)
            let r = try await masker.maskInPlace(ctx)
            XCTAssertGreaterThanOrEqual(r.faces.count, 1, "\(alpha.rawValue)")
            counts.append(r.faces.count)
        }
        XCTAssertEqual(Set(counts).count, 1, "the same faces in every form: \(counts)")
    }

    // Decision 4a rule 4 (alpha rule of 2026-11-11): mask(CGImage) refuses an image with any pixel that is not
    // opaque - no black fill, no repair - and returns nothing; an opaque image is masked and comes back without alpha.
    func testMaskCGImageRefusesAnyPixelThatIsNotOpaque() async throws {
        let masker = try await Fixture.masker()
        let ctx = try Fixture.context(try Fixture.image(), alpha: .premultipliedLast, order: .byteOrder32Big)
        let opaqueBytes = [UInt8](Fixture.bytes(ctx))
        let bpr = ctx.bytesPerRow, w = ctx.width, h = ctx.height
        func image(_ bytes: [UInt8], _ alpha: CGImageAlphaInfo) -> CGImage {
            CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                    provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                    intent: .defaultIntent)!
        }
        var one = opaqueBytes
        one[(h / 2) * bpr + (w / 2) * 4 + 3] = 254
        var transparent = opaqueBytes
        for i in stride(from: 3, to: transparent.count, by: 4) { transparent[i] = 0 }
        var stripe = opaqueBytes // a face-coloured stripe hidden under alpha 0, as in a straight-alpha source
        for y in 0..<16 { for x in 0..<w { stripe[y * bpr + x * 4 + 3] = 0 } }
        for (name, img) in [("one pixel at alpha 254, premultiplied", image(one, .premultipliedLast)),
                            ("one pixel at alpha 254, straight", image(one, .last)),
                            ("fully transparent", image(transparent, .premultipliedLast)),
                            ("hidden stripe, straight alpha", image(stripe, .last))] {
            do {
                _ = try await masker.mask(img)
                XCTFail("\(name): expected unsupportedImage")
            } catch let e as FaceMaskError {
                XCTAssertEqual(e, .unsupportedImage, name)
            }
            await assertThrows(.unsupportedImage) { try await masker.mask(img, orientation: .left) }
        }

        // A format with an alpha channel whose pixels are all opaque is masked.
        let (out, result) = try await masker.mask(image(opaqueBytes, .premultipliedLast))
        XCTAssertGreaterThanOrEqual(result.faces.count, 1, "the opaque face is masked")
        XCTAssertEqual(out.alphaInfo, .noneSkipFirst, "no alpha in the returned image")
        XCTAssertEqual([out.width, out.height], [w, h])
    }

    /// Decision 4a rule 4 without depending on fresh memory being zero: the canvas buffer is poisoned (0xAB, an
    /// alpha byte that is not 255 but also not 0) and must still carry the transparent source's alpha 0, so the
    /// library refuses it.
    func testCanvasCarriesTheSourceAlphaOverPoisonedMemory() throws {
        for poison: UInt8 in [0xAB, 0xFF] {
            let clear = CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: CGDataProvider(data: Data(count: 32 * 128) as CFData)!, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)!
            let canvas = try OwnedCanvas.draw(clear, poison: poison)
            defer { canvas.discard() }
            let bytes = UnsafeRawBufferPointer(start: canvas.base, count: canvas.bytesPerRow * canvas.height)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                XCTAssertEqual([bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]], [0, 0, 0, 0], "pixel \(i / 4)")
            }
            XCTAssertThrowsError(try canvas.description.wrap()) { XCTAssertEqual($0 as? FaceMaskError, .unsupportedImage) }
        }
    }

    func testPlanMismatchCloseAndOnlyFaceMaskErrorCrosses() async throws {
        let masker = try await Fixture.masker()
        let ctx = try Fixture.context(try Fixture.image())
        let before = Fixture.bytes(ctx)
        let wrong = try MaskPlan(width: 10, height: 10, masks: [])
        await assertThrows(.maskPlanMismatch) { try await masker.applyMasks(wrong, to: ctx) }
        XCTAssertEqual(Fixture.bytes(ctx), before)
        await assertThrows(.invalidConfiguration(parameter: "source")) {
            try await masker.detectFile(at: URL(string: "https://example.invalid/a.jpg")!)
        }
        await assertThrows(.invalidConfiguration(parameter: "target")) {
            try await masker.maskFile(at: try Fixture.url(Fixture.face),
                                      to: .newFile(URL(string: "https://example.invalid/b.jpg")!))
        }
        // An unbound plan is refused before the source is opened (the source does not even exist).
        await assertThrows(.maskPlanMismatch) {
            try await masker.maskFile(at: URL(fileURLWithPath: NSTemporaryDirectory() + "absent-\(UUID()).jpg"),
                                      to: .overwriteSource, plan: try MaskPlan(width: 640, height: 640, masks: []))
        }
        masker.close()
        masker.close() // idempotent
        await assertThrows(.closed) { try await masker.maskInPlace(ctx) }
        await assertThrows(.closed) { try await masker.mask(try Fixture.image()) }
        XCTAssertEqual(Fixture.bytes(ctx), before)
    }

    // ST-031 AC5: eight tasks on one masker complete without concurrentUse (the actor serialises them).
    func testEightTasksOnOneMaskerAreSerialised() async throws {
        let masker = try await Fixture.masker()
        let image = try Fixture.image()
        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    let ctx = try Fixture.context(image)
                    return try await masker.maskInPlace(ctx).faces.count
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(counts.count, 8)
        XCTAssertEqual(Set(counts).count, 1, "\(counts)")
    }

    // ST-031 AC3: a task cancelled while its call waits on the masker's queue gets CancellationError from the
    // library's token (not from the check before the hop); the buffer is untouched or fully masked.
    func testCancellationReachesTheLibraryAndLeavesTheBufferUntouchedOrFullyMasked() async throws {
        let masker = try await Fixture.masker()
        let image = try Fixture.image()
        let reference = try Fixture.context(image)
        let original = Fixture.bytes(reference)
        _ = try await masker.maskInPlace(reference)
        let masked = Fixture.bytes(reference)
        XCTAssertNotEqual(masked, original)
        func call(cancelFirst: Bool) -> Task<(Data, Bool), any Error> {
            Task {
                let ctx = try Fixture.context(image)
                if cancelFirst { withUnsafeCurrentTask { $0?.cancel() } }
                do {
                    _ = try await masker.maskInPlace(ctx)
                    return (Fixture.bytes(ctx), false)
                } catch is CancellationError {
                    return (Fixture.bytes(ctx), true)
                }
            }
        }

        // Cancelled before the call: stopped before the hop, untouched.
        let (early, earlyCancelled) = try await call(cancelFirst: true).value
        XCTAssertTrue(earlyCancelled)
        XCTAssertEqual(early, original)

        // Cancelled while the call waits behind a block on the masker's queue.
        let gate = DispatchSemaphore(value: 0)
        masker.enqueueForTesting { gate.wait() }
        let hops = Hooks.hopsEnqueued
        let task = call(cancelFirst: false)
        let deadline = Date().addingTimeInterval(60)
        while Hooks.hopsEnqueued == hops, Date() < deadline { try await Task.sleep(nanoseconds: 1_000_000) }
        let reachedQueue = Hooks.hopsEnqueued > hops
        task.cancel()
        gate.signal()
        XCTAssertTrue(reachedQueue, "the call was waiting on the masker's queue when it was cancelled")
        let (bytes, cancelled) = try await task.value
        XCTAssertTrue(cancelled, "CancellationError through the library's cancellation token")
        XCTAssertTrue(bytes == original || bytes == masked, "untouched or fully masked")
    }

    // MEDIUM-1 (review 061) / ADR 0011 decision 4: with a main-actor caller, the pixel buffer's alpha scan runs on
    // the masker's queue, not on the main thread.
    @MainActor
    func testPixelBufferAlphaScanDoesNotRunOnTheMainThread() async throws {
        let masker = try await Fixture.masker()
        let pb = try Fixture.pixelBuffer(try Fixture.image(), alpha: 0xFF)
        let scans = Hooks.alphaScans, onMain = Hooks.alphaScansOnMain
        dispatchPrecondition(condition: .onQueue(.main)) // the caller really is on the main thread
        _ = try await masker.detect(pb)
        _ = try await masker.maskInPlace(pb)
        XCTAssertEqual(Hooks.alphaScans - scans, 2, "one alpha scan per call")
        XCTAssertEqual(Hooks.alphaScansOnMain - onMain, 0, "no alpha scan on the main thread")
    }

    // ST-031 file mode (ADR 0005) through the library's iOS file mode: the only new file is the masked JPEG, without
    // the source's GPS, TIFF and EXIF entries; the source is unchanged; a plan from detectFile, a plan edited with
    // withMasks and a PlanMasker plan (no model) give the same masks.
    func testMaskFileWritesOnlyTheMaskedOutputWithoutMetadata() async throws {
        let masker = try await Fixture.masker()
        let out = try Fixture.outputFolder()
        defer { try? FileManager.default.removeItem(atPath: out) }
        let source = URL(fileURLWithPath: out + "/source.jpg")
        try Fixture.writeJpegWithMetadata(try Fixture.image(), to: source)
        XCTAssertNotNil(try Fixture.properties(source)[kCGImagePropertyGPSDictionary as String], "the source has GPS")
        let sourceBytes = try Data(contentsOf: source)
        let before = FileSnapshot.take(extra: [out])

        let detection = try await masker.detectFile(at: source)
        XCTAssertGreaterThanOrEqual(detection.faces.count, 1)
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [out])), [],
                       "detectFile writes nothing")
        let target = URL(fileURLWithPath: out + "/masked.jpg")
        let result = try await masker.maskFile(at: source, to: .newFile(target))
        XCTAssertEqual(result.faces, detection.faces, "detectFile and maskFile see the same faces")
        XCTAssertEqual(result.masks.count, result.faces.count)
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [out])), [target.path],
                       "the masked output is the only new file")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "the source is unchanged")
        let written = try Data(contentsOf: target)
        XCTAssertEqual(Int64(written.count), result.outputBytes)
        XCTAssertEqual(written.prefix(2), Data([0xFF, 0xD8]), "a JPEG")
        let props = try Fixture.properties(target)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String], "no GPS in the output")
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[
            kCGImagePropertyTIFFMake as String])
        XCTAssertNil((props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[
            kCGImagePropertyExifUserComment as String])
        XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? Int) ?? 1, 1, "orientation 1")

        let plan = try detection.toMaskPlan()
        let viaPlan = try await masker.maskFile(at: source, to: .newFile(URL(fileURLWithPath: out + "/plan.jpg")),
                                                plan: plan)
        XCTAssertEqual(viaPlan.masks, result.masks, "maskFile(plan: detect plan) == maskFile")
        let edited = try plan.withMasks(Array(plan.masks.prefix(1)))
        let viaEdit = try await masker.maskFile(at: source, to: .newFile(URL(fileURLWithPath: out + "/edit.jpg")),
                                                plan: edited)
        XCTAssertEqual(viaEdit.masks, Array(result.masks.prefix(1)), "an edited plan is applied as edited")
        masker.close()

        let planMasker = PlanMasker()
        let filePlan = try await planMasker.planFile(at: source)
        XCTAssertEqual([filePlan.width, filePlan.height], [detection.width, detection.height])
        let viaPlanMasker = try await planMasker.maskFile(
            at: source, to: .newFile(URL(fileURLWithPath: out + "/plan-masker.jpg")),
            plan: try filePlan.withMasks(plan.masks))
        XCTAssertEqual(viaPlanMasker.masks, result.masks, "PlanMasker writes the same masks")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "the source is still unchanged")
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [out])),
                       ["edit.jpg", "masked.jpg", "plan-masker.jpg", "plan.jpg"].map { out + "/" + $0 })
        try FileSnapshot.assertSeesHostFolders(extra: [out])
    }

    // ST-031 file mode refusals: an existing target without replaceExisting, and a folder that allows no file next
    // to the target (ADR 0005 decision 2), are `unsupportedTarget` and write nothing; overwriteSource replaces only
    // the source.
    func testFileModeTargetsRefusalsAndOverwriteSource() async throws {
        let masker = try await Fixture.masker()
        defer { masker.close() }
        let fm = FileManager.default
        let out = try Fixture.outputFolder()
        let locked = out + "/read-only"
        try fm.createDirectory(atPath: locked, withIntermediateDirectories: false)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked)
            try? fm.removeItem(atPath: out)
        }
        let source = URL(fileURLWithPath: out + "/source.jpg")
        try Fixture.writeJpegWithMetadata(try Fixture.image(), to: source)
        let existing = URL(fileURLWithPath: out + "/existing.jpg")
        try Data([1, 2, 3]).write(to: existing)
        let lockedExisting = locked + "/existing.jpg"
        XCTAssertTrue(fm.createFile(atPath: lockedExisting, contents: Data([4, 5, 6])))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked)
        let sourceBytes = try Data(contentsOf: source)
        let before = FileSnapshot.take(extra: [out])

        await assertThrows(.unsupportedTarget) { try await masker.maskFile(at: source, to: .newFile(existing)) }
        await assertThrows(.unsupportedTarget) {
            try await masker.maskFile(at: source, to: .newFile(URL(fileURLWithPath: locked + "/new.jpg")))
        }
        await assertThrows(.unsupportedTarget) {
            try await masker.maskFile(at: source, to: .newFile(URL(fileURLWithPath: lockedExisting),
                                                               replaceExisting: true))
        }
        await assertThrows(.unsupportedTarget) {
            try await PlanMasker().maskFile(at: source, to: .newFile(existing),
                                            plan: try await PlanMasker().planFile(at: source))
        }
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take(extra: [out])), [], "nothing written")
        XCTAssertEqual(try Data(contentsOf: existing), Data([1, 2, 3]))
        XCTAssertEqual(fm.contents(atPath: lockedExisting), Data([4, 5, 6]))
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)

        let replaced = try await masker.maskFile(at: source, to: .newFile(existing, replaceExisting: true))
        XCTAssertGreaterThanOrEqual(replaced.faces.count, 1)
        XCTAssertEqual(try Data(contentsOf: existing).prefix(2), Data([0xFF, 0xD8]), "replaced by the masked JPEG")
        let overwritten = try await masker.maskFile(at: source, to: .overwriteSource)
        XCTAssertEqual(overwritten.masks, replaced.masks)
        let now = try Data(contentsOf: source)
        XCTAssertNotEqual(now, sourceBytes, "the source holds the masked output")
        XCTAssertEqual(Int64(now.count), overwritten.outputBytes)
        XCTAssertNil(try Fixture.properties(source)[kCGImagePropertyGPSDictionary as String], "no GPS after overwrite")
        let changed = FileSnapshot.difference(before, FileSnapshot.take(extra: [out]))
        XCTAssertTrue(Set(changed).isSubset(of: [existing.path, source.path]), "no other file: \(changed)")
        try FileSnapshot.assertSeesHostFolders(extra: [out])
    }
}
