// SPDX-License-Identifier: Apache-2.0
import Foundation
import Observation

/// The screen state. All work runs in the engine, off the main thread; this class only holds state and orders the
/// steps. It never logs and keeps no copy of a photo: the engine owns the pixels and drops them on `startOver()`.
@MainActor
@Observable
final class DemoViewModel {
    enum Stage: Equatable {
        case chooseModel, hashingModel, confirmModel, loadingModel
        case choosePhoto, preparingPhoto, detecting, review, saving, saved
        case failed(DemoFailure)
    }

    private(set) var stage: Stage = .chooseModel
    private(set) var candidate: ModelCandidate?
    private(set) var loadedModelName: String?
    private(set) var photo: PhotoInfo?
    private(set) var faces: [DetectedFace] = []
    private(set) var items: [MaskItem] = []
    private(set) var jpeg: EncodedJPEG?
    /// The sentence for the status line and for the screen reader. Every assignment bumps `statusSerial`, so the
    /// same sentence set twice (a second "cannot move any further") is announced twice.
    private(set) var status = "" {
        didSet { statusSerial &+= 1 }
    }
    private(set) var statusSerial = 0
    /// Where the screen reader's focus should go after the last change (nil until the first change).
    private(set) var focusRequest: FocusRequest?
    /// Bound to the system file exporter.
    var isExporting = false

    private let engine: MaskingEngine
    private var task: Task<Void, Never>?
    private var undoStack: [[MaskItem]] = []
    private var nextItemID = 1
    private var generation = 0
    private let undoLimit = 50
    private var hasReview = false
    private var focusSerial = 0

    init(engine: MaskingEngine) {
        self.engine = engine
    }

    // MARK: Derived state

    var modelLoaded: Bool { loadedModelName != nil }
    var isBusy: Bool {
        switch stage {
        case .hashingModel, .loadingModel, .preparingPhoto, .detecting, .saving: true
        default: false
        }
    }
    var canChoosePhoto: Bool { modelLoaded && !isBusy && stage != .confirmModel }
    var canChooseModel: Bool { !isBusy }
    var canCancel: Bool {
        switch stage {
        case .hashingModel, .preparingPhoto, .detecting, .saving: true
        default: false
        }
    }
    /// Model loading cannot be cancelled once the runtime starts.
    var cancelBlockedByModelLoading: Bool { stage == .loadingModel }
    var activeMaskCount: Int { items.filter(\.isOn).count }
    var canUndo: Bool { !undoStack.isEmpty }
    var canSave: Bool { stage == .review }
    /// True when a section on the screen already shows the status sentence, so the status line under the content
    /// would repeat it (and the screen reader would read it twice). The sentence is still announced.
    var statusRepeatsScreenText: Bool {
        switch stage {
        case .hashingModel, .loadingModel, .preparingPhoto, .detecting, .failed: true
        case .confirmModel: status == Copy.confirmHint
        case .choosePhoto: loadedModelName.map { status == Copy.modelLoaded(name: $0) } ?? false
        case .review: status == summary
        case .chooseModel, .saving, .saved: false
        }
    }
    var failure: DemoFailure? {
        if case let .failed(f) = stage { return f }
        return nil
    }

    // MARK: Model step

    func modelFilePicked(_ result: Result<URL, any Error>) {
        guard canChooseModel else { return }
        switch result {
        case let .failure(error):
            // The person closing the picker is not a failure.
            if (error as? CocoaError)?.code == .userCancelled { return }
            fail(.modelFileUnreadable)
        case let .success(url):
            stage = .hashingModel
            status = Copy.hashing
            let engine = engine
            launch { [self] in
                do {
                    let found = try await engine.inspectModel(at: url)
                    candidate = found
                    stage = .confirmModel
                    status = Copy.confirmHint
                } catch is CancellationError {
                    finishCancelled(backTo: modelLoaded ? .choosePhoto : .chooseModel)
                } catch {
                    fail(Self.failure(from: error))
                }
            }
        }
    }

    /// The only path that loads a model, and only with the hash that was shown.
    func confirmModel() {
        guard stage == .confirmModel, let candidate else { return }
        stage = .loadingModel
        status = Copy.modelLoadingNoCancel
        let engine = engine
        launch { [self] in
            do {
                try await engine.loadModel(candidate)
                loadedModelName = candidate.fileName
                stage = .choosePhoto
                status = Copy.modelLoaded(name: candidate.fileName)
                focus(.photoHeading)
            } catch {
                self.candidate = nil
                fail(Self.failure(from: error))
            }
        }
    }

    /// Every way out of the confirmation loads nothing.
    func cancelModelConfirmation() {
        guard stage == .confirmModel else { return }
        candidate = nil
        stage = modelLoaded ? .choosePhoto : .chooseModel
        status = Copy.cancelled
        focus(modelLoaded ? .photoHeading : .modelHeading)
    }

    // MARK: Photo step

    func photoPicked(_ data: Data?) {
        guard canChoosePhoto else { return }
        guard let data else {
            fail(.photoUnreadable)
            return
        }
        resetPhotoState()
        stage = .preparingPhoto
        status = Copy.preparing
        let engine = engine
        launch { [self] in
            do {
                let prepared = try await engine.preparePhoto(data)
                photo = prepared
                stage = .detecting
                status = Copy.detecting
                let found = try await engine.detect()
                try Task.checkCancellation()
                guard found.faces.count == found.masks.count else { throw DemoFailure.other }
                faces = found.faces
                items = found.faces.indices.map { i in
                    defer { nextItemID += 1 }
                    return MaskItem(id: nextItemID, kind: .detected(faceIndex: i, score: found.faces[i].score),
                                    geometry: found.masks[i], isOn: true)
                }
                hasReview = true
                stage = .review
                status = summary
                focus(.reviewHeading)
            } catch is CancellationError {
                await engine.discardPhoto()
                resetPhotoState()
                finishCancelled(backTo: .choosePhoto)
            } catch {
                await engine.discardPhoto()
                resetPhotoState()
                fail(Self.failure(from: error))
            }
        }
    }

    func cancelRun() {
        guard canCancel else { return }
        task?.cancel()
    }

    // MARK: Editing (buttons only)

    var summary: String { Copy.facesAndMasks(faces: faces.count, masks: activeMaskCount) }

    func toggle(_ id: Int) {
        guard stage == .review, let index = items.firstIndex(where: { $0.id == id }) else { return }
        pushUndo()
        items[index].isOn.toggle()
        status = summary
    }

    func addMask() {
        guard stage == .review, let photo else { return }
        let side = Double(min(photo.width, photo.height)) * 0.2
        let cx = Double(photo.width) / 2, cy = Double(photo.height) / 2
        let box = PixelRect(left: cx - side / 2, top: cy - side / 2, right: cx + side / 2, bottom: cy + side / 2)
        pushUndo()
        let id = nextItemID
        nextItemID += 1
        // The geometry is a placeholder until the engine answers with the real mask for the box.
        items.append(MaskItem(id: id, kind: .added(box: box),
                              geometry: MaskGeometry(centerX: box.centerX, centerY: box.centerY,
                                                     radiusX: side / 2, radiusY: side / 2, isEllipse: true),
                              isOn: true))
        status = summary
        // The new row is at the end of the list, below the button that was just pressed: take the focus to it.
        focus(.maskTitle(id))
        refreshGeometry(id)
    }

    enum Direction { case left, right, up, down }

    func move(_ id: Int, _ direction: Direction) {
        guard let photo else { return }
        let step = Double(min(photo.width, photo.height)) * 0.02
        let outcome = edit(id) { box in
            var moved = box
            switch direction {
            case .left: moved.left -= step; moved.right -= step
            case .right: moved.left += step; moved.right += step
            case .up: moved.top -= step; moved.bottom -= step
            case .down: moved.top += step; moved.bottom += step
            }
            return Self.clamp(moved, width: photo.width, height: photo.height)
        }
        guard let number = maskNumber(id) else { return }
        switch outcome {
        case .notEditable: break
        case .unchanged:
            let action = switch direction {
            case .left: "move left"
            case .right: "move right"
            case .up: "move up"
            case .down: "move down"
            }
            status = Copy.maskAtLimit(number: number, action: action)
        case let .changed(box):
            status = Copy.maskMoved(number: number, x: Self.percent(box.centerX, of: photo.width),
                                    y: Self.percent(box.centerY, of: photo.height))
        }
    }

    func resize(_ id: Int, larger: Bool) {
        guard let photo else { return }
        let factor = larger ? 1.1 : 1 / 1.1
        let minimum = max(16.0, Double(min(photo.width, photo.height)) * 0.02)
        let outcome = edit(id) { box in
            let w = max(minimum, box.width * factor), h = max(minimum, box.height * factor)
            let scaled = PixelRect(left: box.centerX - w / 2, top: box.centerY - h / 2,
                                   right: box.centerX + w / 2, bottom: box.centerY + h / 2)
            return Self.clamp(scaled, width: photo.width, height: photo.height)
        }
        guard let number = maskNumber(id) else { return }
        switch outcome {
        case .notEditable: break
        case .unchanged: status = Copy.maskAtLimit(number: number, action: larger ? "get larger" : "get smaller")
        case let .changed(box):
            status = Copy.maskResized(number: number, width: Self.percent(box.width, of: photo.width),
                                      height: Self.percent(box.height, of: photo.height))
        }
    }

    func deleteAdded(_ id: Int) {
        guard stage == .review, let index = items.firstIndex(where: { $0.id == id }), items[index].isAdded else { return }
        pushUndo()
        items.remove(at: index)
        status = summary
        focus(.masksHeading) // the focused Delete button is gone
    }

    func undo() {
        guard stage == .review, let previous = undoStack.popLast() else { return }
        items = previous
        status = summary
    }

    private enum EditOutcome { case notEditable, unchanged, changed(PixelRect) }

    private func edit(_ id: Int, _ change: (PixelRect) -> PixelRect) -> EditOutcome {
        guard stage == .review, let index = items.firstIndex(where: { $0.id == id }),
              case let .added(box) = items[index].kind else { return .notEditable }
        let changed = change(box)
        guard changed != box else { return .unchanged }
        pushUndo()
        items[index].kind = .added(box: changed)
        refreshGeometry(id)
        return .changed(changed)
    }

    /// The number shown for a mask: its place in the list, counted from 1.
    private func maskNumber(_ id: Int) -> Int? {
        items.firstIndex(where: { $0.id == id }).map { $0 + 1 }
    }

    /// `value` as a whole percent of `extent` pixels.
    static func percent(_ value: Double, of extent: Int) -> Int {
        Int((value / Double(max(extent, 1)) * 100).rounded())
    }

    /// Asks the engine for the real mask of an added box. A later edit of the same mask wins over an older answer.
    private func refreshGeometry(_ id: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }), case let .added(box) = items[index].kind else { return }
        let engine = engine
        Task { [self] in
            guard let geometry = try? await engine.geometry(forAdded: box),
                  let now = items.firstIndex(where: { $0.id == id }),
                  case let .added(current) = items[now].kind, current == box else { return }
            items[now].geometry = geometry
        }
    }

    private func pushUndo() {
        undoStack.append(items)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
    }

    static func clamp(_ rect: PixelRect, width: Int, height: Int) -> PixelRect {
        var r = rect
        let w = min(r.width, Double(width)), h = min(r.height, Double(height))
        r.right = r.left + w
        r.bottom = r.top + h
        if r.left < 0 { r.right -= r.left; r.left = 0 }
        if r.top < 0 { r.bottom -= r.top; r.top = 0 }
        if r.right > Double(width) { r.left -= r.right - Double(width); r.right = Double(width) }
        if r.bottom > Double(height) { r.top -= r.bottom - Double(height); r.bottom = Double(height) }
        return r
    }

    // MARK: Save

    func save() {
        guard canSave else { return }
        let specs: [MaskSpec] = items.filter(\.isOn).map { item in
            switch item.kind {
            case let .detected(faceIndex, _): .detected(planIndex: faceIndex)
            case let .added(box): .added(box)
            }
        }
        stage = .saving
        status = Copy.saving
        let engine = engine
        launch { [self] in
            do {
                let out = try await engine.maskAndEncode(specs)
                jpeg = out
                stage = .saved
                // The outcome comes from the engine's result, never from the cancel request.
                if Task.isCancelled {
                    status = Copy.tooLateToCancel
                } else {
                    status = Copy.masksApplied(masks: out.maskCount)
                }
                focus(.savedHeading)
                isExporting = true
            } catch is CancellationError {
                finishCancelled(backTo: .review)
            } catch {
                fail(Self.failure(from: error))
            }
        }
    }

    /// The system exporter finished. The demo shows only whether it worked, never the name or place.
    func exportFinished(_ result: Result<URL, any Error>) {
        switch result {
        case .success: status = Copy.saved(masks: jpeg?.maskCount ?? 0)
        case .failure: status = Copy.notSaved
        }
        focus(.savedHeading) // the exporter covered the screen: bring the focus back to the result
    }

    /// The exporter was closed without a choice.
    func exportCancelled() {
        guard stage == .saved else { return }
        status = Copy.notSaved
        focus(.savedHeading)
    }

    func presentExporterAgain() {
        guard stage == .saved, jpeg != nil else { return }
        isExporting = true
    }

    // MARK: Reset

    /// Back to the photo step; the engine forgets the photo and the JPEG is dropped.
    func startOver() {
        task?.cancel()
        let engine = engine
        Task { await engine.discardPhoto() }
        resetPhotoState()
        stage = modelLoaded ? .choosePhoto : .chooseModel
        status = modelLoaded ? Copy.modelLoaded(name: loadedModelName ?? "") : ""
        focus(modelLoaded ? .photoHeading : .modelHeading) // the focused button is gone
    }

    func dismissFailure() {
        guard case .failed = stage else { return }
        if hasReview {
            stage = .review
            status = summary
            focus(.reviewHeading)
            return
        }
        stage = modelLoaded ? .choosePhoto : .chooseModel
        status = ""
        focus(modelLoaded ? .photoHeading : .modelHeading)
    }

    private func resetPhotoState() {
        photo = nil
        faces = []
        items = []
        jpeg = nil
        undoStack = []
        isExporting = false
        hasReview = false
    }

    // MARK: Helpers

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        generation += 1
        let mine = generation
        task = Task { [weak self] in
            await body()
            if let self, self.generation == mine { self.task = nil }
        }
    }

    private func finishCancelled(backTo target: Stage) {
        stage = target
        status = Copy.cancelled
        switch target {
        case .review: focus(.reviewHeading)
        case .choosePhoto: focus(.photoHeading)
        default: focus(.modelHeading)
        }
    }

    private func fail(_ failure: DemoFailure) {
        stage = .failed(failure)
        status = Copy.message(for: failure)
        focus(.failure)
    }

    private func focus(_ target: FocusTarget) {
        focusSerial += 1
        focusRequest = FocusRequest(target: target, serial: focusSerial)
    }

    private static func failure(from error: any Error) -> DemoFailure {
        (error as? DemoFailure) ?? .other
    }
}
