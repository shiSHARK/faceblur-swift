// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
@testable import FaceBlur
import Foundation
import ImageIO
import UIKit
import XCTest

/// The additive in-memory API (ADR 0011): the orientation forms of the `CGContext`, `CVPixelBuffer` and `CGImage`
/// calls, the opaque-only alpha rule for images that have an alpha channel, and `FaceMasker.encodeJPEG`. Simulator,
/// real ONNX Runtime 1.20.0, registered public fixtures only.
final class AdditiveApiTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        PrivateTemp.install()
    }

    static let orientations: [CGImagePropertyOrientation] = [
        .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
    ]

    // MARK: Orientation helpers (independent of the facade: the EXIF table, checked against ImageIO below)

    /// The upright pixel (u, v) at which a viewer shows raw pixel (x, y) of a `w` x `h` image (EXIF table).
    static func shownAt(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ o: UInt32) -> (Int, Int) {
        switch o {
        case 1: (x, y)
        case 2: (w - 1 - x, y)
        case 3: (w - 1 - x, h - 1 - y)
        case 4: (x, h - 1 - y)
        case 5: (y, x)
        case 6: (h - 1 - y, x)
        case 7: (h - 1 - y, w - 1 - x)
        default: (y, w - 1 - x)
        }
    }

    /// Opaque RGBA bytes (R, G, B, 255; no padding) of `image`.
    static func rgba(_ image: CGImage) throws -> [UInt8] {
        let ctx = try Fixture.context(image, alpha: .premultipliedLast, order: .byteOrder32Big)
        let all = [UInt8](Fixture.bytes(ctx)), row = image.width * 4
        return (0..<image.height).flatMap { y in all[(y * ctx.bytesPerRow)..<(y * ctx.bytesPerRow + row)] }
    }

    /// The stored (raw) pixels that a viewer applying `o` shows as `upright` (`uw` x `uh`): RGBA, no padding.
    static func raw(_ upright: [UInt8], _ uw: Int, _ uh: Int, _ o: UInt32) -> (bytes: [UInt8], w: Int, h: Int) {
        let w = o >= 5 ? uh : uw, h = o >= 5 ? uw : uh
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (u, v) = shownAt(x, y, w, h, o)
                for k in 0..<4 { out[(y * w + x) * 4 + k] = upright[(v * uw + u) * 4 + k] }
            }
        }
        return (out, w, h)
    }

    static func image(_ bytes: [UInt8], _ w: Int, _ h: Int,
                      alpha: CGImageAlphaInfo = .premultipliedLast) -> CGImage {
        CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
                provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent)!
    }

    /// The helper above agrees with ImageIO: a lossless TIFF of the raw pixels tagged with the orientation, decoded
    /// with the transform applied, shows the upright pixels.
    func testTheRawHelperAgreesWithImageIO() throws {
        let uw = 5, uh = 3
        var upright = [UInt8]()
        for i in 0..<(uw * uh) { upright += [UInt8(i * 16), UInt8(255 - i * 16), UInt8(i * 7), 255] }
        for o in 1...8 {
            let r = Self.raw(upright, uw, uh, UInt32(o))
            let data = NSMutableData()
            let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, Self.image(r.bytes, r.w, r.h, alpha: .noneSkipLast),
                                       [kCGImagePropertyOrientation as String: o] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
            let shown = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 64,
            ] as CFDictionary))
            XCTAssertEqual([shown.width, shown.height], [uw, uh], "o=\(o)")
            XCTAssertEqual(try Self.rgba(shown), upright, "ImageIO shows the upright pixels for o=\(o)")
        }
    }

    /// The facade's canvas draws a raw image upright for every orientation, pixel for pixel.
    func testTheCanvasDrawsEveryOrientationUpright() throws {
        let uw = 7, uh = 4
        var upright = [UInt8]()
        for i in 0..<(uw * uh) { upright += [UInt8(i * 9), UInt8(200 - i * 5), UInt8(i * 3 + 1), 255] }
        for o in Self.orientations {
            let r = Self.raw(upright, uw, uh, o.rawValue)
            let canvas = try OwnedCanvas.draw(Self.image(r.bytes, r.w, r.h), orientation: Int32(o.rawValue))
            defer { canvas.discard() }
            XCTAssertEqual([canvas.width, canvas.height], [uw, uh], "o=\(o.rawValue)")
            let b = UnsafeRawBufferPointer(start: canvas.base, count: canvas.bytesPerRow * canvas.height)
            for i in 0..<(uw * uh) {
                // Canvas bytes are B, G, R, A.
                XCTAssertEqual([b[i * 4 + 2], b[i * 4 + 1], b[i * 4], b[i * 4 + 3]],
                               Array(upright[(i * 4)..<(i * 4 + 4)]), "o=\(o.rawValue) pixel \(i)")
            }
        }
    }

    // MARK: Orientation through the facade

    /// For all 8 orientations, a fixture face stored turned or mirrored is detected on the upright view and masked:
    /// in a `CGContext` and a `CVPixelBuffer` (in place, through the view) and through `mask(_:orientation:)`
    /// (upright copy). Each result equals the result of the upright fixture with `.up`: the same faces and masks in
    /// upright coordinates, and the same masked pixels at the place a viewer shows them.
    func testEveryOrientationMasksTheFaceInEveryInMemoryForm() async throws {
        let masker = try await Fixture.masker()
        let fixture = try Fixture.image()
        let uw = fixture.width, uh = fixture.height
        let upright = try Self.rgba(fixture)
        let uprightImage = Self.image(upright, uw, uh)

        // References: the upright pixels with .up, in the same carrier forms.
        let refCtx = try Self.context(upright, uw, uh)
        let refResult = try await masker.maskInPlace(refCtx)
        XCTAssertGreaterThanOrEqual(refResult.faces.count, 1, "the fixture face is found upright")
        let refBytes = Self.rgbaOf(refCtx)
        XCTAssertNotEqual(refBytes, upright, "the reference is masked")
        for m in refResult.masks {
            let o = (Int(m.centerY) * uw + Int(m.centerX)) * 4
            XCTAssertNotEqual(Array(refBytes[o..<(o + 3)]), Array(upright[o..<(o + 3)]), "the face is covered")
        }
        let (refImage, refImageResult) = try await masker.mask(uprightImage)
        let refImageBytes = try Self.rgba(refImage)

        for o in Self.orientations {
            let n = o.rawValue
            let r = Self.raw(upright, uw, uh, n)

            // CGContext, in place.
            let ctx = try Self.context(r.bytes, r.w, r.h)
            let detected = try await masker.detect(ctx, orientation: o)
            XCTAssertEqual(detected.faces, refResult.faces, "detect o=\(n)")
            XCTAssertEqual([detected.width, detected.height], [uw, uh], "upright size o=\(n)")
            let res = try await masker.maskInPlace(ctx, orientation: o)
            XCTAssertEqual(res.faces, refResult.faces, "faces o=\(n)")
            XCTAssertEqual(res.masks, refResult.masks, "masks o=\(n)")
            XCTAssertEqual(Self.raw(refBytes, uw, uh, n).bytes, Self.rgbaOf(ctx), "masked pixels, context o=\(n)")
            // applyMasks with the upright plan on a fresh raw copy gives the same pixels.
            let again = try Self.context(r.bytes, r.w, r.h)
            _ = try await masker.applyMasks(try detected.toMaskPlan(), to: again, orientation: o)
            XCTAssertEqual(Self.rgbaOf(again), Self.rgbaOf(ctx), "applyMasks o=\(n)")
            let expected = try refResult.faces.map { (f) throws(FaceMaskError) in
                try ExpectedFace(left: f.left, top: f.top, right: f.right, bottom: f.bottom)
            }
            let check = try await masker.checkProfile(try Self.context(r.bytes, r.w, r.h), orientation: o,
                                                      expectedFaces: expected)
            XCTAssertTrue(check.allFound, "checkProfile o=\(n)")

            // CVPixelBuffer (32BGRA), in place.
            let pb = try Fixture.pixelBuffer(Self.image(r.bytes, r.w, r.h), alpha: 0xFF)
            let pbResult = try await masker.maskInPlace(pb, orientation: o)
            XCTAssertEqual(pbResult.masks, refResult.masks, "masks, pixel buffer o=\(n)")
            XCTAssertEqual(Self.raw(refBytes, uw, uh, n).bytes, Self.rgbaOfBuffer(pb), "masked pixels, pixel buffer o=\(n)")

            // CGImage: the returned image is upright and equals the masked upright fixture.
            let (out, imageResult) = try await masker.mask(Self.image(r.bytes, r.w, r.h), orientation: o)
            XCTAssertEqual([out.width, out.height], [uw, uh], "upright output o=\(n)")
            XCTAssertEqual(imageResult.masks, refImageResult.masks, "masks, CGImage o=\(n)")
            XCTAssertEqual(try Self.rgba(out), refImageBytes, "masked pixels, CGImage o=\(n)")
        }
        // The forms without an orientation are `.up`.
        let plain = try Self.context(upright, uw, uh)
        let plainResult = try await masker.maskInPlace(plain)
        XCTAssertEqual(plainResult.masks, refResult.masks)
        XCTAssertEqual(Self.rgbaOf(plain), refBytes)
        // A plan of the stored size does not fit a turned view.
        let turned = try Self.context(Self.raw(upright, uw, uh, 6).bytes, uh, uw)
        if uw != uh {
            await assertThrows(.maskPlanMismatch) {
                try await masker.applyMasks(try MaskPlan(width: uh, height: uw, masks: []), to: turned,
                                            orientation: .right)
            }
        }
    }

    /// An opaque RGBA context (`premultipliedLast`, big-endian) holding `bytes`.
    static func context(_ bytes: [UInt8], _ w: Int, _ h: Int) throws -> CGContext {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        bytes.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        return ctx
    }

    static func rgbaOf(_ ctx: CGContext) -> [UInt8] { [UInt8](Fixture.bytes(ctx)) }

    /// The RGBA bytes (no padding) of a `32BGRA` pixel buffer.
    static func rgbaOfBuffer(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * bpr + x * 4, i = (y * w + x) * 4
                out[i] = p[o + 2]; out[i + 1] = p[o + 1]; out[i + 2] = p[o]; out[i + 3] = p[o + 3]
            }
        }
        return out
    }

    // MARK: A plan from detect is bound to its orientation

    /// The `width` x `height` RGBA block of `bytes` (`w` pixels wide, no padding) at (`x`, `y`).
    static func crop(_ bytes: [UInt8], _ w: Int, _ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [UInt8] {
        (y..<(y + height)).flatMap { row in bytes[((row * w + x) * 4)..<((row * w + x + width) * 4)] }
    }

    /// For every pair of the 8 orientations, on the fixture (not square) and on a square crop of it (where every
    /// orientation has the same size, so only the binding can refuse): a plan from `detect` with orientation `d` is
    /// refused by `applyMasks` with any other orientation `a`, in the `CGContext` and the `CVPixelBuffer` form, with
    /// the buffer byte-identical; the forms without an orientation are `.up`. With `a == d` it masks as
    /// `maskInPlace` does. An edited plan keeps the binding; a plan from the public initialiser has none.
    func testAPlanFromDetectIsAppliedOnlyWithItsOrientation() async throws {
        let masker = try await Fixture.masker()
        let fixture = try Fixture.image()
        let fw = fixture.width, fh = fixture.height
        let full = try Self.rgba(fixture)
        let face = try await masker.detect(try Self.context(full, fw, fh)).faces.first
        let f = try XCTUnwrap(face, "the fixture face is found upright")
        // A square and a non-square (3:4 of the shorter side) crop around the face.
        let side = min(fw, fh), short = side * 3 / 4
        let cx = Int((f.left + f.right) / 2), cy = Int((f.top + f.bottom) / 2)
        let sx = max(0, min(fw - side, cx - side / 2)), sy = max(0, min(fh - side, cy - side / 2))
        let square = Self.crop(full, fw, sx, sy, side, side)
        let ny = max(0, min(fh - short, cy - short / 2))
        let wide = Self.crop(full, fw, sx, ny, side, short)

        for (upright, uw, uh) in [(wide, side, short), (square, side, side)] {
            let raws = Self.orientations.map { Self.raw(upright, uw, uh, $0.rawValue) }
            for (di, d) in Self.orientations.enumerated() {
                let r = raws[di]
                let plan = try await masker.detect(try Self.context(r.bytes, r.w, r.h), orientation: d).toMaskPlan()
                XCTAssertFalse(plan.masks.isEmpty, "a mask d=\(d.rawValue) \(uw)x\(uh)")
                let edited = try plan.withMasks(plan.masks)
                for (ai, a) in Self.orientations.enumerated() where a != d {
                    let t = raws[ai], what = "d=\(d.rawValue) a=\(a.rawValue) \(uw)x\(uh)"
                    let ctx = try Self.context(t.bytes, t.w, t.h)
                    let before = Self.rgbaOf(ctx)
                    await assertThrows(.maskPlanMismatch) { try await masker.applyMasks(plan, to: ctx, orientation: a) }
                    await assertThrows(.maskPlanMismatch) {
                        try await masker.applyMasks(edited, to: ctx, orientation: a)
                    }
                    XCTAssertEqual(Self.rgbaOf(ctx), before, "context unchanged \(what)")
                    let pb = try Fixture.pixelBuffer(Self.image(t.bytes, t.w, t.h), alpha: 0xFF)
                    let pbBefore = Self.rgbaOfBuffer(pb)
                    await assertThrows(.maskPlanMismatch) { try await masker.applyMasks(plan, to: pb, orientation: a) }
                    XCTAssertEqual(Self.rgbaOfBuffer(pb), pbBefore, "pixel buffer unchanged \(what)")
                    if a == .up {
                        await assertThrows(.maskPlanMismatch) { try await masker.applyMasks(plan, to: ctx) }
                        await assertThrows(.maskPlanMismatch) { try await masker.applyMasks(plan, to: pb) }
                        XCTAssertEqual(Self.rgbaOf(ctx), before, "context unchanged, form without orientation \(what)")
                        XCTAssertEqual(Self.rgbaOfBuffer(pb), pbBefore, "pixel buffer unchanged, .up form \(what)")
                    }
                }
                // The same orientation masks exactly as maskInPlace does.
                let applied = try Self.context(r.bytes, r.w, r.h)
                let res = try await masker.applyMasks(plan, to: applied, orientation: d)
                XCTAssertEqual(res.masks, plan.masks, "masks d=\(d.rawValue)")
                let inPlace = try Self.context(r.bytes, r.w, r.h)
                _ = try await masker.maskInPlace(inPlace, orientation: d)
                XCTAssertEqual(Self.rgbaOf(applied), Self.rgbaOf(inPlace), "pixels d=\(d.rawValue) \(uw)x\(uh)")
                XCTAssertNotEqual(Self.rgbaOf(applied), r.bytes, "masked d=\(d.rawValue)")
                let pb = try Fixture.pixelBuffer(Self.image(r.bytes, r.w, r.h), alpha: 0xFF)
                let pbResult = try await masker.applyMasks(edited, to: pb, orientation: d)
                XCTAssertEqual(pbResult.masks, plan.masks, "edited plan, pixel buffer d=\(d.rawValue)")
                if d == .up { _ = try await masker.applyMasks(plan, to: try Self.context(r.bytes, r.w, r.h)) }
            }
            // A plan from the public initialiser applies with every orientation (size rule only).
            let masks = try await masker.detect(try Self.context(raws[5].bytes, raws[5].w, raws[5].h),
                                                orientation: Self.orientations[5]).toMaskPlan().masks
            let unbound = try MaskPlan(width: uw, height: uh, masks: masks)
            for (ai, a) in Self.orientations.enumerated() {
                let t = raws[ai]
                let ctx = try Self.context(t.bytes, t.w, t.h)
                let unboundResult = try await masker.applyMasks(unbound, to: ctx, orientation: a)
                XCTAssertEqual(unboundResult.masks, masks, "unbound plan a=\(a.rawValue)")
                XCTAssertNotEqual(Self.rgbaOf(ctx), t.bytes, "unbound plan masks a=\(a.rawValue)")
            }
        }
    }

    // MARK: The DocC orientation example of FaceMasker

    /// The class DocC "Orientation" example of `FaceMasker`, line for line (compiled here; the test below checks that
    /// the documentation holds the same lines).
    static func docExampleOrientation(_ photo: UIImage) -> CGImagePropertyOrientation? {
        var mapped: CGImagePropertyOrientation?
        func example() {
            let orientation: CGImagePropertyOrientation
            switch photo.imageOrientation {
            case .up: orientation = .up
            case .down: orientation = .down
            case .left: orientation = .left
            case .right: orientation = .right
            case .upMirrored: orientation = .upMirrored
            case .downMirrored: orientation = .downMirrored
            case .leftMirrored: orientation = .leftMirrored
            case .rightMirrored: orientation = .rightMirrored
            @unknown default: return // an orientation this code does not know: do not guess
            }
            mapped = orientation
        }
        example()
        return mapped
    }

    static let docExampleLines = [
        "let orientation: CGImagePropertyOrientation",
        "switch photo.imageOrientation {",
        "case .up: orientation = .up",
        "case .down: orientation = .down",
        "case .left: orientation = .left",
        "case .right: orientation = .right",
        "case .upMirrored: orientation = .upMirrored",
        "case .downMirrored: orientation = .downMirrored",
        "case .leftMirrored: orientation = .leftMirrored",
        "case .rightMirrored: orientation = .rightMirrored",
        "@unknown default: return // an orientation this code does not know: do not guess",
        "}",
    ]

    /// The example maps every orientation a `UIImage` gets from an image file's EXIF orientation (1-8, decoded by
    /// UIKit) back to that EXIF value, and the DocC text holds exactly the compiled lines.
    func testTheDocOrientationExampleMapsAllEightOrientations() throws {
        for o in 1...8 {
            let data = NSMutableData()
            let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.tiff" as CFString, 1, nil))
            CGImageDestinationAddImage(dest, Self.image([UInt8](repeating: 255, count: 6 * 4 * 4), 6, 4,
                                                        alpha: .noneSkipLast),
                                       [kCGImagePropertyOrientation as String: o] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            let photo = try XCTUnwrap(UIImage(data: data as Data))
            XCTAssertEqual(Self.docExampleOrientation(photo)?.rawValue, UInt32(o), "EXIF orientation \(o)")
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/FaceBlur/FaceMasker.swift")
        let doc = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
            .filter { $0.hasPrefix("///") }.map { $0.dropFirst(3).trimmingCharacters(in: .whitespaces) }
        let start = try XCTUnwrap(doc.firstIndex(of: Self.docExampleLines[0]), "the example is in the DocC text")
        XCTAssertEqual(Array(doc[start..<min(doc.count, start + Self.docExampleLines.count)]), Self.docExampleLines)
    }

    // MARK: Alpha: a format with alpha whose pixels are all opaque is masked

    /// The way apps commonly make a `CGImage` from a photo: `UIGraphicsImageRenderer` with its default format, which
    /// has an alpha channel (premultiplied). Every pixel of a drawn photo is opaque, so it must still be masked, in the
    /// `CGImage` form and in a premultiplied `CGContext`.
    func testAnOpaqueImageWithAnAlphaChannelIsMasked() async throws {
        let masker = try await Fixture.masker()
        let fixture = try Fixture.image()
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: fixture.width, height: fixture.height),
                                               format: format)
            .image { ctx in
                ctx.cgContext.translateBy(x: 0, y: CGFloat(fixture.height))
                ctx.cgContext.scaleBy(x: 1, y: -1)
                ctx.cgContext.draw(fixture, in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
            }
        let cg = try XCTUnwrap(rendered.cgImage)
        let alpha = cg.alphaInfo
        XCTAssertTrue(alpha == .premultipliedFirst || alpha == .premultipliedLast,
                      "the renderer's default format has alpha (\(alpha.rawValue))")
        let (out, result) = try await masker.mask(cg)
        XCTAssertGreaterThanOrEqual(result.faces.count, 1, "masked")
        XCTAssertEqual(out.alphaInfo, .noneSkipFirst)
        let (plain, plainResult) = try await masker.mask(fixture)
        XCTAssertEqual(result.masks, plainResult.masks, "the same masks as the image without alpha")
        XCTAssertEqual(try Self.rgba(out), try Self.rgba(plain))

        let ctx = try Fixture.context(cg, alpha: .premultipliedFirst, order: .byteOrder32Little)
        let inPlace = try await masker.maskInPlace(ctx)
        XCTAssertEqual(inPlace.masks, plainResult.masks, "premultiplied context with all pixels opaque")
    }

    // MARK: JPEG helper

    /// `encodeJPEG` returns a JPEG of the pixels only: no GPS, EXIF text, TIFF entries, XMP, ICC profile or
    /// auxiliary image, orientation 1, the image's size; it writes no file.
    func testEncodeJPEGIsInMemoryWithoutMetadata() async throws {
        let masker = try await Fixture.masker()
        // A source with a colour profile other than sRGB, to show that no profile is carried.
        let fixture = try Fixture.image()
        let p3 = try XCTUnwrap(CGContext(
            data: nil, width: fixture.width, height: fixture.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        p3.draw(fixture, in: CGRect(x: 0, y: 0, width: fixture.width, height: fixture.height))
        let source = try XCTUnwrap(p3.makeImage())
        let (masked, _) = try await masker.mask(source)

        let before = FileSnapshot.take()
        let jpeg = try await FaceMasker.encodeJPEG(masked)
        let lower = try await FaceMasker.encodeJPEG(masked, quality: 30)
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take()), [], "no file created, removed or resized")
        try FileSnapshot.assertSeesHostFolders()

        XCTAssertEqual(jpeg.prefix(3), Data([0xFF, 0xD8, 0xFF]))
        XCTAssertLessThan(lower.count, jpeg.count, "the quality reaches the encoder")
        let markers = Self.markers(jpeg)
        XCTAssertEqual(Array(markers.prefix(2)), [0xE0, 0xE1], "the fixed JFIF and the library's EXIF header")
        XCTAssertTrue(markers.dropFirst(2).allSatisfy { !(0xE0...0xEF).contains($0) && $0 != 0xFE },
                      "no other APPn (ICC profile, XMP, MPF) and no comment: \(markers)")
        XCTAssertNil(jpeg.range(of: Data("ICC_PROFILE".utf8)))
        XCTAssertNil(jpeg.range(of: Data("http://ns.adobe.com/xap/1.0/".utf8)))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 1, "one image")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertNil(props[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(props[kCGImagePropertyIPTCDictionary as String])
        // No profile is embedded (no APP2 above); ImageIO then reports its default for untagged JPEGs, never the
        // source's Display P3.
        XCTAssertNotEqual(props[kCGImagePropertyProfileName as String] as? String, "Display P3", "no source profile")
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[
            kCGImagePropertyTIFFMake as String])
        XCTAssertNil((props[kCGImagePropertyExifDictionary as String] as? [String: Any])?[
            kCGImagePropertyExifUserComment as String])
        XCTAssertEqual((props[kCGImagePropertyOrientation as String] as? Int) ?? 1, 1, "orientation 1")
        XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int, masked.width)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight as String] as? Int, masked.height)
        for type in [kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity,
                     kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type), "no auxiliary image")
        }
    }

    /// Refusals: quality outside 1 to 100 and any pixel that is not opaque, before anything is encoded; nothing on
    /// disk; and the output check's error crosses as `outputValidationFailed` (mapped from the library).
    func testEncodeJPEGRefusals() async throws {
        let before = FileSnapshot.take()
        let fixture = try Fixture.image()
        for q in [0, 100 + 1, -1] {
            await assertThrows(.invalidConfiguration(parameter: "quality")) {
                try await FaceMasker.encodeJPEG(fixture, quality: q)
            }
        }
        var bytes = try Self.rgba(fixture)
        bytes[(fixture.height / 2 * fixture.width + fixture.width / 2) * 4 + 3] = 254
        await assertThrows(.unsupportedImage) {
            try await FaceMasker.encodeJPEG(Self.image(bytes, fixture.width, fixture.height))
        }
        await assertThrows(.unsupportedImage) {
            try await FaceMasker.encodeJPEG(Self.image(bytes, fixture.width, fixture.height, alpha: .last))
        }
        // A side above the JPEG limit is refused (by the library; or earlier, if CoreGraphics cannot make the canvas).
        // The output check itself runs in the library; Kotlin iosTest `IosJpegTest.theOutputCheckFailsClosed` plants bad encoder
        // output there, and ErrorMappingTests maps `OutputValidationFailed`.
        let wide = Self.image([UInt8](repeating: 0xFF, count: 65_536 * 4), 65_536, 1)
        await assertThrows(.unsupportedImage) { try await FaceMasker.encodeJPEG(wide) }
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take()), [], "nothing written")
    }

    /// The markers of a JPEG's segments up to the first scan (SOS included).
    static func markers(_ jpeg: Data) -> [Int] {
        let b = [UInt8](jpeg)
        var out: [Int] = []
        var i = 2
        while i + 4 <= b.count, b[i] == 0xFF {
            let m = Int(b[i + 1])
            out.append(m)
            if m == 0xDA { break }
            i += 2 + (Int(b[i + 2]) << 8 | Int(b[i + 3]))
        }
        return out
    }
}
