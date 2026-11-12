// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// The four pixel layouts of the library (ADR 0004 decision 2), as a Swift value that can cross to the masker's queue.
enum PixelLayout: Sendable {
    case rgbaPremultiplied, rgbaNoneSkip, bgraPremultiplied, bgraNoneSkip

    var kotlin: IosPixelLayout {
        switch self {
        case .rgbaPremultiplied: .rgbaPremultiplied
        case .rgbaNoneSkip: .rgbaNoneSkip
        case .bgraPremultiplied: .bgraPremultiplied
        case .bgraNoneSkip: .bgraNoneSkip
        }
    }
}

/// A caller-owned buffer described by primitives only: no reference to the caller's object crosses the queue hop.
/// The caller's object is kept alive by the calling method for the duration of the call (ADR 0004 caller obligation:
/// no other code touches the buffer during the call).
struct BufferDescription: Sendable {
    let address: Int64, width: Int32, height: Int32, bytesPerRow: Int32, layout: PixelLayout
    /// Set for `CVPixelBuffer`s (decision 4a rule 1a): ``wrap()`` first checks that every alpha byte is 255.
    var alphaMustBeOpaque = false
    /// How a viewer turns the stored pixels (1 to 8, `CGImagePropertyOrientation`); the library sees the upright view.
    var orientation: Int32 = 1

    /// Wraps the buffer for one library call, seen upright. Called only inside the masker's queue block, so the alpha
    /// scan of a pixel buffer runs there too, never on the caller's thread.
    func wrap() throws(FaceMaskError) -> MutablePixelImage {
        if alphaMustBeOpaque { try checkOpaque() }
        return try kotlinCall {
            try FaceBlurIos.shared.wrapRgba(address: address, width: width, height: height, bytesPerRow: bytesPerRow,
                                            layout: layout.kotlin, orientation: orientation)
        }
    }

    /// Any alpha byte below 255 is `unsupportedImage`, with the buffer untouched (an image with transparency is
    /// refused, never repaired). Padding is never read.
    private func checkOpaque() throws(FaceMaskError) {
        Hooks.alphaScan()
        guard let base = UnsafePointer<UInt8>(bitPattern: Int(address)) else { throw .unsupportedImage }
        let width = Int(width), bytesPerRow = Int(bytesPerRow)
        for y in 0..<Int(height) {
            let row = base + y * bytesPerRow
            for x in 0..<width where row[x * 4 + 3] != 0xFF { throw .unsupportedImage }
        }
    }
}

/// ADR 0011 decision 4a: the layout of a buffer, from its declaration, failing closed.
enum Carriers {
    /// Rule 1 for `CGContext`: 8-bit RGB, 32 bits per pixel; the alpha form and byte order pick the layout. Anything
    /// else is `unsupportedImage` before a pixel is read or written. Premultiplied data is then checked by the
    /// library (rule 2) on every call.
    static func describe(_ context: CGContext) throws(FaceMaskError) -> BufferDescription {
        guard let data = context.data, context.bitsPerComponent == 8, context.bitsPerPixel == 32,
              context.colorSpace?.model == .rgb, context.width > 0, context.height > 0,
              context.bitmapInfo.intersection(.floatInfoMask).isEmpty
        else { throw .unsupportedImage }
        let order = context.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder32Little
        let big = order == .byteOrder32Big || order.rawValue == 0
        let layout: PixelLayout
        switch context.alphaInfo {
        case .premultipliedLast where big: layout = .rgbaPremultiplied
        case .premultipliedFirst where little: layout = .bgraPremultiplied
        case .noneSkipLast where big: layout = .rgbaNoneSkip
        case .noneSkipFirst where little: layout = .bgraNoneSkip
        default: throw .unsupportedImage
        }
        return try describe(data, context.width, context.height, context.bytesPerRow, layout)
    }

    /// ``describe(_:)`` with the orientation a viewer applies (the library sees the upright view).
    static func describe(_ context: CGContext, _ orientation: CGImagePropertyOrientation) throws(FaceMaskError)
        -> BufferDescription {
        var d = try describe(context)
        d.orientation = number(orientation)
        return d
    }

    /// Rule 1 and 1a for `CVPixelBuffer` (locked by the caller): `32BGRA` / `32RGBA` only, never a premultiplied
    /// layout. Every alpha byte must be 255 (an opaque image); that full read pass is left to
    /// ``BufferDescription/wrap()`` on the masker's queue. Only the cheap checks run here.
    static func describe(locked buffer: CVPixelBuffer) throws(FaceMaskError) -> BufferDescription {
        let layout: PixelLayout
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_32BGRA: layout = .bgraNoneSkip
        case kCVPixelFormatType_32RGBA: layout = .rgbaNoneSkip
        default: throw .unsupportedImage
        }
        guard !CVPixelBufferIsPlanar(buffer), let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw .unsupportedImage
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, bytesPerRow >= width * 4 else { throw .unsupportedImage }
        var d = try describe(base, width, height, bytesPerRow, layout)
        d.alphaMustBeOpaque = true
        return d
    }

    /// The orientation's EXIF number, 1 to 8 (`CGImagePropertyOrientation` is a closed enum of exactly those values;
    /// the library checks the range again).
    static func number(_ orientation: CGImagePropertyOrientation) -> Int32 { Int32(orientation.rawValue) }

    private static func describe(_ base: UnsafeMutableRawPointer, _ width: Int, _ height: Int, _ bytesPerRow: Int,
                                 _ layout: PixelLayout) throws(FaceMaskError) -> BufferDescription {
        guard let w = Int32(exactly: width), let h = Int32(exactly: height), let bpr = Int32(exactly: bytesPerRow)
        else { throw .unsupportedImage }
        return BufferDescription(address: Int64(Int(bitPattern: base)), width: w, height: h, bytesPerRow: bpr,
                                 layout: layout)
    }
}

/// A buffer owned by the library for `FaceMasker.mask(_:orientation:)` and `FaceMasker.encodeJPEG(_:quality:)`: the
/// image drawn upright (its orientation applied), `premultipliedFirst`, 32-bit little-endian, onto cleared memory with
/// the copy blend mode, so every pixel of the canvas has exactly the source's alpha. The library then refuses the
/// canvas unless every pixel is opaque (decision 4a: an image with transparency is refused, never repaired). The
/// returned image is a no-copy view over it, declared without alpha, which frees the buffer when it is released.
struct OwnedCanvas {
    static let drawInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        .union(.byteOrder32Little)
    static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        .union(.byteOrder32Little)

    let base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int

    /// `poison` is a test hook only: it fills the fresh buffer with that byte before it is cleared, so a test can prove
    /// that no earlier memory content (an opaque alpha byte in particular) survives under a transparent source pixel.
    static func draw(_ image: CGImage, orientation: Int32 = 1, poison: UInt8? = nil) throws(FaceMaskError)
        -> OwnedCanvas {
        let turned = orientation >= 5
        let width = turned ? image.height : image.width, height = turned ? image.width : image.height
        let (bytesPerRow, overflow) = width.multipliedReportingOverflow(by: 4)
        let (count, overflow2) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard (1...8).contains(orientation), width > 0, height > 0, !overflow, !overflow2,
              Int32(exactly: width) != nil, Int32(exactly: height) != nil, Int32(exactly: bytesPerRow) != nil
        else { throw .unsupportedImage }
        guard let base = malloc(count) else { throw .notEnoughMemory }
        if let poison { memset(base, Int32(poison), count) }
        memset(base, 0, count)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: drawInfo.rawValue)
        else {
            free(base)
            throw .unsupportedImage
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.concatenate(upright(orientation, rawWidth: CGFloat(image.width), rawHeight: CGFloat(image.height)))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return OwnedCanvas(base: base, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// The transform that shows a raw image of `rawWidth` x `rawHeight` (drawn at the origin) upright in a bitmap
    /// context (origin bottom-left): raw pixel (x, y) (top-left origin) lands on upright pixel (u, v) of the EXIF table
    /// 1 (x, y); 2 (W-x, y); 3 (W-x, H-y); 4 (x, H-y); 5 (y, x); 6 (H-y, x); 7 (H-y, W-x); 8 (y, W-x).
    static func upright(_ orientation: Int32, rawWidth w: CGFloat, rawHeight h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
    }

    /// The canvas for the library: premultiplied, so the library checks that every pixel is opaque.
    var description: BufferDescription {
        BufferDescription(address: Int64(Int(bitPattern: base)), width: Int32(width), height: Int32(height),
                          bytesPerRow: Int32(bytesPerRow), layout: .bgraPremultiplied)
    }

    /// Hands the buffer to a no-copy image; after this call the image owns it. Every pixel is opaque (the library
    /// checked it), so the image is declared without alpha.
    func image() throws(FaceMaskError) -> CGImage {
        let release: CGDataProviderReleaseDataCallback = { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }
        guard let provider = CGDataProvider(dataInfo: nil, data: base, size: bytesPerRow * height,
                                            releaseData: release)
        else {
            free(base)
            throw .notEnoughMemory
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: space, bitmapInfo: Self.bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw .internal }
        return image
    }

    func discard() { free(base) }
}
