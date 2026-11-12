// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import Foundation

// The model and its profile (ADR 0012). The app supplies the model; FaceBlur ships none. The score threshold and the
// expected SHA-256 have no default.

/// Where the model bytes come from.
public enum ModelSource: Sendable {
    /// Model bytes in memory. They reach the library through one memory copy.
    case data(Data)
    /// A model file (file URLs only). The library reads it read-only; nothing is written.
    case file(URL)
}

public enum RowLayout: Sendable, Hashable { case rows, columns }
public enum BoxFormat: Sendable, Hashable { case xyxy, xywh, cxcywh }
public enum CoordinateSpace: Sendable, Hashable { case inputPixels, normalized }
public enum ColorOrder: Sendable, Hashable { case rgb, bgr }
public enum TensorLayout: Sendable, Hashable { case nchw, nhwc }

/// Input scaling of a generic model: `(pixel / divisor - mean) / std` per channel.
public struct PixelScaling: Sendable, Hashable {
    public let divisor: Float, mean: [Float], std: [Float]

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)``: `divisor` must be finite and above 0, `mean`
    ///   three finite values, `std` three finite values above 0.
    public init(divisor: Float, mean: [Float], std: [Float]) throws(FaceMaskError) {
        guard divisor.isFinite && divisor > 0 else { throw .invalidConfiguration(parameter: "divisor") }
        guard mean.count == 3 && mean.allSatisfy(\.isFinite) else { throw .invalidConfiguration(parameter: "mean") }
        guard std.count == 3 && std.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw .invalidConfiguration(parameter: "std")
        }
        self.divisor = divisor
        self.mean = mean
        self.std = std
        _ = try kotlin()
    }

    func kotlin() throws(FaceMaskError) -> FaceBlurCore.PixelScaling {
        func array(_ v: [Float]) -> KotlinFloatArray {
            let a = KotlinFloatArray(size: Int32(v.count))
            for (i, x) in v.enumerated() { a.set(index: Int32(i), value: x) }
            return a
        }
        return try kotlinCall { try FaceBlurCore.PixelScaling(divisor: divisor, mean: array(mean), std: array(std)) }
    }
}

/// The output layout of a generic detection model.
public struct GenericDetections: Sendable, Hashable {
    public let boxesOutput: String, boxColumn: Int, scoresOutput: String?, scoreColumn: Int
    public let rows: RowLayout, boxFormat: BoxFormat, coordinates: CoordinateSpace
    public let colorOrder: ColorOrder, tensorLayout: TensorLayout, scaling: PixelScaling, nmsInGraph: Bool

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)`` for an empty output name or a negative column.
    public init(boxesOutput: String, boxColumn: Int, scoresOutput: String?, scoreColumn: Int,
                rows: RowLayout, boxFormat: BoxFormat, coordinates: CoordinateSpace, colorOrder: ColorOrder,
                tensorLayout: TensorLayout, scaling: PixelScaling, nmsInGraph: Bool = false) throws(FaceMaskError) {
        guard !boxesOutput.isEmpty else { throw .invalidConfiguration(parameter: "boxesOutput") }
        guard scoresOutput.map({ !$0.isEmpty }) ?? true else { throw .invalidConfiguration(parameter: "scoresOutput") }
        guard boxColumn >= 0 else { throw .invalidConfiguration(parameter: "boxColumn") }
        guard scoreColumn >= 0 else { throw .invalidConfiguration(parameter: "scoreColumn") }
        self.boxesOutput = boxesOutput
        self.boxColumn = boxColumn
        self.scoresOutput = scoresOutput
        self.scoreColumn = scoreColumn
        self.rows = rows
        self.boxFormat = boxFormat
        self.coordinates = coordinates
        self.colorOrder = colorOrder
        self.tensorLayout = tensorLayout
        self.scaling = scaling
        self.nmsInGraph = nmsInGraph
        _ = try kotlin()
    }

    func kotlin() throws(FaceMaskError) -> FaceBlurCore.DetectionFormat.GenericDetections {
        let s = try scaling.kotlin()
        return try kotlinCall {
            try FaceBlurCore.DetectionFormat.GenericDetections(
                boxesOutput: boxesOutput, boxColumn: Int32(clamping: boxColumn), scoresOutput: scoresOutput,
                scoreColumn: Int32(clamping: scoreColumn),
                rows: rows == .rows ? FaceBlurCore.RowLayout.rows : .columns,
                boxFormat: boxFormat == .xyxy ? FaceBlurCore.BoxFormat.xyxy : boxFormat == .xywh ? .xywh : .cxcywh,
                coordinates: coordinates == .inputPixels ? FaceBlurCore.CoordinateSpace.inputPixels : .normalized,
                colorOrder: colorOrder == .rgb ? FaceBlurCore.ColorOrder.rgb : .bgr,
                tensorLayout: tensorLayout == .nchw ? FaceBlurCore.TensorLayout.nchw : .nhwc,
                scaling: s, nmsInGraph: nmsInGraph)
        }
    }
}

/// The output format of the model.
public enum DetectionFormat: Sendable, Hashable {
    /// The output layout of a face-detection model in YuNet layout (12 named outputs).
    case yuNetLayout
    case genericDetections(GenericDetections)
}

/// The profile of the model: its format, input size, score threshold and expected SHA-256.
public struct DetectorProfile: Sendable, Hashable {
    public let format: DetectionFormat, inputWidth: Int, inputHeight: Int, scoreThreshold: Float
    /// 64 hexadecimal digits, stored in lower case.
    public let expectedSHA256: String
    /// Defaults 1.6 / 1.8 (also the minimum); only larger, up to 3.0.
    public let minMaskExpandX: Float, minMaskExpandY: Float

    /// - Throws: ``FaceMaskError/invalidConfiguration(parameter:)``: input sides 128 ... 1280 (multiples of 32 for
    ///   `.yuNetLayout`), a threshold above 0 and below 1, 64 hexadecimal digits, expansion minima in range.
    public init(format: DetectionFormat, inputWidth: Int, inputHeight: Int, scoreThreshold: Float,
                expectedSHA256: String, minMaskExpandX: Float = 1.6, minMaskExpandY: Float = 1.8) throws(FaceMaskError) {
        let yuNet = format == .yuNetLayout
        guard (128...1280).contains(inputWidth), !yuNet || inputWidth % 32 == 0 else {
            throw .invalidConfiguration(parameter: "inputWidth")
        }
        guard (128...1280).contains(inputHeight), !yuNet || inputHeight % 32 == 0 else {
            throw .invalidConfiguration(parameter: "inputHeight")
        }
        guard scoreThreshold > 0 && scoreThreshold < 1 else { throw .invalidConfiguration(parameter: "scoreThreshold") }
        try Check.range("minMaskExpandX", minMaskExpandX, MaskingConfiguration.defaultExpandX,
                        MaskingConfiguration.maxExpand)
        try Check.range("minMaskExpandY", minMaskExpandY, MaskingConfiguration.defaultExpandY,
                        MaskingConfiguration.maxExpand)
        let sha = expectedSHA256.lowercased()
        guard sha.utf8.count == 64, sha.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw .invalidConfiguration(parameter: "expectedSha256")
        }
        self.format = format
        self.inputWidth = inputWidth
        self.inputHeight = inputHeight
        self.scoreThreshold = scoreThreshold
        self.expectedSHA256 = sha
        self.minMaskExpandX = minMaskExpandX
        self.minMaskExpandY = minMaskExpandY
        _ = try kotlin()
    }

    func kotlin() throws(FaceMaskError) -> FaceBlurCore.DetectorProfile {
        let f: FaceBlurCore.DetectionFormat
        switch format {
        case .yuNetLayout: f = FaceBlurCore.DetectionFormat.YuNetLayout()
        case let .genericDetections(g): f = try g.kotlin()
        }
        return try kotlinCall {
            try FaceBlurCore.DetectorProfile(
                format: f, inputWidth: Int32(clamping: inputWidth), inputHeight: Int32(clamping: inputHeight),
                scoreThreshold: scoreThreshold, expectedSha256: expectedSHA256, minMaskExpandX: minMaskExpandX,
                minMaskExpandY: minMaskExpandY)
        }
    }
}

/// One input or output of the model.
public struct TensorInfo: Sendable, Hashable {
    public let name: String, elementType: String
    /// `nil` = a symbolic dimension.
    public let shape: [Int?]

    init(_ k: FaceBlurCore.TensorInfo) {
        name = k.name
        elementType = k.elementType
        shape = k.shape.map { ($0 as? NSNumber)?.intValue }
    }
}

/// What the library found when it checked the model.
public struct ModelInfo: Sendable, Hashable {
    public let sha256: String, sizeBytes: Int64, irVersion: Int64, opsetImports: [String: Int64]
    public let inputs: [TensorInfo], outputs: [TensorInfo], warnings: [String]

    init(_ k: FaceBlurCore.ModelInfo) {
        sha256 = k.sha256
        sizeBytes = k.sizeBytes
        irVersion = k.irVersion
        opsetImports = k.opsetImports.mapValues { $0.int64Value }
        inputs = k.inputs.map(TensorInfo.init)
        outputs = k.outputs.map(TensorInfo.init)
        warnings = k.warnings
    }
}

/// The model of a masker plus the runtime that runs it.
public struct MaskerModelInfo: Sendable, Hashable {
    public let model: ModelInfo, runtimeVersion: String, executionProvider: String, faceBlurVersion: String

    init(_ k: FaceBlurCore.MaskerModelInfo) {
        model = ModelInfo(k.model)
        runtimeVersion = k.runtimeVersion
        executionProvider = k.executionProvider
        faceBlurVersion = k.faceBlurVersion
    }
}

/// A checked model: its bytes matched the expected SHA-256 and passed the library's pre-parse checks. Immutable;
/// load it once and share it with every ``FaceMasker``.
public final class DetectorModel: @unchecked Sendable {
    // Unchecked opt-out 1 of 2: all stored properties are `let`; the library's model object is immutable and
    // documented as thread-safe (ADR 0012).
    public static let defaultMaxModelBytes: Int = 52_428_800
    static let maxModelBytesLimit: Int = 2_147_483_639

    public let info: ModelInfo
    public let profile: DetectorProfile
    let kotlin: FaceBlurCore.DetectorModel

    /// Reads, hashes and checks the model on a private queue of FaceBlur, never on the caller's thread, the main
    /// thread or the cooperative pool. For `.file`, the facade holds security-scoped access to the URL for the
    /// duration of the read.
    ///
    /// - Throws: ``FaceMaskError``: `invalidConfiguration(parameter: "source")` for a URL that is not a file URL,
    ///   `invalidConfiguration(parameter: "maxModelBytes")` outside 1 ... 2,147,483,639, `ioFailed`,
    ///   `modelIntegrity`, `modelRejected(findings:)`.
    public init(source: ModelSource, profile: DetectorProfile,
                maxModelBytes: Int = DetectorModel.defaultMaxModelBytes) async throws {
        guard (1...Self.maxModelBytesLimit).contains(maxModelBytes) else {
            throw FaceMaskError.invalidConfiguration(parameter: "maxModelBytes")
        }
        if case let .file(url) = source, !url.isFileURL { throw FaceMaskError.invalidConfiguration(parameter: "source") }
        if case let .data(data) = source, data.count > maxModelBytes {
            throw FaceMaskError.invalidConfiguration(parameter: "maxModelBytes")
        }
        let loaded: KotlinRef<FaceBlurCore.DetectorModel> = try await Work.onQueue(Work.models) {
            () throws(FaceMaskError) in
            let kProfile = try profile.kotlin()
            let kSource: FaceBlurCore.ModelSource
            switch source {
            case let .data(data):
                kSource = try data.withUnsafeBytes { (raw) throws(FaceMaskError) in
                    guard let base = raw.baseAddress, !raw.isEmpty else {
                        throw FaceMaskError.invalidConfiguration(parameter: "source")
                    }
                    return try Hooks.modelCopy(base, raw.count)
                }
                return KotlinRef(try kotlinCall {
                    try FaceBlurCore.DetectorModel.companion.load(
                        source: kSource, profile: kProfile, maxModelBytes: Int64(maxModelBytes))
                })
            case let .file(url):
                return try SecurityScope.with(url) { () throws(FaceMaskError) in
                    let path = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? ""
                    return KotlinRef(try kotlinCall {
                        try FaceBlurCore.DetectorModel.companion.load(
                            source: FaceBlurCore.ModelSource.companion.fromFile(path: path), profile: kProfile,
                            maxModelBytes: Int64(maxModelBytes))
                    })
                }
            }
        }
        kotlin = loaded.value
        info = ModelInfo(loaded.value.info)
        self.profile = profile
    }
}
