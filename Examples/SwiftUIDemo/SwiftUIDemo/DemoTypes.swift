// SPDX-License-Identifier: Apache-2.0
import Foundation
import UIKit

/// A model file the person picked, hashed but not loaded yet.
struct ModelCandidate: Equatable, Sendable {
    let url: URL
    let fileName: String
    let sizeBytes: Int64
    /// 64 lower-case hexadecimal digits.
    let sha256: String

    /// The hash in 4 lines of 16 digits, so it can be compared by eye or read out.
    var hashLines: [String] {
        let digits = Array(sha256)
        return stride(from: 0, to: digits.count, by: 16).map { String(digits[$0..<min($0 + 16, digits.count)]) }
    }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) }
}

/// A rectangle in pixels of the upright photo, origin at the top-left.
struct PixelRect: Equatable, Sendable {
    var left: Double, top: Double, right: Double, bottom: Double
    var width: Double { right - left }
    var height: Double { bottom - top }
    var centerX: Double { (left + right) / 2 }
    var centerY: Double { (top + bottom) / 2 }
}

/// The footprint of one mask in pixels of the upright photo.
struct MaskGeometry: Equatable, Sendable {
    var centerX: Double, centerY: Double, radiusX: Double, radiusY: Double
    var isEllipse: Bool
    var bounds: PixelRect {
        PixelRect(left: centerX - radiusX, top: centerY - radiusY, right: centerX + radiusX, bottom: centerY + radiusY)
    }
}

struct DetectedFace: Equatable, Sendable {
    let box: PixelRect
    let score: Double
}

/// What the person sees after the photo was prepared. The preview is the upright photo, not a masked copy.
struct PhotoInfo: Sendable {
    let width: Int
    let height: Int
    let preview: UIImage
}

struct DetectionSummary: Equatable, Sendable {
    let faces: [DetectedFace]
    /// One mask per face, in the same order as `faces`.
    let masks: [MaskGeometry]
}

/// What goes into the saved photo: a mask the library drew for a detected face, or one the person added.
enum MaskSpec: Equatable, Sendable {
    case detected(planIndex: Int)
    case added(PixelRect)
}

struct EncodedJPEG: Equatable, Sendable {
    let data: Data
    let maskCount: Int
}

/// Why a step failed, in terms the screen can explain. The engine maps every library error to one of these.
enum DemoFailure: Error, Equatable, Sendable {
    case modelFileUnreadable
    case modelFileUnsuitable
    case modelDoesNotMatch
    case modelRejected
    case runtimeUnavailable
    case photoUnreadable
    case photoTooLarge
    case notEnoughMemory
    case outputCheckFailed
    case other
}

/// One mask in the review list.
struct MaskItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case detected(faceIndex: Int, score: Double)
        case added(box: PixelRect)
    }

    let id: Int
    var kind: Kind
    var geometry: MaskGeometry
    var isOn: Bool

    var isAdded: Bool {
        if case .added = kind { return true }
        return false
    }
}

/// The work the view model asks for. The real implementation uses only the public FaceBlur API; tests use a fake.
protocol MaskingEngine: Sendable {
    /// Hashes the file. Throws ``DemoFailure``.
    func inspectModel(at url: URL) async throws -> ModelCandidate
    /// Loads the model with the hash the person confirmed. Throws ``DemoFailure``.
    func loadModel(_ candidate: ModelCandidate) async throws
    /// Draws the photo upright (orientation applied) and keeps only that. Throws ``DemoFailure``.
    func preparePhoto(_ data: Data) async throws -> PhotoInfo
    /// Detects faces in the prepared photo. Throws ``DemoFailure`` or `CancellationError`.
    func detect() async throws -> DetectionSummary
    /// The mask that a box the person added would get.
    func geometry(forAdded box: PixelRect) async throws -> MaskGeometry
    /// Masks a fresh copy of the prepared photo and returns it as a JPEG without metadata.
    func maskAndEncode(_ specs: [MaskSpec]) async throws -> EncodedJPEG
    /// Forgets the prepared photo.
    func discardPhoto() async
}
