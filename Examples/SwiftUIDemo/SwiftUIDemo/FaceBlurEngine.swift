// SPDX-License-Identifier: Apache-2.0
import CryptoKit
import FaceBlur
import Foundation
import UIKit

/// The only file that calls FaceBlur, and only its public Swift API: `DetectorModel`, `FaceMasker`, `Detection`,
/// `MaskPlan`, `Mask` and `FaceMaskError`. It keeps the model, the masker and the upright photo; the photo is
/// copied into a fresh bitmap for every detection and every save, so edits never stack on masked pixels.
actor FaceBlurEngine: MaskingEngine {
    /// The size limit for a model file in this demo (the library's default).
    static let maxModelBytes = Int64(DetectorModel.defaultMaxModelBytes)

    private var masker: FaceMasker?
    private var upright: CGImage?
    private var plan: MaskPlan?

    // MARK: Model

    func inspectModel(at url: URL) async throws -> ModelCandidate {
        try await Self.hash(url)
    }

    /// Reads the file in chunks, off the actor, and never keeps its bytes.
    @concurrent
    private static func hash(_ url: URL) async throws -> ModelCandidate {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size: Int64
        do {
            size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        } catch {
            throw DemoFailure.modelFileUnreadable
        }
        guard size > 0, size <= maxModelBytes else { throw DemoFailure.modelFileUnsuitable }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch { throw DemoFailure.modelFileUnreadable }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DemoFailure.modelFileUnreadable
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ModelCandidate(url: url, fileName: url.lastPathComponent, sizeBytes: size, sha256: digest)
    }

    func loadModel(_ candidate: ModelCandidate) async throws {
        masker?.close()
        masker = nil
        do {
            // The profile carries the hash the person confirmed: the library refuses any other bytes.
            let profile = try DetectorProfile(format: .yuNetLayout, inputWidth: 640, inputHeight: 640,
                                              scoreThreshold: 0.5, expectedSHA256: candidate.sha256)
            let model = try await DetectorModel(source: .file(candidate.url), profile: profile)
            masker = try await FaceMasker(model: model)
        } catch {
            throw Self.map(error)
        }
    }

    // MARK: Photo

    func preparePhoto(_ data: Data) async throws -> PhotoInfo {
        let rendered = try await Self.render(data)
        guard let cgImage = rendered.cgImage else { throw DemoFailure.photoUnreadable }
        upright = cgImage
        plan = nil
        return PhotoInfo(width: cgImage.width, height: cgImage.height, preview: rendered)
    }

    @concurrent
    private static func render(_ data: Data) async throws -> UIImage {
        guard let photo = UIImage(data: data) else { throw DemoFailure.photoUnreadable }
        guard let upright = PhotoPixels.uprightImage(from: photo) else { throw DemoFailure.photoUnreadable }
        return upright
    }

    func detect() async throws -> DetectionSummary {
        guard let masker, let upright, let context = PhotoPixels.makeContext(from: upright) else {
            throw DemoFailure.other
        }
        do {
            let found = try await masker.detect(context)
            let faceMasks = try found.toMaskPlan()
            plan = faceMasks
            return DetectionSummary(
                faces: found.faces.map { DetectedFace(box: Self.rect($0), score: Double($0.score)) },
                masks: faceMasks.masks.map(Self.geometry))
        } catch {
            throw Self.map(error)
        }
    }

    func geometry(forAdded box: PixelRect) async throws -> MaskGeometry {
        do { return Self.geometry(try Self.mask(for: box)) } catch { throw Self.map(error) }
    }

    func maskAndEncode(_ specs: [MaskSpec]) async throws -> EncodedJPEG {
        guard let masker, let upright, let plan, let context = PhotoPixels.makeContext(from: upright) else {
            throw DemoFailure.other
        }
        do {
            let masks: [Mask] = try specs.map { spec in
                switch spec {
                case let .detected(index):
                    guard plan.masks.indices.contains(index) else { throw DemoFailure.other }
                    return plan.masks[index]
                case let .added(box):
                    return try Self.mask(for: box)
                }
            }
            let result = try await masker.applyMasks(try plan.withMasks(masks), to: context)
            // Fail closed: every mask the person kept must be in the result before anything is encoded.
            guard result.masks.count == masks.count, let masked = context.makeImage(),
                  let data = PhotoPixels.jpegData(from: masked) else { throw DemoFailure.outputCheckFailed }
            return EncodedJPEG(data: data, maskCount: result.masks.count)
        } catch {
            throw Self.map(error)
        }
    }

    func discardPhoto() async {
        upright = nil
        plan = nil
    }

    // MARK: Mapping

    private static func mask(for box: PixelRect) throws -> Mask {
        try Mask.manual(left: Float(box.left), top: Float(box.top), right: Float(box.right), bottom: Float(box.bottom))
    }

    private static func rect(_ face: FaceBox) -> PixelRect {
        PixelRect(left: Double(face.left), top: Double(face.top), right: Double(face.right), bottom: Double(face.bottom))
    }

    private static func geometry(_ mask: Mask) -> MaskGeometry {
        MaskGeometry(centerX: Double(mask.centerX), centerY: Double(mask.centerY), radiusX: Double(mask.radiusX),
                     radiusY: Double(mask.radiusY), isEllipse: mask.shape == .ellipse)
    }

    /// Every library error becomes a fixed demo failure: the demo shows its own wording and never the library's
    /// text, a finding list or a path.
    static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let failure = error as? DemoFailure { return failure }
        guard let error = error as? FaceMaskError else { return DemoFailure.other }
        switch error {
        case .cancelled: return CancellationError()
        case .modelIntegrity: return DemoFailure.modelDoesNotMatch
        case .modelRejected, .modelOutputInvalid: return DemoFailure.modelRejected
        case .runtimeUnavailable: return DemoFailure.runtimeUnavailable
        case .ioFailed: return DemoFailure.modelFileUnreadable
        case .imageTooLarge, .sourceTooLarge: return DemoFailure.photoTooLarge
        case .unsupportedImage: return DemoFailure.photoUnreadable
        case .notEnoughMemory: return DemoFailure.notEnoughMemory
        case .outputValidationFailed, .maskWriteFailed: return DemoFailure.outputCheckFailed
        default: return DemoFailure.other
        }
    }
}
