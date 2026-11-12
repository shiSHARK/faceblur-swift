// SPDX-License-Identifier: Apache-2.0
internal import FaceBlurCore
import Foundation

/// The only error type FaceBlur throws, apart from Swift's `CancellationError` from the async methods.
///
/// One case per error of the shared library, with its payload. Messages (``description``) are fixed English text
/// plus numbers: never a path, a file name, a pixel value or a coordinate.
///
/// - Important: After any error from an in-place method, the buffer must not be displayed, encoded or shared as
///   masked. After `CancellationError` treat the buffer as not masked: it is either untouched or fully masked, and the
///   caller cannot tell which.
/// - Note: New cases and new `findings` codes may appear in later versions. Treat every code as a failure, do not
///   match the `findings` lists exhaustively, and keep a `default` branch when you switch over this type.
public enum FaceMaskError: Error, Sendable, Hashable, CustomStringConvertible {
    /// A value is outside its allowed range; `parameter` is the name of the library parameter.
    case invalidConfiguration(parameter: String)
    /// The decoded image has more pixels than the limit.
    case imageTooLarge(width: Int, height: Int, limit: Int)
    /// A stream source is larger than the stream limit. Kept for the one-to-one rule; the Swift API has no stream
    /// form, so it is not thrown in practice.
    case sourceTooLarge(limitBytes: Int64)
    /// There was not enough memory; the image was not masked.
    case notEnoughMemory
    /// The image cannot be read or its pixel layout is not supported. Nothing was written.
    case unsupportedImage
    /// The output target cannot be used.
    case unsupportedTarget
    /// Reading or writing a file failed.
    case ioFailed
    /// The masked output failed the library's check before it was kept; nothing was kept.
    case outputValidationFailed(findings: [String])
    /// A mask plan does not belong to the image or file it was applied to. Nothing was written.
    case maskPlanMismatch
    /// The source file changed after its mask plan was made. Nothing was written.
    case sourceChanged
    /// Writing the masks failed after it started; discard the image.
    case maskWriteFailed
    /// The model's SHA-256 does not match the profile's expected value.
    case modelIntegrity
    /// The model was refused before the runtime saw it.
    case modelRejected(findings: [String])
    /// The model produced an output that does not match its profile.
    case modelOutputInvalid(findings: [String])
    /// The ONNX Runtime is not available, another runtime bridge was registered first, or the library binary does not
    /// match this facade.
    case runtimeUnavailable
    /// Two calls used one masker at the same time. Kept for the one-to-one rule; ``FaceMasker`` is an actor that runs
    /// calls one after another, so it is not thrown in practice.
    case concurrentUse
    /// The masker was closed.
    case closed
    /// The call was cancelled. Kept for the one-to-one rule; the async methods throw Swift's `CancellationError`.
    case cancelled
    /// An unexpected failure inside the library.
    case `internal`

    /// Fixed English text, without paths, file names, pixel data or coordinates.
    public var description: String {
        switch self {
        case let .invalidConfiguration(parameter): "Invalid value for '\(parameter)'"
        case let .imageTooLarge(width, height, limit):
            "Image of \(width) x \(height) pixels exceeds the limit of \(limit) pixels"
        case let .sourceTooLarge(limitBytes): "Source exceeds the limit of \(limitBytes) bytes"
        case .notEnoughMemory: "Not enough memory to mask the image; it was not masked"
        case .unsupportedImage: "Unsupported image"
        case .unsupportedTarget: "Unsupported target"
        case .ioFailed: "I/O failed"
        case let .outputValidationFailed(findings): "Output validation failed: \(findings.joined(separator: ","))"
        case .maskPlanMismatch: "The mask plan does not belong to this image; nothing was written"
        case .sourceChanged: "The source image changed after the mask plan was made; nothing was written"
        case .maskWriteFailed: "Writing masks into the image failed after it started; discard the image"
        case .modelIntegrity: "Model integrity check failed"
        case let .modelRejected(findings): "Model rejected: \(findings.joined(separator: ","))"
        case let .modelOutputInvalid(findings): "Model output invalid: \(findings.joined(separator: ","))"
        case .runtimeUnavailable: "ONNX Runtime unavailable"
        case .concurrentUse: "The masker is already in use by another call"
        case .closed: "The masker is closed"
        case .cancelled: "Cancelled"
        case .internal: "Internal error"
        }
    }
}

extension FaceMaskError {
    /// Maps an error from a Kotlin call by the Kotlin exception class (hand-written table, ADR 0011 decision 5). An
    /// error that is not a Kotlin `FaceMaskException` becomes `.internal`. Kotlin text is never carried over.
    static func from(_ error: any Error) -> FaceMaskError {
        if let mapped = error as? FaceMaskError { return mapped }
        guard let kotlin = (error as NSError).kotlinException else { return .internal }
        return from(kotlin: kotlin)
    }

    static func from(kotlin: Any) -> FaceMaskError {
        switch kotlin {
        case let e as FaceMaskException.InvalidConfiguration: .invalidConfiguration(parameter: e.parameter)
        case let e as FaceMaskException.ImageTooLarge:
            .imageTooLarge(width: Int(e.width), height: Int(e.height), limit: Int(clamping: e.limit))
        case let e as FaceMaskException.SourceTooLarge: .sourceTooLarge(limitBytes: e.limitBytes)
        case is FaceMaskException.NotEnoughMemory: .notEnoughMemory
        case is FaceMaskException.UnsupportedImage: .unsupportedImage
        case is FaceMaskException.UnsupportedTarget: .unsupportedTarget
        case is FaceMaskException.IoFailed: .ioFailed
        case let e as FaceMaskException.OutputValidationFailed: .outputValidationFailed(findings: e.findings)
        case is FaceMaskException.MaskPlanMismatch: .maskPlanMismatch
        case is FaceMaskException.SourceChanged: .sourceChanged
        case is FaceMaskException.MaskWriteFailed: .maskWriteFailed
        case is FaceMaskException.ModelIntegrity: .modelIntegrity
        case let e as FaceMaskException.ModelRejected: .modelRejected(findings: e.findings)
        case let e as FaceMaskException.ModelOutputInvalid: .modelOutputInvalid(findings: e.findings)
        case is FaceMaskException.RuntimeUnavailable: .runtimeUnavailable
        case is FaceMaskException.ConcurrentUse: .concurrentUse
        case is FaceMaskException.Closed: .closed
        case is FaceMaskException.Cancelled: .cancelled
        default: .internal
        }
    }

    /// The error an async method throws: Swift's `CancellationError` for a cancelled call, otherwise the mapped case.
    static func forAsync(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        let mapped = from(error)
        return mapped == .cancelled ? CancellationError() : mapped
    }
}

/// Runs a Kotlin call and maps whatever it throws to ``FaceMaskError``.
@inline(__always)
func kotlinCall<T>(_ body: () throws -> T) throws(FaceMaskError) -> T {
    do { return try body() } catch { throw FaceMaskError.from(error) }
}
