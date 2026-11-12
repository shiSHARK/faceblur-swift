// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import Foundation

// Masks, plans and results (ADR 0002 decisions 5 and 6, ADR 0015 decision 6). The library computes mask geometry
// and upright boxes; the facade keeps a reference to the library value a Swift value came from (`KotlinRef`), which
// takes no part in `==`, hashing or printing.

public enum MaskOrigin: Sendable, Hashable { case detected, manual }

/// A detected face in pixel coordinates of the image passed in. No landmarks.
public struct FaceBox: Sendable, Hashable {
    public let left: Float, top: Float, right: Float, bottom: Float, score: Float
    public var width: Float { right - left }
    public var height: Float { bottom - top }
    let ref: KotlinRef<FaceBlurCore.FaceBox>

    init(_ k: FaceBlurCore.FaceBox) {
        left = k.left
        top = k.top
        right = k.right
        bottom = k.bottom
        score = k.score
        ref = KotlinRef(k)
    }
}

/// An opaque mask: an ellipse or a rectangle with its centre and radii in image pixels.
public struct Mask: Sendable, Hashable {
    public let shape: MaskShape, centerX: Float, centerY: Float, radiusX: Float, radiusY: Float
    public let origin: MaskOrigin
    let ref: KotlinRef<FaceBlurCore.Mask>

    init(_ k: FaceBlurCore.Mask) {
        shape = MaskShape(k.shape)
        centerX = k.centerX
        centerY = k.centerY
        radiusX = k.radiusX
        radiusY = k.radiusY
        origin = k.origin == .manual ? .manual : .detected
        ref = KotlinRef(k)
    }

    /// The mask the library draws for a detected face with `masking`.
    public static func fromFace(_ face: FaceBox, masking: MaskingConfiguration = .default) throws(FaceMaskError) -> Mask {
        let m = try masking.kotlin()
        return Mask(try kotlinCall { try FaceBlurCore.Mask.companion.fromFace(box: face.ref.value, masking: m) })
    }

    /// A manual mask over a box the user drew, expanded as a detected face would be.
    public static func manual(left: Float, top: Float, right: Float, bottom: Float,
                              masking: MaskingConfiguration = .default) throws(FaceMaskError) -> Mask {
        let m = try masking.kotlin()
        return Mask(try kotlinCall {
            try FaceBlurCore.Mask.companion.manual(left: left, top: top, right: right, bottom: bottom, masking: m)
        })
    }

    /// A mask with exactly this geometry.
    public static func exact(shape: MaskShape, centerX: Float, centerY: Float,
                             radiusX: Float, radiusY: Float) throws(FaceMaskError) -> Mask {
        Mask(try kotlinCall {
            try FaceBlurCore.Mask.companion.exact(shape: shape.kotlin, centerX: centerX, centerY: centerY,
                                                  radiusX: radiusX, radiusY: radiusY)
        })
    }
}

/// The masks for one image of `width` x `height` pixels. `==` and hashing use width, height and masks only.
public struct MaskPlan: Sendable, Hashable {
    public let width: Int, height: Int, masks: [Mask]
    /// The library plan this plan came from (`detectFile`, `toMaskPlan`, `planFile`, `withMasks`); `nil` for a plan
    /// from the public initialiser, which file mode refuses with `maskPlanMismatch`. A plan from the in-memory `detect`
    /// keeps the orientation it was detected with: in-memory `applyMasks` with another one throws `maskPlanMismatch`.
    let binding: KotlinRef<FaceBlurCore.MaskPlan>?

    /// A plan for in-memory calls. It is not bound to a file, so file mode refuses it.
    public init(width: Int, height: Int, masks: [Mask]) throws(FaceMaskError) {
        _ = try kotlinCall {
            try FaceBlurCore.MaskPlan(width: Int32(clamping: width), height: Int32(clamping: height),
                                      masks: masks.map(\.ref.value))
        }
        self.width = width
        self.height = height
        self.masks = masks
        binding = nil
    }

    init(_ k: FaceBlurCore.MaskPlan) {
        width = Int(k.width)
        height = Int(k.height)
        masks = k.masks.map(Mask.init)
        binding = KotlinRef(k)
    }

    /// The same plan (same size and binding) with other masks, for example after the user edited them.
    public func withMasks(_ masks: [Mask]) throws(FaceMaskError) -> MaskPlan {
        guard let binding else { return try MaskPlan(width: width, height: height, masks: masks) }
        return MaskPlan(try kotlinCall { try binding.value.withMasks(masks: masks.map(\.ref.value)) })
    }

    /// The library plan for an in-memory call.
    func kotlinForImage() throws(FaceMaskError) -> FaceBlurCore.MaskPlan {
        if let binding { return binding.value }
        return try kotlinCall {
            try FaceBlurCore.MaskPlan(width: Int32(clamping: width), height: Int32(clamping: height),
                                      masks: masks.map(\.ref.value))
        }
    }

    /// The library plan for file mode: the bound plan with these masks; an unbound plan is refused before the source
    /// is opened.
    func kotlinForFile() throws(FaceMaskError) -> FaceBlurCore.MaskPlan {
        guard let binding else { throw .maskPlanMismatch }
        return try kotlinCall { try binding.value.withMasks(masks: masks.map(\.ref.value)) }
    }

    public static func == (a: MaskPlan, b: MaskPlan) -> Bool {
        a.width == b.width && a.height == b.height && a.masks == b.masks
    }

    public func hash(into h: inout Hasher) {
        h.combine(width)
        h.combine(height)
        h.combine(masks)
    }
}

/// A box in upright (orientation-applied) coordinates.
public struct UprightBox: Sendable, Hashable {
    public let left: Float, top: Float, right: Float, bottom: Float, imageWidth: Int, imageHeight: Int

    /// Converts a box in raw (stored) pixel coordinates to upright coordinates for an EXIF orientation 1 ... 8.
    public static func fromRaw(left: Float, top: Float, right: Float, bottom: Float,
                               rawWidth: Int, rawHeight: Int, orientation: Int) throws(FaceMaskError) -> UprightBox {
        let k = try kotlinCall {
            try FaceBlurCore.UprightBox.companion.fromRaw(
                left: left, top: top, right: right, bottom: bottom, rawWidth: Int32(clamping: rawWidth),
                rawHeight: Int32(clamping: rawHeight), orientation: Int32(clamping: orientation))
        }
        return UprightBox(left: k.left, top: k.top, right: k.right, bottom: k.bottom,
                          imageWidth: Int(k.imageWidth), imageHeight: Int(k.imageHeight))
    }
}

/// A face that a profile check expects, in pixel coordinates.
public struct ExpectedFace: Sendable, Hashable {
    public let left: Float, top: Float, right: Float, bottom: Float

    public init(left: Float, top: Float, right: Float, bottom: Float) throws(FaceMaskError) {
        _ = try kotlinCall { try FaceBlurCore.ExpectedFace(left: left, top: top, right: right, bottom: bottom) }
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    var kotlin: FaceBlurCore.ExpectedFace {
        get throws(FaceMaskError) {
            try kotlinCall { try FaceBlurCore.ExpectedFace(left: left, top: top, right: right, bottom: bottom) }
        }
    }
}

/// Step durations in milliseconds; `nil` = the step was not performed.
public struct Timings: Sendable, Hashable {
    public let decodeMs: Double?, orientScaleMs: Double?, detectMs: Double, passes: Int
    public let maskMs: Double, encodeMs: Double?, totalMs: Double, gcMs: Double?

    init(_ k: FaceBlurCore.Timings) {
        decodeMs = k.decodeMs?.doubleValue
        orientScaleMs = k.orientScaleMs?.doubleValue
        detectMs = k.detectMs
        passes = Int(k.passes)
        maskMs = k.maskMs
        encodeMs = k.encodeMs?.doubleValue
        totalMs = k.totalMs
        gcMs = k.gcMs?.doubleValue
    }
}

/// The faces found in an image, without masking it. `==` uses the public values only.
public struct Detection: Sendable, Hashable {
    public let faces: [FaceBox], width: Int, height: Int, outputWidth: Int, outputHeight: Int
    public let hasGainMap: Bool, masking: MaskingConfiguration, timings: Timings, warnings: [String]
    let ref: KotlinRef<FaceBlurCore.Detection>

    init(_ k: FaceBlurCore.Detection) {
        faces = k.faces.map(FaceBox.init)
        width = Int(k.width)
        height = Int(k.height)
        outputWidth = Int(k.outputWidth)
        outputHeight = Int(k.outputHeight)
        hasGainMap = k.hasGainMap
        masking = MaskingConfiguration(k.masking)
        timings = Timings(k.timings)
        warnings = k.warnings
        ref = KotlinRef(k)
    }

    /// The plan with one mask per face, drawn with the detection's masking configuration.
    public func toMaskPlan() throws(FaceMaskError) -> MaskPlan {
        MaskPlan(try kotlinCall { try ref.value.toMaskPlan() })
    }

    /// The plan with one mask per face, drawn with `masking`.
    public func toMaskPlan(masking: MaskingConfiguration) throws(FaceMaskError) -> MaskPlan {
        let m = try masking.kotlin()
        return MaskPlan(try kotlinCall { try ref.value.toMaskPlan(masking: m) })
    }
}

/// The result of an in-memory masking call.
public struct MaskResult: Sendable, Hashable {
    public let faces: [FaceBox], masks: [Mask], width: Int, height: Int, gainMapRemoved: Bool
    public let timings: Timings, warnings: [String]

    init(_ k: FaceBlurCore.MaskResult) {
        faces = k.faces.map(FaceBox.init)
        masks = k.masks.map(Mask.init)
        width = Int(k.width)
        height = Int(k.height)
        gainMapRemoved = k.gainMapRemoved
        timings = Timings(k.timings)
        warnings = k.warnings
    }
}

/// The result of a file-mode masking call.
public struct FileResult: Sendable, Hashable {
    public let faces: [FaceBox], masks: [Mask], width: Int, height: Int
    public let sourceWidth: Int, sourceHeight: Int, outputWidth: Int, outputHeight: Int, outputBytes: Int64
    public let gainMapRemoved: Bool, timings: Timings, warnings: [String]

    init(_ k: FaceBlurCore.FileResult) {
        faces = k.faces.map(FaceBox.init)
        masks = k.masks.map(Mask.init)
        width = Int(k.width)
        height = Int(k.height)
        sourceWidth = Int(k.sourceWidth)
        sourceHeight = Int(k.sourceHeight)
        outputWidth = Int(k.outputWidth)
        outputHeight = Int(k.outputHeight)
        outputBytes = k.outputBytes
        gainMapRemoved = k.gainMapRemoved
        timings = Timings(k.timings)
        warnings = k.warnings
    }
}

/// The result of a profile check: whether every expected face was found.
public struct ProfileCheckResult: Sendable, Hashable {
    public let allFound: Bool, bestIoU: [Float], detections: [FaceBox]

    init(_ k: FaceBlurCore.ProfileCheckResult) {
        allFound = k.allFound
        bestIoU = k.bestIoU.map(\.floatValue)
        detections = k.detections.map(FaceBox.init)
    }
}

/// A reference to an immutable library value, carried inside a Swift value. Unchecked opt-out 2 of 2: the library's
/// `FaceBox`, `Mask`, `MaskPlan` and `Detection` are immutable, and the `FaceMasker` it also carries is used on the
/// masker's serial queue only. It takes no part in equality, hashing or printing: every instance compares equal.
final class KotlinRef<T: AnyObject>: @unchecked Sendable, Hashable, CustomStringConvertible, CustomReflectable {
    let value: T
    init(_ value: T) { self.value = value }
    static func == (a: KotlinRef, b: KotlinRef) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
    var description: String { "" }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
