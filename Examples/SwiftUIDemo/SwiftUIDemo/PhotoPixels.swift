// SPDX-License-Identifier: Apache-2.0
import CoreGraphics
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Pixel helpers that do not need FaceBlur: the upright drawing, bitmap contexts and the JPEG encoder.
enum PhotoPixels {
    /// The long side the demo works at (the library's default working size).
    static let maxLongSide: CGFloat = 3_500

    /// Draws the photo upright. `UIImage.cgImage` ignores `imageOrientation`, so the photo is drawn with
    /// `UIImage.draw`, which applies it (the FaceBlur DocC example). Photos with a long side above ``maxLongSide``
    /// are drawn smaller. Returns nil for a photo without size.
    static func uprightImage(from photo: UIImage) -> UIImage? {
        let size = photo.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = min(1, maxLongSide / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            photo.draw(in: CGRect(origin: .zero, size: target)) // draw applies imageOrientation
        }
    }

    /// A new 8-bit BGRA bitmap with the image drawn into it, the layout the FaceBlur in-memory calls take.
    static func makeContext(from image: CGImage) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }

    /// Encodes pixels as a JPEG from the pixels alone and rebuilds the file the way FaceBlur's file mode writes it:
    /// every application segment ImageIO adds (its Exif block, IPTC/Photoshop block, colour profile) and every
    /// comment is dropped, and the file starts with a fixed plain JFIF header and a fixed Exif block whose only
    /// entry is Orientation = 1 (the pixels are already upright). No properties are passed to the encoder. Returns
    /// nil if the encoder output cannot be parsed (the caller must then save nothing).
    static func jpegData(from image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return rebuilt(data as Data)
    }

    /// SOI, the fixed JFIF header, the fixed Exif block, then the encoder's non-application segments and the scan
    /// unchanged. Returns nil for anything that is not a well-formed JPEG ending in EOI.
    static func rebuilt(_ jpeg: Data) -> Data? {
        let bytes = [UInt8](jpeg)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8, Array(bytes.suffix(2)) == [0xFF, 0xD9] else {
            return nil
        }
        var out: [UInt8] = [0xFF, 0xD8] + fixedJFIF + fixedExif
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else { return nil }
            let marker = bytes[offset + 1]
            if marker == 0xDA { // start of scan: the rest is entropy-coded data and the end marker
                out.append(contentsOf: bytes[offset...])
                return Data(out)
            }
            let length = (Int(bytes[offset + 2]) << 8) + Int(bytes[offset + 3])
            let end = offset + 2 + length
            guard length >= 2, end <= bytes.count else { return nil }
            switch marker {
            case 0xE0...0xEF, 0xFE: break // application segments and comments are never copied
            default: out.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        return nil
    }

    /// JFIF 1.01, no density unit, 1 x 1, no thumbnail (18 bytes with the marker).
    static let fixedJFIF: [UInt8] = [0xFF, 0xE0, 0x00, 0x10] + Array("JFIF".utf8) + [0x00, 0x01, 0x01, 0x00,
                                                                                    0x00, 0x01, 0x00, 0x01, 0x00, 0x00]

    /// Big-endian TIFF header and one IFD0 entry: Orientation (0x0112), SHORT, count 1, value 1; no next IFD.
    static let fixedExif: [UInt8] = [0xFF, 0xE1, 0x00, 0x22] + Array("Exif".utf8) + [0x00, 0x00]
        + [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
        + [0x00, 0x01, 0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
        + [0x00, 0x00, 0x00, 0x00]
}
