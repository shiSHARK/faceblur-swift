// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import CoreVideo
@testable import FaceBlur
import Foundation
import ImageIO
import XCTest

/// Fixtures for the facade tests. The model and the images are not part of the package; their paths come from the
/// test environment (TEST_RUNNER_FACEBLUR_MODEL: the pinned YuNet file; TEST_RUNNER_FACEBLUR_TESTDATA: the faceblur
/// `testdata` folder with the registered public fixtures). The simulator reads them from the host.
enum Fixture {
    static let yunetSha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
    static let face = "pd/pd-p01-s025-x00938-y00610.png"

    static func env(_ name: String) throws -> String {
        try XCTUnwrap(ProcessInfo.processInfo.environment[name], "set TEST_RUNNER_\(name)")
    }

    static func modelURL() throws -> URL { URL(fileURLWithPath: try env("FACEBLUR_MODEL")) }
    static func modelData() throws -> Data { try Data(contentsOf: try modelURL()) }
    static func url(_ relative: String) throws -> URL {
        URL(fileURLWithPath: try env("FACEBLUR_TESTDATA")).appendingPathComponent(relative)
    }

    /// A new, empty output folder of the test under the process's private temporary directory (``PrivateTemp``).
    static func outputFolder() throws -> String {
        PrivateTemp.assertActive()
        let out = NSTemporaryDirectory() + "faceblur-out-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: false)
        return out
    }

    /// Writes `image` as a JPEG with GPS, TIFF and EXIF entries (orientation 1), as a camera file would have.
    static func writeJpegWithMetadata(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let props: [String: Any] = [
            kCGImagePropertyOrientation as String: 1,
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 1.5, kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 2.5, kCGImagePropertyGPSLongitudeRef as String: "E",
            ],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "FaceBlurTest"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifUserComment as String: "FaceBlurTest"],
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// The primary image's properties as ImageIO reads them.
    static func properties(_ url: URL) throws -> [String: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
    }

    static func image(_ relative: String = face) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(try url(relative) as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    static func profile(threshold: Float = 0.5) throws -> DetectorProfile {
        try DetectorProfile(format: .yuNetLayout, inputWidth: 640, inputHeight: 640, scoreThreshold: threshold,
                            expectedSHA256: yunetSha256)
    }

    static func model() async throws -> DetectorModel {
        try await DetectorModel(source: .data(try modelData()), profile: try profile())
    }

    static func masker() async throws -> FaceMasker {
        try await FaceMasker(model: try await model())
    }

    /// `image` drawn into a new bitmap context of the given form, scaled to `size` (default: the image's size).
    static func context(_ image: CGImage, alpha: CGImageAlphaInfo = .premultipliedFirst,
                        order: CGBitmapInfo = .byteOrder32Little, size: Int? = nil) throws -> CGContext {
        let w = size ?? image.width, h = size ?? image.height
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue | order.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx
    }

    static func bytes(_ ctx: CGContext) -> Data { Data(bytes: ctx.data!, count: ctx.bytesPerRow * ctx.height) }

    /// `image` in a new `32BGRA` / `32RGBA` pixel buffer with every alpha byte set to `alpha`.
    static func pixelBuffer(_ image: CGImage, format: OSType = kCVPixelFormatType_32BGRA,
                            alpha: UInt8) throws -> CVPixelBuffer {
        // CVPixelBufferCreateWithBytes: the simulator does not allocate every format (32RGBA) itself.
        let rowBytes = image.width * 4 + 128 // padding that must never be read
        let memory = UnsafeMutableRawPointer.allocate(byteCount: rowBytes * image.height, alignment: 64)
        memory.initializeMemory(as: UInt8.self, repeating: 0x5A, count: rowBytes * image.height)
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreateWithBytes(
            nil, image.width, image.height, format, memory, rowBytes, { _, base in base?.deallocate() }, nil, nil, &pb)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bpr = CVPixelBufferGetBytesPerRow(buffer)
        let info = format == kCVPixelFormatType_32BGRA
            ? CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx = try XCTUnwrap(CGContext(
            data: base, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let px = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<image.height { for x in 0..<image.width { px[y * bpr + x * 4 + 3] = alpha } }
        return buffer
    }

    static func bytes(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return Data(bytes: CVPixelBufferGetBaseAddress(buffer)!,
                    count: CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
}

/// Asserts that `body` throws exactly `expected` (a ``FaceMaskError``), and that nothing else crosses.
func assertThrows<T>(_ expected: FaceMaskError, file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected), but the call completed", file: file, line: line)
    } catch let e as FaceMaskError {
        XCTAssertEqual(e, expected, file: file, line: line)
    } catch {
        XCTFail("only FaceMaskError may cross, got \(type(of: error))", file: file, line: line)
    }
}
