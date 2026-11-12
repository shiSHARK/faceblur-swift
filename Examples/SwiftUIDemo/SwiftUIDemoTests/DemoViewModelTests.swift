// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import SwiftUIDemo

@MainActor
final class DemoViewModelTests: XCTestCase {
    private let modelURL = URL(fileURLWithPath: "/model.onnx")

    private func make() -> (DemoViewModel, FakeEngine) {
        let engine = FakeEngine()
        return (DemoViewModel(engine: engine), engine)
    }

    private func waitFor(_ model: DemoViewModel, _ stage: DemoViewModel.Stage, file: StaticString = #filePath,
                         line: UInt = #line) async {
        for _ in 0..<400 where model.stage != stage { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.stage, stage, file: file, line: line)
    }

    /// Model chosen, confirmed and loaded.
    private func loadedModel() async -> (DemoViewModel, FakeEngine) {
        let (model, engine) = make()
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .confirmModel)
        model.confirmModel()
        await waitFor(model, .choosePhoto)
        return (model, engine)
    }

    /// A photo with one detected face in review.
    private func reviewing() async -> (DemoViewModel, FakeEngine) {
        let (model, engine) = await loadedModel()
        model.photoPicked(Data([1]))
        await waitFor(model, .review)
        return (model, engine)
    }

    // MARK: Model step

    func testPhotoStepIsDisabledUntilAModelIsLoaded() async {
        let (model, engine) = make()
        XCTAssertFalse(model.canChoosePhoto)
        model.photoPicked(Data([1]))
        XCTAssertEqual(model.stage, .chooseModel)
        let prepared = await engine.prepared
        XCTAssertEqual(prepared, 0)
    }

    func testPickedModelIsShownAndLoadsOnlyAfterConfirmation() async {
        let (model, engine) = make()
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .confirmModel)
        XCTAssertEqual(model.candidate?.hashLines.count, 4)
        XCTAssertTrue(model.candidate?.hashLines.allSatisfy { $0.count == 16 } ?? false)
        let loadedBefore = await engine.loaded
        XCTAssertTrue(loadedBefore.isEmpty, "nothing may load before the person confirms")
        model.confirmModel()
        await waitFor(model, .choosePhoto)
        let loadedAfter = await engine.loaded
        let expected = await engine.candidate.sha256
        XCTAssertEqual(loadedAfter.map(\.sha256), [expected], "the confirmed hash is passed on")
        XCTAssertTrue(model.canChoosePhoto)
        XCTAssertEqual(model.loadedModelName, "model.onnx")
    }

    func testCancellingTheConfirmationLoadsNothing() async {
        let (model, engine) = make()
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .confirmModel)
        model.cancelModelConfirmation()
        XCTAssertEqual(model.stage, .chooseModel)
        XCTAssertNil(model.candidate)
        XCTAssertFalse(model.modelLoaded)
        let loaded = await engine.loaded
        XCTAssertTrue(loaded.isEmpty)
    }

    func testClosingTheFilePickerIsNotAFailure() {
        let (model, _) = make()
        model.modelFilePicked(.failure(CocoaError(.userCancelled)))
        XCTAssertEqual(model.stage, .chooseModel)
    }

    func testAnOtherPickerErrorIsAFixedFailure() {
        let (model, _) = make()
        model.modelFilePicked(.failure(CocoaError(.fileReadNoPermission)))
        XCTAssertEqual(model.failure, .modelFileUnreadable)
        XCTAssertEqual(model.status, Copy.message(for: .modelFileUnreadable))
    }

    func testHashFailureShowsTheFailure() async {
        let (model, engine) = make()
        await engine.configure { $0.inspectError = DemoFailure.modelFileUnsuitable }
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .failed(.modelFileUnsuitable))
        XCTAssertFalse(model.modelLoaded)
    }

    func testAModelThatDoesNotMatchLeavesNothingLoaded() async {
        let (model, engine) = make()
        await engine.configure { $0.loadError = DemoFailure.modelDoesNotMatch }
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .confirmModel)
        model.confirmModel()
        await waitFor(model, .failed(.modelDoesNotMatch))
        XCTAssertFalse(model.modelLoaded)
        XCTAssertNil(model.candidate)
        XCTAssertFalse(model.canChoosePhoto)
        model.dismissFailure()
        XCTAssertEqual(model.stage, .chooseModel)
    }

    func testModelLoadingCannotBeCancelled() async {
        let (model, _) = make()
        model.modelFilePicked(.success(modelURL))
        await waitFor(model, .confirmModel)
        model.confirmModel()
        XCTAssertEqual(model.stage, .loadingModel)
        XCTAssertFalse(model.canCancel)
        XCTAssertTrue(model.cancelBlockedByModelLoading)
        model.cancelRun()
        await waitFor(model, .choosePhoto)
    }

    // MARK: Detection and review

    func testDetectionFillsTheReview() async {
        let (model, engine) = await reviewing()
        XCTAssertEqual(model.faces.count, 1)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertTrue(model.items[0].isOn)
        XCTAssertEqual(model.summary, "1 face detected, 1 mask will be applied")
        let prepared = await engine.prepared
        XCTAssertEqual(prepared, 1)
    }

    func testNoFacesStillReachesTheReview() async {
        let (model, engine) = await loadedModel()
        await engine.configure { $0.summary = DetectionSummary(faces: [], masks: []) }
        model.photoPicked(Data([1]))
        await waitFor(model, .review)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.summary, "0 faces detected, 0 masks will be applied")
    }

    func testFacesAndMasksThatDoNotMatchFailClosed() async {
        let (model, engine) = await loadedModel()
        await engine.configure {
            $0.summary = DetectionSummary(faces: $0.summary.faces, masks: [])
        }
        model.photoPicked(Data([1]))
        await waitFor(model, .failed(.other))
        XCTAssertNil(model.photo)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testAnUnreadablePhotoFails() async {
        let (model, engine) = await loadedModel()
        await engine.configure { $0.prepareError = DemoFailure.photoUnreadable }
        model.photoPicked(Data([1]))
        await waitFor(model, .failed(.photoUnreadable))
        model.dismissFailure()
        XCTAssertEqual(model.stage, .choosePhoto)
    }

    func testAPickerThatReturnsNoDataFails() async {
        let (model, _) = await loadedModel()
        model.photoPicked(nil)
        XCTAssertEqual(model.failure, .photoUnreadable)
    }

    func testEngineWorkRunsOffTheMainThread() async {
        let (model, engine) = await reviewing()
        model.save()
        await waitFor(model, .saved)
        let flags = await engine.threadWasMain
        XCTAssertFalse(flags.isEmpty)
        XCTAssertFalse(flags.contains(true), "hashing, loading, decoding, detecting and saving stay off the main thread")
    }

    func testCancelDuringDetectionReturnsToThePhotoStepAndDropsThePhoto() async {
        let (model, engine) = await loadedModel()
        await engine.configure { $0.hold = true }
        model.photoPicked(Data([1]))
        await waitFor(model, .detecting)
        XCTAssertTrue(model.canCancel)
        model.cancelRun()
        await waitFor(model, .choosePhoto)
        XCTAssertEqual(model.status, Copy.cancelled)
        XCTAssertNil(model.photo)
        let discards = await engine.discards
        XCTAssertEqual(discards, 1)
    }

    // MARK: Editing

    func testRemoveAndRestoreAMaskAndUndo() async {
        let (model, _) = await reviewing()
        let id = model.items[0].id
        model.toggle(id)
        XCTAssertFalse(model.items[0].isOn)
        XCTAssertEqual(model.activeMaskCount, 0)
        model.toggle(id)
        XCTAssertTrue(model.items[0].isOn)
        model.toggle(id)
        model.undo()
        XCTAssertTrue(model.items[0].isOn, "one undo step takes back one edit")
        model.undo()
        XCTAssertFalse(model.items[0].isOn)
        model.undo()
        XCTAssertTrue(model.items[0].isOn)
        XCTAssertFalse(model.canUndo)
    }

    func testAddingAMaskUsesTheEnginesGeometry() async {
        let (model, engine) = await reviewing()
        model.addMask()
        XCTAssertEqual(model.items.count, 2)
        XCTAssertTrue(model.items[1].isAdded)
        for _ in 0..<200 where await engine.geometryRequests.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        guard case let .added(box) = model.items[1].kind else { return XCTFail("added mask expected") }
        for _ in 0..<200 where model.items[1].geometry.radiusX != box.width / 2 + 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.items[1].geometry.radiusX, box.width / 2 + 1)
        XCTAssertEqual(box.width, 20, accuracy: 0.001, "20 % of the shorter side (100 px)")
        XCTAssertEqual(box.centerX, 100, accuracy: 0.001)
    }

    func testMoveAndResizeStayInsideThePhoto() async {
        let (model, _) = await reviewing()
        model.addMask()
        let id = model.items[1].id
        for _ in 0..<200 { model.move(id, .left) }
        guard case let .added(left) = model.items[1].kind else { return XCTFail("added mask expected") }
        XCTAssertEqual(left.left, 0, accuracy: 0.001)
        XCTAssertEqual(left.width, 20, accuracy: 0.001, "moving does not change the size")
        for _ in 0..<200 { model.resize(id, larger: true) }
        guard case let .added(big) = model.items[1].kind else { return XCTFail("added mask expected") }
        XCTAssertLessThanOrEqual(big.width, 200)
        XCTAssertLessThanOrEqual(big.height, 100)
        for _ in 0..<400 { model.resize(id, larger: false) }
        guard case let .added(small) = model.items[1].kind else { return XCTFail("added mask expected") }
        XCTAssertGreaterThanOrEqual(small.width, 16, "a mask cannot shrink to nothing")
    }

    func testDetectedMasksCannotBeDeletedOrMoved() async {
        let (model, _) = await reviewing()
        let id = model.items[0].id
        let before = model.items
        model.deleteAdded(id)
        model.move(id, .left)
        model.resize(id, larger: true)
        XCTAssertEqual(model.items, before)
        XCTAssertFalse(model.canUndo)
    }

    func testDeletingAnAddedMaskCanBeUndone() async {
        let (model, _) = await reviewing()
        model.addMask()
        let id = model.items[1].id
        model.deleteAdded(id)
        XCTAssertEqual(model.items.count, 1)
        model.undo()
        XCTAssertEqual(model.items.count, 2)
    }

    func testClampKeepsTheSizeWhereItFits() {
        let r = DemoViewModel.clamp(PixelRect(left: -10, top: 90, right: 10, bottom: 110), width: 200, height: 100)
        XCTAssertEqual(r, PixelRect(left: 0, top: 80, right: 20, bottom: 100))
    }

    // MARK: Save

    func testSavePassesOnlyTheMasksThatAreOn() async {
        let (model, engine) = await reviewing()
        model.addMask()
        model.toggle(model.items[0].id)
        model.save()
        await waitFor(model, .saved)
        let saved = await engine.saved
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved[0].count, 1)
        guard case .added = saved[0][0] else { return XCTFail("only the added mask was left on") }
        XCTAssertEqual(model.jpeg?.maskCount, 1)
        XCTAssertTrue(model.isExporting)
        XCTAssertEqual(model.status, Copy.masksApplied(masks: 1))
    }

    func testSaveWithoutAnyMaskIsAllowedAndSaysSo() async {
        let (model, engine) = await reviewing()
        model.toggle(model.items[0].id)
        XCTAssertEqual(model.activeMaskCount, 0)
        model.save()
        await waitFor(model, .saved)
        let saved = await engine.saved
        XCTAssertEqual(saved, [[]])
    }

    func testSaveFailureReturnsToTheReview() async {
        let (model, engine) = await reviewing()
        await engine.configure { $0.saveError = DemoFailure.notEnoughMemory }
        model.save()
        await waitFor(model, .failed(.notEnoughMemory))
        XCTAssertNil(model.jpeg)
        XCTAssertFalse(model.isExporting)
        model.dismissFailure()
        XCTAssertEqual(model.stage, .review)
        XCTAssertEqual(model.items.count, 1)
    }

    func testCancelBeforeTheWriteEndsWithNothingChanged() async {
        let (model, engine) = await reviewing()
        await engine.configure { $0.hold = true }
        model.save()
        await waitFor(model, .saving)
        model.cancelRun()
        await waitFor(model, .review)
        XCTAssertEqual(model.status, Copy.cancelled)
        XCTAssertNil(model.jpeg)
        XCTAssertFalse(model.isExporting)
    }

    func testALateCancelIsReportedFromTheOutcome() async {
        let (model, engine) = await reviewing()
        await engine.configure { $0.hold = true; $0.ignoreCancellation = true }
        model.save()
        await waitFor(model, .saving)
        model.cancelRun()
        await engine.release()
        await waitFor(model, .saved)
        XCTAssertEqual(model.status, Copy.tooLateToCancel)
        XCTAssertNotNil(model.jpeg, "the masks were applied, so the demo must not say it was cancelled")
    }

    func testExportOutcomeIsReportedWithoutNamesOrPlaces() async {
        let (model, _) = await reviewing()
        model.save()
        await waitFor(model, .saved)
        model.exportFinished(.success(URL(fileURLWithPath: "/private/place/name.jpg")))
        XCTAssertEqual(model.status, "Saved. 1 mask applied.")
        XCTAssertFalse(model.status.contains("name"))
        model.exportCancelled()
        XCTAssertEqual(model.status, Copy.notSaved)
        model.exportFinished(.failure(CocoaError(.fileWriteUnknown)))
        XCTAssertEqual(model.status, Copy.notSaved)
        model.presentExporterAgain()
        XCTAssertTrue(model.isExporting)
    }

    func testStartOverForgetsThePhotoAndTheJPEG() async {
        let (model, engine) = await reviewing()
        model.save()
        await waitFor(model, .saved)
        model.startOver()
        XCTAssertEqual(model.stage, .choosePhoto)
        XCTAssertNil(model.photo)
        XCTAssertNil(model.jpeg)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isExporting)
        for _ in 0..<200 where await engine.discards == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        let discards = await engine.discards
        XCTAssertGreaterThanOrEqual(discards, 1)
        XCTAssertTrue(model.modelLoaded, "the model stays loaded for the next photo")
    }

    func testEveryFailureHasFixedWording() {
        let all: [DemoFailure] = [
            .modelFileUnreadable, .modelFileUnsuitable, .modelDoesNotMatch, .modelRejected, .runtimeUnavailable,
            .photoUnreadable, .photoTooLarge, .notEnoughMemory, .outputCheckFailed, .other,
        ]
        XCTAssertEqual(Set(all.map(Copy.message)).count, all.count)
    }
}
