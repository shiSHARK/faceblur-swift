// SPDX-License-Identifier: Apache-2.0
import Foundation
import UIKit
@testable import SwiftUIDemo

/// A scripted engine for the view-model tests. It records what the view model asked for.
actor FakeEngine: MaskingEngine {
    var candidate = ModelCandidate(
        url: URL(fileURLWithPath: "/model.onnx"), fileName: "model.onnx", sizeBytes: 232_589,
        sha256: "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4")
    var inspectError: (any Error)?
    var loadError: (any Error)?
    var prepareError: (any Error)?
    var detectError: (any Error)?
    var saveError: (any Error)?
    var summary = DetectionSummary(
        faces: [DetectedFace(box: PixelRect(left: 40, top: 30, right: 80, bottom: 90), score: 0.9)],
        masks: [MaskGeometry(centerX: 60, centerY: 60, radiusX: 30, radiusY: 50, isEllipse: true)])
    var photoSize = (width: 200, height: 100)

    /// While true, `detect` and `maskAndEncode` wait (and notice cancellation unless `ignoreCancellation`).
    var hold = false
    var ignoreCancellation = false

    private(set) var inspected: [URL] = []
    private(set) var loaded: [ModelCandidate] = []
    private(set) var prepared = 0
    private(set) var saved: [[MaskSpec]] = []
    private(set) var discards = 0
    private(set) var geometryRequests: [PixelRect] = []
    private(set) var threadWasMain: [Bool] = []

    func configure(_ change: @Sendable (isolated FakeEngine) -> Void) { change(self) }

    func inspectModel(at url: URL) async throws -> ModelCandidate {
        threadWasMain.append(runsOnMainThread())
        inspected.append(url)
        if let inspectError { throw inspectError }
        return candidate
    }

    func loadModel(_ candidate: ModelCandidate) async throws {
        threadWasMain.append(runsOnMainThread())
        loaded.append(candidate)
        if let loadError { throw loadError }
    }

    func preparePhoto(_ data: Data) async throws -> PhotoInfo {
        threadWasMain.append(runsOnMainThread())
        prepared += 1
        if let prepareError { throw prepareError }
        return PhotoInfo(width: photoSize.width, height: photoSize.height, preview: UIImage())
    }

    func detect() async throws -> DetectionSummary {
        threadWasMain.append(runsOnMainThread())
        try await waitWhileHeld()
        if let detectError { throw detectError }
        return summary
    }

    func geometry(forAdded box: PixelRect) async throws -> MaskGeometry {
        geometryRequests.append(box)
        // A recognisable answer: the box grown by one pixel on every side.
        return MaskGeometry(centerX: box.centerX, centerY: box.centerY, radiusX: box.width / 2 + 1,
                            radiusY: box.height / 2 + 1, isEllipse: true)
    }

    func maskAndEncode(_ specs: [MaskSpec]) async throws -> EncodedJPEG {
        threadWasMain.append(runsOnMainThread())
        saved.append(specs)
        try await waitWhileHeld()
        if let saveError { throw saveError }
        return EncodedJPEG(data: Data([0xFF, 0xD8, 0xFF, 0xD9]), maskCount: specs.count)
    }

    func discardPhoto() async { discards += 1 }

    func release() { hold = false }

    private func waitWhileHeld() async throws {
        while hold {
            if ignoreCancellation { await Task.yield() } else { try await Task.sleep(for: .milliseconds(5)) }
        }
    }
}

/// True when called on the main thread (a plain function, so it can be used from async code).
func runsOnMainThread() -> Bool { pthread_main_np() != 0 }
