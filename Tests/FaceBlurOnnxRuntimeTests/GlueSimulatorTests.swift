// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import FaceBlurCore
@testable import FaceBlurOnnxRuntime
import FaceBlurOrtShim
import FaceBlurOrtShimTestSupport
import Foundation
import ImageIO
import XCTest

/// ST-004 (simulator parts) and ST-027: the Kotlin library through the glue and ONNX Runtime 1.20.0 on the iOS
/// simulator. The model and the fixtures are not part of the package; their paths come from the test environment
/// (TEST_RUNNER_FACEBLUR_MODEL: the pinned YuNet file; TEST_RUNNER_FACEBLUR_TESTDATA: the faceblur `testdata` folder
/// with the registered public fixtures). The simulator reads them from the host.
final class GlueSimulatorTests: XCTestCase {
    private static let yunetSha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
    private static let names = ["cls_8", "cls_16", "cls_32", "obj_8", "obj_16", "obj_32", "bbox_8", "bbox_16",
                                "bbox_32", "kps_8", "kps_16", "kps_32"]

    override class func setUp() {
        super.setUp()
        PrivateTemp.install() // before any NSTemporaryDirectory() call of this process
        _ = FaceBlurIos.shared.registerOnnxRuntime(factory: OnnxRuntimeGlueFactory())
    }

    private func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name], "set TEST_RUNNER_\(name)")
    }

    private func modelData() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: try env("FACEBLUR_MODEL"))) }

    private func testdata() throws -> URL { URL(fileURLWithPath: try env("FACEBLUR_TESTDATA")) }

    /// The model loaded from memory: one copy into the library, never a file.
    private func loadModel(threshold: Float) throws -> DetectorModel {
        let profile = try DetectorProfile.Builder()
            .format(value: DetectionFormat.YuNetLayout())
            .inputSize(width: 640, height: 640)
            .scoreThreshold(value: threshold)
            .expectedSha256(value: Self.yunetSha256)
            .build()
        let data = try modelData()
        let source = try data.withUnsafeBytes { raw in
            try FaceBlurIos.shared.modelSourceFromMemory(
                address: Int64(Int(bitPattern: raw.baseAddress)), byteCount: Int64(raw.count))
        }
        return try DetectorModel.companion.load(
            source: source, profile: profile, maxModelBytes: DetectorModel.companion.DEFAULT_MAX_MODEL_BYTES)
    }

    /// A fixture drawn into a BGRA premultiplied bitmap context (a typical app buffer).
    private func context(for url: URL) throws -> CGContext {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx
    }

    /// The fixture's decoded bytes as they are (no colour conversion), in an RGBX buffer the caller frees.
    private func rawRgbx(_ url: URL) throws -> (UnsafeMutableRawPointer, Int, Int) {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
        let data = try XCTUnwrap(img.dataProvider?.data)
        let base = try XCTUnwrap(CFDataGetBytePtr(data))
        let w = img.width, h = img.height, bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
        XCTAssertEqual(img.bitsPerComponent, 8)
        XCTAssertFalse(img.bitmapInfo.contains(.byteOrder32Little))
        let offset = [.first, .noneSkipFirst].contains(img.alphaInfo) ? 1 : 0
        let out = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
        let o = out.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let p = base + y * bpr + x * bpp + offset
                let q = o + (y * w + x) * 4
                q[0] = p[0]; q[1] = p[1]; q[2] = p[2]; q[3] = 0xFF
            }
        }
        return (out, w, h)
    }

    // ST-004 AC1/AC2/AC3/AC4 (simulator), ST-027 AC1 (functional part), AC5, privacy by construction.
    func testInPlaceMaskingThroughTheGlueWritesNoFile() throws {
        let fixture = try testdata().appendingPathComponent("pd/pd-p01-s025-x00938-y00610.png")
        let ctx = try context(for: fixture)
        let before = FileSnapshot.take()
        let model = try loadModel(threshold: 0.5)
        let masker = try FaceMasker(model: model, config: try FaceMaskerConfig.Builder().build())
        XCTAssertEqual(masker.modelInfo.runtimeVersion, "1.20.0")
        XCTAssertEqual(masker.modelInfo.executionProvider, "XNNPACK")

        let base = try XCTUnwrap(ctx.data)
        let count = ctx.bytesPerRow * ctx.height
        let original = Data(bytes: base, count: count)
        let image = try FaceBlurIos.shared.wrapRgba(
            address: Int64(Int(bitPattern: base)), width: Int32(ctx.width), height: Int32(ctx.height),
            bytesPerRow: Int32(ctx.bytesPerRow), layout: .bgraPremultiplied)
        let result = try masker.maskInPlace(image: image, cancellation: nil)
        masker.close()

        XCTAssertGreaterThanOrEqual(result.faces.count, 1)
        XCTAssertTrue(result.faces.allSatisfy { $0.score >= 0.5 && $0.score <= 1 })
        XCTAssertEqual(result.masks.count, result.faces.count)
        let px = base.assumingMemoryBound(to: UInt8.self)
        var changed = 0
        for i in 0..<count where px[i] != original[i] { changed += 1 }
        XCTAssertGreaterThan(changed, 0, "the caller's buffer holds the masks")
        for m in result.masks {
            let o = Int(m.centerY) * ctx.bytesPerRow + Int(m.centerX) * 4
            XCTAssertEqual(px[o + 3], 0xFF, "opaque mask interior")
            XCTAssertNotEqual(Data(bytes: px + o, count: 3), original.subdata(in: o..<(o + 3)), "covered")
        }
        // Pixels far from every mask are untouched.
        for y in stride(from: 0, to: ctx.height, by: 7) {
            for x in stride(from: 0, to: ctx.width, by: 7) {
                let far = result.masks.allSatisfy { m in
                    let dx = (Float(x) - m.centerX) / (m.radiusX * 2), dy = (Float(y) - m.centerY) / (m.radiusY * 2)
                    return dx * dx + dy * dy > 1
                }
                guard far else { continue }
                let o = y * ctx.bytesPerRow + x * 4
                XCTAssertEqual(Data(bytes: px + o, count: 4), original.subdata(in: o..<(o + 4)), "(\(x),\(y))")
            }
        }
        XCTAssertEqual(FileSnapshot.difference(before, FileSnapshot.take()), [],
                       "no file created, removed or resized by load, creation, call")
        try FileSnapshot.assertSeesHostFolders()
    }

    // ADR 0010 (telemetry amendment): a failing DisableTelemetryEvents fails closed with status 7 (option failed),
    // releases the environment and hands out none, so no session can be created; with the switch working, the
    // environment is created normally.
    func testAFailingTelemetrySwitchIsStatus7AndNoEnvironment() {
        var handedOut: Int32 = -1, created: Int32 = -1, released: Int32 = -1
        XCTAssertEqual(fb_ort_test_create_env(1, &handedOut, &created, &released), Int32(FB_ORT_OPTION_FAILED))
        XCTAssertEqual(FB_ORT_OPTION_FAILED, 7)
        XCTAssertEqual(handedOut, 0, "no environment handed out")
        XCTAssertEqual(created, 1)
        XCTAssertEqual(released, 1, "the environment whose telemetry could not be disabled is released")

        XCTAssertEqual(fb_ort_test_create_env(0, &handedOut, &created, &released), Int32(FB_ORT_OK))
        XCTAssertEqual(handedOut, 1)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(released, 1, "released by the test support after the check")
    }

    // ADR 0009 tier 2 on the simulator: boxes against the OpenCV reference of the committed fixtures.
    func testBoxesMatchTheOpenCVReference() throws {
        let dir = try testdata()
        let ref = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("yunet_reference.json"))) as? [String: Any])
        let threshold = try XCTUnwrap(ref["scoreThreshold"] as? Double)
        let delta = try XCTUnwrap(ref["marginDelta"] as? Double)
        let masker = try FaceMasker(model: try loadModel(threshold: Float(threshold)),
                                    config: try FaceMaskerConfig.Builder().build())
        defer { masker.close() }
        func iou(_ a: [Double], _ b: [Double]) -> Double {
            let w = max(0, min(a[2], b[2]) - max(a[0], b[0])), h = max(0, min(a[3], b[3]) - max(a[1], b[1]))
            let inter = w * h
            let union = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
            return union > 0 ? inter / union : 0
        }
        var compared = 0
        for entry in try XCTUnwrap(ref["images"] as? [[String: Any]]) {
            let file = try XCTUnwrap(entry["file"] as? String)
            let (buf, w, h) = try rawRgbx(dir.appendingPathComponent(file))
            defer { buf.deallocate() }
            let image = try FaceBlurIos.shared.wrapRgba(
                address: Int64(Int(bitPattern: buf)), width: Int32(w), height: Int32(h), bytesPerRow: Int32(w * 4),
                layout: .rgbaNoneSkip)
            let ours = try masker.detect(image: image, cancellation: nil).faces.map {
                ([Double($0.left), Double($0.top), Double($0.right), Double($0.bottom)], Double($0.score))
            }
            let theirs = try XCTUnwrap(entry["faces"] as? [[String: Any]]).map { f -> ([Double], Double) in
                let x = f["x"] as! Double, y = f["y"] as! Double, fw = f["w"] as! Double, fh = f["h"] as! Double
                let box = [max(0, x), max(0, y), min(Double(w), x + fw), min(Double(h), y + fh)]
                return (box, f["score"] as! Double)
            }
            for (box, score) in theirs where score >= threshold + delta {
                XCTAssertTrue(ours.contains { iou($0.0, box) >= 0.99 }, "\(file): reference box \(box) unmatched")
                compared += 1
            }
            for (box, score) in ours where score >= threshold + delta {
                XCTAssertTrue(theirs.contains { iou($0.0, box) >= 0.99 }, "\(file): our box \(box) unmatched")
            }
        }
        XCTAssertGreaterThan(compared, 0)
    }

    // ADR 0010 "Bounds" and status codes, straight on the glue.
    func testTheGlueAnswersBadArgumentsWithStatusCodes() throws {
        let glue = OnnxRuntimeGlue()
        XCTAssertEqual(glue.runtimeVersion(), "1.20.0")
        XCTAssertEqual(OnnxBridgeCompanion.shared.OUTPUT_ROW_LONGS, Int32(OnnxRuntimeGlue.rowLongs))
        let shape = KotlinLongArray(size: 4)
        for (i, v) in [1, 3, 640, 640].enumerated() { shape.set(index: Int32(i), value: Int64(v)) }
        XCTAssertEqual(glue.run(inputAddress: 8, inputByteCount: 4, outputTableAddress: 8), 4, "not open")
        let model = try modelData()
        func open(_ bytes: Data, input: String = "input", outputs: [String] = Self.names, shape s: KotlinLongArray? = nil) -> Int32 {
            bytes.withUnsafeBytes { raw in
                glue.open(modelAddress: Int64(Int(bitPattern: raw.baseAddress)), modelByteCount: Int64(raw.count),
                          threads: 0, inputName: input, inputShape: s ?? shape, outputNames: outputs)
            }
        }
        XCTAssertEqual(glue.open(modelAddress: 0, modelByteCount: 10, threads: 0, inputName: "input",
                                 inputShape: shape, outputNames: Self.names), 5, "null model")
        XCTAssertEqual(open(Data([1, 2, 3, 4])), 1, "not a model")
        XCTAssertEqual(open(model, input: "other"), 6)
        XCTAssertEqual(open(model, outputs: Array(Self.names.reversed())), 6)
        XCTAssertEqual(open(model, outputs: []), 5)
        XCTAssertEqual(open(model, shape: KotlinLongArray(size: 3)), 5)
        XCTAssertEqual(open(model), 0)
        XCTAssertEqual(glue.executionProvider(), "XNNPACK")

        let bytes = 3 * 640 * 640 * 4
        let input = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        input.initializeMemory(as: Float.self, repeating: 0.5, count: bytes / 4)
        let cap = 1 << 20
        let bufs = Self.names.map { _ in UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16) }
        defer { input.deallocate(); bufs.forEach { $0.deallocate() } }
        var table = [Int64](repeating: 0, count: Self.names.count * 9)
        func run(byteCount: Int = bytes, capacity: Int = cap) -> Int32 {
            for i in Self.names.indices {
                table[i * 9] = Int64(Int(bitPattern: bufs[i]))
                table[i * 9 + 1] = Int64(capacity)
                table[i * 9 + 2] = -1
            }
            return table.withUnsafeMutableBufferPointer { t in
                glue.run(inputAddress: Int64(Int(bitPattern: input)), inputByteCount: Int64(byteCount),
                         outputTableAddress: Int64(Int(bitPattern: t.baseAddress)))
            }
        }
        XCTAssertEqual(run(byteCount: bytes - 4), 5, "wrong input size")
        XCTAssertEqual(glue.run(inputAddress: 0, inputByteCount: Int64(bytes), outputTableAddress: 8), 5)
        XCTAssertEqual(run(capacity: 16), 3, "buffers too small")
        XCTAssertEqual(table[4], 3, "rank written also with status 3")
        XCTAssertEqual(table[2], -1, "nothing claimed as written")
        XCTAssertEqual(run(), 0)
        for i in Self.names.indices {
            let r = Array(table[(i * 9)..<(i * 9 + 9)])
            XCTAssertEqual(r[3], 1, "float32")
            let dims = r[5..<(5 + Int(r[4]))].reduce(1, *)
            XCTAssertEqual(r[2], dims * 4, Self.names[i])
        }
        glue.close()
        XCTAssertEqual(run(), 4, "closed")
        glue.close()
    }
}
