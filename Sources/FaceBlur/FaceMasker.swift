// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO

/// Detects faces with the app's model and covers them with opaque masks.
///
/// Each masker owns a private serial queue, which is also the actor's executor: every call that does work runs there,
/// one after another, never on the main thread or the cooperative pool. Use one masker per parallel worker and share
/// one ``DetectorModel`` between them.
///
/// In-memory calls work on the caller's buffer in place. After any error the buffer must not be displayed, encoded or
/// shared as masked; after `CancellationError` treat it as not masked (it is either untouched or fully masked).
///
/// ## Orientation
///
/// Every in-memory form takes the orientation a viewer applies to the stored pixels (`CGImagePropertyOrientation`,
/// default `.up`). Detection runs on the upright view, and every coordinate of the call (faces, masks, a plan) is in
/// that view; its size is the stored size, with width and height swapped for `.left`, `.leftMirrored`, `.right` and
/// `.rightMirrored`. The in-place forms write the masks through the same view, so they land on the stored pixels a
/// viewer shows under them; the buffer is not turned. ``mask(_:orientation:)`` returns an upright image. Pass the
/// orientation the image is shown with: with a wrong one a sideways face may not be detected, and then stays unmasked.
/// A plan from `detect` is bound to the orientation it was detected with: `applyMasks` with another orientation (the
/// forms without one are `.up`) throws ``FaceMaskError/maskPlanMismatch`` and writes nothing. A plan built with
/// ``MaskPlan/init(width:height:masks:)`` has no such binding.
/// `UIImage.cgImage` ignores `imageOrientation`; pass the matching value. `UIImage.Orientation` and
/// `CGImagePropertyOrientation` name the same eight cases (`.up`, `.down`, `.left`, `.right` and the mirrored ones)
/// with different raw values, so map them case by case, never by raw value:
///
/// ```swift
/// guard let pixels = photo.cgImage else { return }
/// let orientation: CGImagePropertyOrientation
/// switch photo.imageOrientation {
/// case .up: orientation = .up
/// case .down: orientation = .down
/// case .left: orientation = .left
/// case .right: orientation = .right
/// case .upMirrored: orientation = .upMirrored
/// case .downMirrored: orientation = .downMirrored
/// case .leftMirrored: orientation = .leftMirrored
/// case .rightMirrored: orientation = .rightMirrored
/// @unknown default: return // an orientation this code does not know: do not guess
/// }
/// let (masked, result) = try await masker.mask(pixels, orientation: orientation)
/// let jpeg = try await FaceMasker.encodeJPEG(masked) // upright pixels, no metadata, orientation 1
/// ```
///
/// ## Alpha
///
/// The in-memory forms mask opaque images only. An image with any pixel that is not opaque (alpha below its maximum)
/// is refused with ``FaceMaskError/unsupportedImage`` and nothing is changed: flatten it onto an opaque background
/// first. A format that has an alpha channel is fine when every pixel is opaque (for example the default format of
/// `UIGraphicsImageRenderer` for a photo).
///
/// Outside the guarantee of the in-memory calls: showing, encoding or sharing the pixels before the call returns,
/// scaling them below the profile's input size before the call, and using them after any error.
public actor FaceMasker {
    private let queue: DispatchSerialQueue
    private let handle: KotlinRef<FaceBlurCore.FaceMasker>

    public nonisolated let model: DetectorModel
    public nonisolated let configuration: FaceMaskerConfiguration
    public nonisolated let modelInfo: MaskerModelInfo

    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// Creates the runtime session on the masker's queue (the caller is not blocked).
    ///
    /// - Throws: ``FaceMaskError``: `runtimeUnavailable` (no runtime, another runtime bridge registered first, or a
    ///   library binary of another version), `invalidConfiguration(parameter:)`, `modelRejected(findings:)`.
    public init(model: DetectorModel, configuration: FaceMaskerConfiguration = .default) async throws {
        try Runtime.check()
        let queue = DispatchSerialQueue(label: "io.github.shishark.faceblur.masker", qos: .userInitiated)
        let created = try await Work.onQueue(queue) { () throws(FaceMaskError) in
            let config = try configuration.kotlin()
            return KotlinRef(try kotlinCall { try FaceBlurCore.FaceMasker(model: model.kotlin, config: config) })
        }
        self.queue = queue
        handle = created
        self.model = model
        self.configuration = configuration
        modelInfo = MaskerModelInfo(created.value.modelInfo)
    }

    deinit {
        let handle = handle
        queue.async { handle.value.close() }
    }

    /// Releases the runtime session. Idempotent, never throws; it runs after a call in progress. Calls after it throw
    /// ``FaceMaskError/closed``.
    public nonisolated func close() {
        let handle = handle
        queue.async { handle.value.close() }
    }

    // MARK: In-memory mode (ADR 0004): the caller keeps owning the buffer and may use it after the call.

    /// Detects faces in the context's pixels, stored upright, without changing them. The same as
    /// ``detect(_:orientation:)-(CGContext,_)`` with `.up`.
    public nonisolated(nonsending) func detect(_ context: CGContext) async throws -> Detection {
        try await detect(context, orientation: .up)
    }

    /// Detects faces in the upright view of the context's pixels (see ``FaceMasker``, "Orientation") without changing
    /// them. Runs on the masker's queue; coordinates are pixels of the upright view, origin top-left. Throws
    /// ``FaceMaskError`` (`unsupportedImage` for an unsupported layout or a pixel that is not opaque) or
    /// `CancellationError`.
    public nonisolated(nonsending) func detect(_ context: CGContext, orientation: CGImagePropertyOrientation)
        async throws -> Detection {
        let d = try Carriers.describe(context, orientation)
        defer { withExtendedLifetime(context) {} }
        return try await run { k, token throws(FaceMaskError) in
            let image = try d.wrap()
            return Detection(try kotlinCall { try k.detect(image: image, cancellation: token) })
        }
    }

    /// Detects faces and masks them in the context's pixels, stored upright, in place. The same as
    /// ``maskInPlace(_:orientation:)-(CGContext,_)`` with `.up`.
    public nonisolated(nonsending) func maskInPlace(_ context: CGContext) async throws -> MaskResult {
        try await maskInPlace(context, orientation: .up)
    }

    /// Detects faces in the upright view of the context's pixels (see ``FaceMasker``, "Orientation") and masks them
    /// in place: the masks land on the stored pixels a viewer shows under them. Runs on the masker's queue;
    /// coordinates are pixels of the upright view. Throws ``FaceMaskError`` or `CancellationError`; after any error
    /// discard the buffer.
    public nonisolated(nonsending) func maskInPlace(_ context: CGContext, orientation: CGImagePropertyOrientation)
        async throws -> MaskResult {
        let d = try Carriers.describe(context, orientation)
        defer { withExtendedLifetime(context) {} }
        return try await run { k, token throws(FaceMaskError) in
            let image = try d.wrap()
            return MaskResult(try kotlinCall { try k.maskInPlace(image: image, cancellation: token) })
        }
    }

    /// Writes the plan's masks into the context's pixels, stored upright, in place. The same as
    /// ``applyMasks(_:to:orientation:)-(_,CGContext,_)`` with `.up`.
    public nonisolated(nonsending) func applyMasks(_ plan: MaskPlan, to context: CGContext) async throws -> MaskResult {
        try await applyMasks(plan, to: context, orientation: .up)
    }

    /// Writes the plan's masks into the upright view of the context's pixels (see ``FaceMasker``, "Orientation"), in
    /// place. Runs on the masker's queue; the plan is in pixels of the upright view. Throws ``FaceMaskError``
    /// (`maskPlanMismatch` for a plan of another size, or a plan from `detect` with another orientation; nothing is
    /// written then) or `CancellationError`.
    public nonisolated(nonsending) func applyMasks(_ plan: MaskPlan, to context: CGContext,
                                                   orientation: CGImagePropertyOrientation) async throws -> MaskResult {
        let d = try Carriers.describe(context, orientation)
        defer { withExtendedLifetime(context) {} }
        return try await run { k, token throws(FaceMaskError) in
            let image = try d.wrap()
            let p = try plan.kotlinForImage()
            return MaskResult(try kotlinCall { try k.applyMasks(image: image, plan: p, cancellation: token) })
        }
    }

    /// Checks that the profile finds the expected faces in the context's pixels, stored upright. The same as
    /// ``checkProfile(_:orientation:expectedFaces:minIoU:)-(CGContext,_,_,_)`` with `.up`.
    public nonisolated(nonsending) func checkProfile(_ context: CGContext, expectedFaces: [ExpectedFace],
                                                     minIoU: Float = 0.5) async throws -> ProfileCheckResult {
        try await checkProfile(context, orientation: .up, expectedFaces: expectedFaces, minIoU: minIoU)
    }

    /// Checks that the profile finds the expected faces in the upright view of the context's pixels (see
    /// ``FaceMasker``, "Orientation"). Runs on the masker's queue; coordinates are pixels of the upright view. Throws
    /// ``FaceMaskError`` or `CancellationError`.
    public nonisolated(nonsending) func checkProfile(_ context: CGContext, orientation: CGImagePropertyOrientation,
                                                     expectedFaces: [ExpectedFace],
                                                     minIoU: Float = 0.5) async throws -> ProfileCheckResult {
        let d = try Carriers.describe(context, orientation)
        defer { withExtendedLifetime(context) {} }
        return try await run { k, token throws(FaceMaskError) in
            let image = try d.wrap()
            let expected = try expectedFaces.map { (e) throws(FaceMaskError) in try e.kotlin }
            return ProfileCheckResult(try kotlinCall {
                try k.checkProfile(image: image, expectedFaces: expected, minIoU: minIoU, cancellation: token)
            })
        }
    }

    /// Detects faces in an opaque `32BGRA` or `32RGBA` pixel buffer, stored upright. The same as
    /// ``detect(_:orientation:)-(CVPixelBuffer,_)`` with `.up`.
    public nonisolated(nonsending) func detect(_ pixelBuffer: CVPixelBuffer) async throws -> Detection {
        try await detect(pixelBuffer, orientation: .up)
    }

    /// Detects faces in the upright view (see ``FaceMasker``, "Orientation") of a `32BGRA` or `32RGBA` pixel buffer
    /// whose alpha bytes are all 255 (opaque). Runs on the masker's queue, including the alpha check; the buffer is
    /// locked for the call. Throws ``FaceMaskError`` (`unsupportedImage` for another format or a pixel that is not
    /// opaque) or `CancellationError`.
    public nonisolated(nonsending) func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation)
        async throws -> Detection {
        try await locked(pixelBuffer, orientation) { d in
            try await run { k, token throws(FaceMaskError) in
                let image = try d.wrap()
                return Detection(try kotlinCall { try k.detect(image: image, cancellation: token) })
            }
        }
    }

    /// Detects faces and masks them in an opaque pixel buffer, stored upright, in place. The same as
    /// ``maskInPlace(_:orientation:)-(CVPixelBuffer,_)`` with `.up`.
    public nonisolated(nonsending) func maskInPlace(_ pixelBuffer: CVPixelBuffer) async throws -> MaskResult {
        try await maskInPlace(pixelBuffer, orientation: .up)
    }

    /// Detects faces in the upright view of an opaque pixel buffer (formats as
    /// ``detect(_:orientation:)-(CVPixelBuffer,_)``) and masks them in place. Runs on the masker's queue. Throws
    /// ``FaceMaskError`` or `CancellationError`; after any error discard the buffer.
    public nonisolated(nonsending) func maskInPlace(_ pixelBuffer: CVPixelBuffer,
                                                    orientation: CGImagePropertyOrientation) async throws -> MaskResult {
        try await locked(pixelBuffer, orientation) { d in
            try await run { k, token throws(FaceMaskError) in
                let image = try d.wrap()
                return MaskResult(try kotlinCall { try k.maskInPlace(image: image, cancellation: token) })
            }
        }
    }

    /// Writes the plan's masks into an opaque pixel buffer, stored upright, in place. The same as
    /// ``applyMasks(_:to:orientation:)-(_,CVPixelBuffer,_)`` with `.up`.
    public nonisolated(nonsending) func applyMasks(_ plan: MaskPlan, to pixelBuffer: CVPixelBuffer) async throws
        -> MaskResult {
        try await applyMasks(plan, to: pixelBuffer, orientation: .up)
    }

    /// Writes the plan's masks into the upright view of an opaque pixel buffer, in place. Runs on the masker's queue;
    /// the plan is in pixels of the upright view. Throws ``FaceMaskError`` (`maskPlanMismatch` for a plan of another
    /// size, or a plan from `detect` with another orientation; nothing is written then) or `CancellationError`.
    public nonisolated(nonsending) func applyMasks(_ plan: MaskPlan, to pixelBuffer: CVPixelBuffer,
                                                   orientation: CGImagePropertyOrientation) async throws -> MaskResult {
        try await locked(pixelBuffer, orientation) { d in
            try await run { k, token throws(FaceMaskError) in
                let image = try d.wrap()
                let p = try plan.kotlinForImage()
                return MaskResult(try kotlinCall { try k.applyMasks(image: image, plan: p, cancellation: token) })
            }
        }
    }

    /// Checks that the profile finds the expected faces in an opaque pixel buffer, stored upright. The same as
    /// ``checkProfile(_:orientation:expectedFaces:minIoU:)-(CVPixelBuffer,_,_,_)`` with `.up`.
    public nonisolated(nonsending) func checkProfile(_ pixelBuffer: CVPixelBuffer, expectedFaces: [ExpectedFace],
                                                     minIoU: Float = 0.5) async throws -> ProfileCheckResult {
        try await checkProfile(pixelBuffer, orientation: .up, expectedFaces: expectedFaces, minIoU: minIoU)
    }

    /// Checks that the profile finds the expected faces in the upright view of an opaque pixel buffer. Runs on the
    /// masker's queue. Throws ``FaceMaskError`` or `CancellationError`.
    public nonisolated(nonsending) func checkProfile(_ pixelBuffer: CVPixelBuffer,
                                                     orientation: CGImagePropertyOrientation,
                                                     expectedFaces: [ExpectedFace],
                                                     minIoU: Float = 0.5) async throws -> ProfileCheckResult {
        try await locked(pixelBuffer, orientation) { d in
            try await run { k, token throws(FaceMaskError) in
                let image = try d.wrap()
                let expected = try expectedFaces.map { (e) throws(FaceMaskError) in try e.kotlin }
                return ProfileCheckResult(try kotlinCall {
                    try k.checkProfile(image: image, expectedFaces: expected, minIoU: minIoU, cancellation: token)
                })
            }
        }
    }

    /// Masks a copy of an upright `image`. The same as ``mask(_:orientation:)`` with `.up`.
    public func mask(_ image: CGImage) async throws -> (image: CGImage, result: MaskResult) {
        try await mask(image, orientation: .up)
    }

    /// Masks a copy of `image`: one copy into a library-owned buffer, drawn upright (`orientation` applied), and
    /// returns a no-copy, upright image without alpha over that buffer. Coordinates in the result are pixels of the
    /// returned image. Runs on the masker's queue. Throws ``FaceMaskError`` (`unsupportedImage` when any pixel of
    /// `image` is not opaque: an image with transparency is refused, never repaired) or `CancellationError`.
    ///
    /// `UIImage.cgImage` drops `imageOrientation`; pass the matching orientation (example in ``FaceMasker``).
    public func mask(_ image: CGImage, orientation: CGImagePropertyOrientation) async throws
        -> (image: CGImage, result: MaskResult) {
        let token = Token()
        let k = handle.value
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let canvas = try OwnedCanvas.draw(image, orientation: Carriers.number(orientation))
                let result: MaskResult
                do {
                    let wrapped = try canvas.description.wrap()
                    result = MaskResult(try kotlinCall { try k.maskInPlace(image: wrapped, cancellation: token) })
                } catch {
                    canvas.discard()
                    throw error
                }
                return (try canvas.image(), result)
            } catch {
                throw FaceMaskError.forAsync(error)
            }
        } onCancel: {
            token.cancel()
        }
    }

    // MARK: JPEG output in memory

    /// Encodes `image` as a JPEG in memory, through the same steps as file mode's output: the encoder gets the pixels
    /// only (drawn once into a library-owned buffer, as stored: no orientation is applied, so pass an upright image
    /// such as the one ``mask(_:orientation:)`` returns), FaceBlur rebuilds the file with its own minimal headers (no
    /// metadata of any source, no colour profile, orientation 1) and runs file mode's fail-closed output check on it.
    /// Nothing is written to disk. Runs on a private queue of FaceBlur, never on the main thread or the cooperative
    /// pool; needs no masker. `quality` is 1 to 100 (file mode's default is 90).
    ///
    /// Throws ``FaceMaskError``: `invalidConfiguration(parameter: "quality")`, `unsupportedImage` (any pixel not
    /// opaque, or a side above 65,535 pixels), `outputValidationFailed(findings:)` (the output check failed; no bytes
    /// are returned), `notEnoughMemory`; or `CancellationError` when the task is cancelled before the work starts.
    public static func encodeJPEG(_ image: CGImage, quality: Int = 90) async throws -> Data {
        guard (1...100).contains(quality) else { throw FaceMaskError.invalidConfiguration(parameter: "quality") }
        return try await Work.onQueue(Work.encoding) { () throws(FaceMaskError) in
            let canvas = try OwnedCanvas.draw(image)
            defer { canvas.discard() }
            let d = canvas.description
            let encoded = try kotlinCall {
                try FaceBlurIos.shared.encodeJpeg(address: d.address, width: d.width, height: d.height,
                                                  bytesPerRow: d.bytesPerRow, layout: d.layout.kotlin,
                                                  quality: Int32(quality))
            }
            var data = Data(count: Int(encoded.byteCount))
            try data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) throws(FaceMaskError) in
                guard let base = raw.baseAddress else { throw .internal }
                try kotlinCall {
                    try encoded.exportTo(address: Int64(Int(bitPattern: base)), capacity: Int64(raw.count))
                }
            }
            return data
        }
    }

    // MARK: File mode (ADR 0005): file URLs; JPEG or HEIC in, JPEG out.

    /// Decodes the file at its working size and detects faces; nothing is written. Runs on the masker's queue;
    /// coordinates are pixels of the working image (``Detection/width`` x ``Detection/height``). Throws
    /// ``FaceMaskError`` or `CancellationError`.
    public func detectFile(at source: URL, options: FileOptions = .default) async throws -> Detection {
        let path = try SecurityScope.path(source, parameter: "source")
        let k = handle.value
        return try await cancellable { token throws(FaceMaskError) in
            let o = try options.kotlin()
            return try SecurityScope.with(source) { () throws(FaceMaskError) in
                Detection(try kotlinCall { try k.detectFile(source: path, options: o, cancellation: token) })
            }
        }
    }

    /// Masks the file and writes a JPEG without metadata (unless `options` keeps an allow-list) to `target`. FaceBlur
    /// writes a temporary file of the masked output next to the destination and replaces the destination atomically;
    /// on any error nothing is kept and the destination is unchanged. Runs on the masker's queue; a `plan` must come
    /// from ``detectFile(at:options:)`` (or be derived from one with ``MaskPlan/withMasks(_:)``), in working-image
    /// pixels. Throws ``FaceMaskError`` or `CancellationError`.
    public func maskFile(at source: URL, to target: OutputTarget, options: FileOptions = .default,
                         plan: MaskPlan? = nil) async throws -> FileResult {
        let path = try SecurityScope.path(source, parameter: "source")
        let k = handle.value
        return try await cancellable { token throws(FaceMaskError) in
            let o = try options.kotlin()
            let p = try plan?.kotlinForFile()
            return try FileTarget.with(source: source, target: target) { (t) throws(FaceMaskError) in
                FileResult(try kotlinCall {
                    try k.maskFile(source: path, target: t, options: o, plan: p, cancellation: token)
                })
            }
        }
    }

    // MARK: Internals

    /// Test seam: puts `block` on the masker's queue, ahead of any call started after it (FIFO).
    nonisolated func enqueueForTesting(_ block: @escaping @Sendable () -> Void) { queue.async(execute: block) }

    /// Runs `body` with the library masker on the masker's queue, with task cancellation passed to the library.
    private nonisolated func run<T: Sendable>(
        _ body: @escaping @Sendable (FaceBlurCore.FaceMasker, Token) throws(FaceMaskError) -> T
    ) async throws -> T {
        let token = Token()
        let handle = handle
        return try await Work.onQueue(queue, token: token) { () throws(FaceMaskError) in
            try body(handle.value, token)
        }
    }

    /// Runs `body` on the masker's executor (this actor's queue) with task cancellation passed to the library.
    private func cancellable<T: Sendable>(_ body: (Token) throws(FaceMaskError) -> T) async throws -> T {
        let token = Token()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do { return try body(token) } catch { throw FaceMaskError.forAsync(error) }
        } onCancel: {
            token.cancel()
        }
    }

    /// Locks the pixel buffer for the call and unlocks it on every path.
    private nonisolated(nonsending) func locked<T: Sendable>(
        _ buffer: CVPixelBuffer, _ orientation: CGImagePropertyOrientation,
        _ body: (BufferDescription) async throws -> T
    ) async throws -> T {
        let number = Carriers.number(orientation)
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw FaceMaskError.unsupportedImage
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var d = try Carriers.describe(locked: buffer)
        d.orientation = number
        defer { withExtendedLifetime(buffer) {} }
        return try await body(d)
    }
}

/// The output target as the library sees it, with security-scoped access to the source and the target (or the
/// target's folder for a new file) for the duration of the call.
enum FileTarget {
    static func with<T>(source: URL, target: OutputTarget,
                        _ body: (FaceBlurCore.OutputTarget) throws(FaceMaskError) -> T) throws(FaceMaskError) -> T {
        switch target {
        case .overwriteSource:
            return try SecurityScope.with(source) { () throws(FaceMaskError) in
                try body(FaceBlurCore.OutputTarget.OverwriteSource.shared)
            }
        case let .newFile(url, replaceExisting):
            let path = try SecurityScope.path(url, parameter: "target")
            let k = FaceBlurCore.OutputTarget.NewFile(path: path, replaceExisting: replaceExisting)
            return try SecurityScope.with(source) { () throws(FaceMaskError) in
                try SecurityScope.with(url.deletingLastPathComponent()) { () throws(FaceMaskError) in try body(k) }
            }
        }
    }
}
