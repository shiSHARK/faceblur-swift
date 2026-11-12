// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import Foundation

// Masking and file-mode configuration (ADR 0002 decision 10, ADR 0011 decision 2). Every range is checked in Swift
// first and again by the library; a value outside its range throws `invalidConfiguration` with the library's
// parameter name. Opaque styles only: there is no blur, pixelation or transparency anywhere.

/// How a mask is filled. Every style is opaque.
public enum MaskStyle: Sendable, Hashable, CaseIterable { case gradientOval, smoothFill, solid }

/// The outline of a mask.
public enum MaskShape: Sendable, Hashable, CaseIterable { case ellipse, rectangle }

/// A mask colour. It has no alpha component, so a mask is opaque by construction.
public struct MaskColor: Sendable, Hashable {
    public var red: UInt8, green: UInt8, blue: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// (127, 127, 127), the default.
    public static let neutralGray = MaskColor(red: 127, green: 127, blue: 127)

    /// The library's ARGB form: `0xFF000000 | r << 16 | g << 8 | b`.
    var argb: Int32 {
        Int32(bitPattern: 0xFF00_0000 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue))
    }
}

/// How masks are drawn. Expansion factors can only be larger than the defaults; the feather grows outward only.
public struct MaskingConfiguration: Sendable, Hashable {
    public static let `default` = MaskingConfiguration(
        unchecked: .gradientOval, .ellipse, defaultExpandX, defaultExpandY, 0.10, .neutralGray)
    static let defaultExpandX: Float = 1.6
    static let defaultExpandY: Float = 1.8
    static let maxExpand: Float = 3.0
    static let maxFeather: Float = 0.5

    public let style: MaskStyle
    public let shape: MaskShape
    /// Default 1.6; range 1.6 ... 3.0 (only larger).
    public let expandX: Float
    /// Default 1.8; range 1.8 ... 3.0 (only larger).
    public let expandY: Float
    /// Default 0.10; range 0 ... 0.5 (outward only).
    public let feather: Float
    public let color: MaskColor

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)`` for a value outside its range.
    public init(style: MaskStyle = .gradientOval, shape: MaskShape = .ellipse,
                expandX: Float = 1.6, expandY: Float = 1.8, feather: Float = 0.10,
                color: MaskColor = .neutralGray) throws(FaceMaskError) {
        try Check.range("expandX", expandX, Self.defaultExpandX, Self.maxExpand)
        try Check.range("expandY", expandY, Self.defaultExpandY, Self.maxExpand)
        try Check.range("feather", feather, 0, Self.maxFeather)
        self.init(unchecked: style, shape, expandX, expandY, feather, color)
        _ = try kotlin()
    }

    init(unchecked style: MaskStyle, _ shape: MaskShape, _ expandX: Float, _ expandY: Float, _ feather: Float,
         _ color: MaskColor) {
        self.style = style
        self.shape = shape
        self.expandX = expandX
        self.expandY = expandY
        self.feather = feather
        self.color = color
    }

    func kotlin() throws(FaceMaskError) -> MaskingConfig {
        try kotlinCall {
            try MaskingConfig(style: style.kotlin, shape: shape.kotlin, expandX: expandX, expandY: expandY,
                              feather: feather, color: color.argb)
        }
    }

    init(_ k: MaskingConfig) {
        let argb = UInt32(bitPattern: k.color)
        self.init(unchecked: MaskStyle(k.style), MaskShape(k.shape), k.expandX, k.expandY, k.feather,
                  MaskColor(red: UInt8(truncatingIfNeeded: argb >> 16), green: UInt8(truncatingIfNeeded: argb >> 8),
                            blue: UInt8(truncatingIfNeeded: argb)))
    }
}

/// Configuration of a ``FaceMasker``.
public struct FaceMaskerConfiguration: Sendable, Hashable {
    public static let `default` = FaceMaskerConfiguration(unchecked: .default, 0)
    public let masking: MaskingConfiguration
    /// Threads of the ONNX Runtime; default 0 (automatic), range 0 ... 4.
    public let onnxThreads: Int

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)`` for a value outside its range.
    public init(masking: MaskingConfiguration = .default, onnxThreads: Int = 0) throws(FaceMaskError) {
        guard (0...4).contains(onnxThreads) else { throw .invalidConfiguration(parameter: "onnxThreads") }
        self.init(unchecked: masking, onnxThreads)
        _ = try kotlin()
    }

    init(unchecked masking: MaskingConfiguration, _ onnxThreads: Int) {
        self.masking = masking
        self.onnxThreads = onnxThreads
    }

    func kotlin() throws(FaceMaskError) -> FaceMaskerConfig {
        let m = try masking.kotlin()
        return try kotlinCall { try FaceMaskerConfig(masking: m, onnxThreads: Int32(clamping: onnxThreads)) }
    }
}

/// The output format of file mode. JPEG only.
public enum OutputFormat: Sendable, Hashable {
    /// Quality 1 ... 100; the default is 90.
    case jpeg(quality: Int)
}

/// Which metadata of the source is kept in the output.
public enum MetadataPolicy: Sendable, Hashable {
    /// Remove all metadata (the default).
    case stripAll
    /// Keep only the named groups. An opt-in: GPS, date and time and camera data can identify a person or a place.
    case keepAllowlist(gps: Bool = false, dateTime: Bool = false, camera: Bool = false)
}

/// Options of file mode (ADR 0005).
public struct FileOptions: Sendable, Hashable {
    public static let `default` = FileOptions(unchecked: 3_500, 0, 25_000_000, .jpeg(quality: 90), .stripAll)
    /// Default 3,500; 0 (source size) or at least 3,500 (the detection floor).
    public let maxLongSide: Int
    /// Default 0 (output = working size); 0 or at least 64.
    public let maxOutputLongSide: Int
    /// Default 25,000,000; the limit on the decoded working image.
    public let maxDecodedPixels: Int
    /// Default `.jpeg(quality: 90)`.
    public let format: OutputFormat
    /// Default `.stripAll`.
    public let metadata: MetadataPolicy

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)`` for a value outside its range.
    public init(maxLongSide: Int = 3_500, maxOutputLongSide: Int = 0, maxDecodedPixels: Int = 25_000_000,
                format: OutputFormat = .jpeg(quality: 90), metadata: MetadataPolicy = .stripAll) throws(FaceMaskError) {
        guard maxLongSide == 0 || (3_500...Int(Int32.max)).contains(maxLongSide) else {
            throw .invalidConfiguration(parameter: "maxLongSide")
        }
        guard maxOutputLongSide == 0 || (64...Int(Int32.max)).contains(maxOutputLongSide) else {
            throw .invalidConfiguration(parameter: "maxOutputLongSide")
        }
        guard (13_000_000...100_000_000).contains(maxDecodedPixels) else {
            throw .invalidConfiguration(parameter: "maxDecodedPixels")
        }
        if case let .jpeg(quality) = format, !(1...100).contains(quality) {
            throw .invalidConfiguration(parameter: "quality")
        }
        if case let .keepAllowlist(gps, dateTime, camera) = metadata, !(gps || dateTime || camera) {
            throw .invalidConfiguration(parameter: "metadata")
        }
        self.init(unchecked: maxLongSide, maxOutputLongSide, maxDecodedPixels, format, metadata)
        _ = try kotlin()
    }

    init(unchecked maxLongSide: Int, _ maxOutputLongSide: Int, _ maxDecodedPixels: Int, _ format: OutputFormat,
         _ metadata: MetadataPolicy) {
        self.maxLongSide = maxLongSide
        self.maxOutputLongSide = maxOutputLongSide
        self.maxDecodedPixels = maxDecodedPixels
        self.format = format
        self.metadata = metadata
    }

    func kotlin() throws(FaceMaskError) -> FaceBlurCore.FileOptions {
        try kotlinCall {
            let f: FaceBlurCore.OutputFormat
            switch format {
            case let .jpeg(quality): f = try FaceBlurCore.OutputFormat.Jpeg(quality: Int32(clamping: quality))
            }
            let m: FaceBlurCore.MetadataPolicy
            switch metadata {
            case .stripAll: m = FaceBlurCore.MetadataPolicy.StripAll.shared
            case let .keepAllowlist(gps, dateTime, camera):
                m = try FaceBlurCore.MetadataPolicy.KeepAllowlist(gps: gps, dateTime: dateTime, camera: camera)
            }
            return try FaceBlurCore.FileOptions(
                maxLongSide: Int32(clamping: maxLongSide), maxOutputLongSide: Int32(clamping: maxOutputLongSide),
                maxDecodedPixels: Int32(clamping: maxDecodedPixels), format: f, metadata: m)
        }
    }
}

/// Where file mode writes the masked JPEG.
public enum OutputTarget: Sendable, Hashable {
    /// A new file (file URLs only). With `replaceExisting: false` an existing file is an error.
    case newFile(URL, replaceExisting: Bool = false)
    /// Replace the source file atomically.
    case overwriteSource
}

/// Range checks shared by the configuration types.
enum Check {
    static func range(_ parameter: String, _ value: Float, _ min: Float, _ max: Float) throws(FaceMaskError) {
        guard value >= min && value <= max else { throw .invalidConfiguration(parameter: parameter) }
    }
}

// MARK: - Enum conversions

extension MaskStyle {
    var kotlin: FaceBlurCore.MaskStyle {
        switch self {
        case .gradientOval: .gradientOval
        case .smoothFill: .smoothFill
        case .solid: .solid
        }
    }

    init(_ k: FaceBlurCore.MaskStyle) {
        self = k == .solid ? .solid : k == .smoothFill ? .smoothFill : .gradientOval
    }
}

extension MaskShape {
    var kotlin: FaceBlurCore.MaskShape { self == .ellipse ? .ellipse : .rectangle }
    init(_ k: FaceBlurCore.MaskShape) { self = k == .rectangle ? .rectangle : .ellipse }
}
