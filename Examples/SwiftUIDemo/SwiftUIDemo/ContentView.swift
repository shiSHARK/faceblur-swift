// SPDX-License-Identifier: Apache-2.0
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: DemoViewModel
    @State private var showModelImporter = false
    @State private var pickerItem: PhotosPickerItem?
    @AccessibilityFocusState private var focus: FocusTarget?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// While the masks are edited the photo stays on screen, so the effect of a button can be seen.
    private var pinsPreview: Bool { model.stage == .review && model.photo != nil }
    /// A phone held sideways has no height to spare: the photo goes beside the list instead of above it.
    private var previewBesideList: Bool { pinsPreview && verticalSizeClass == .compact }

    var body: some View {
        NavigationStack {
            layout
                // No navigation bar: the title is part of the content, so no translucent bar sits over the photo.
                .toolbar(.hidden, for: .navigationBar)
        }
        .fileImporter(isPresented: $showModelImporter, allowedContentTypes: [.data]) { model.modelFilePicked($0) }
        .fileExporter(
            isPresented: $model.isExporting,
            item: model.jpeg.map { MaskedJPEG(data: $0.data) },
            contentTypes: [.jpeg],
            defaultFilename: StagedFiles.exportName,
            onCompletion: { result in
                StagedFiles.removeExport()
                model.exportFinished(result)
            },
            onCancellation: {
                StagedFiles.removeExport()
                model.exportCancelled()
            })
        .onChange(of: model.statusSerial) {
            if !model.status.isEmpty { AccessibilityNotification.Announcement(model.status).post() }
        }
        .onChange(of: model.focusRequest) { _, request in
            guard let target = request?.target else { return }
            // Clear first so a repeated request for the same target moves the focus again; set it one turn later,
            // when the sections of the new state exist.
            focus = nil
            Task { @MainActor in focus = target }
        }
    }

    // MARK: Layout

    @ViewBuilder
    private var layout: some View {
        if previewBesideList {
            HStack(spacing: 0) {
                previewPane
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }
                    .background(.bar)
                content
            }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                // The bar backdrop also covers the status bar, so the clock never overprints scrolling text; with
                // the photo pinned it holds the preview as well.
                VStack(spacing: 0) {
                    if pinsPreview { previewPane.frame(maxHeight: horizontalSizeClass == .regular ? 400 : 220) }
                }
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(Copy.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(Copy.intro)
                modelSection
                photoSection
                if model.stage == .review { reviewSection }
                if model.stage == .saved { savedSection }
                if let failure = model.failure { failureSection(failure) }
                if !model.statusRepeatsScreenText { statusLine }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var previewPane: some View {
        if let photo = model.photo {
            PhotoReview(photo: photo, faces: model.faces, items: model.items, label: "Photo preview",
                        value: model.summary)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    // MARK: Sections

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.modelHeading).font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .modelHeading)
            if let name = model.loadedModelName, model.stage != .confirmModel, model.stage != .hashingModel {
                Text(Copy.modelLoaded(name: name))
                if model.stage == .choosePhoto {
                    ActionButton(Copy.changeModel) { showModelImporter = true }
                }
            } else if model.stage == .confirmModel, let candidate = model.candidate {
                confirmation(candidate)
            } else if model.stage == .hashingModel || model.stage == .loadingModel {
                busy(model.stage == .hashingModel ? Copy.hashing : Copy.modelLoadingNoCancel)
            } else {
                ActionButton(Copy.chooseModel) { showModelImporter = true }
                    .disabled(!model.canChooseModel)
            }
        }
    }

    private func confirmation(_ candidate: ModelCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File name: \(candidate.fileName)")
            Text("Size: \(candidate.sizeText)")
            Text("SHA-256")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(candidate.hashLines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(.body, design: .monospaced))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("SHA-256 digits")
            .accessibilityValue(candidate.hashLines.map { $0.map { "\($0)" }.joined(separator: " ") }
                .joined(separator: ", line break, "))
            Text(Copy.confirmHint).font(.footnote)
            AdaptiveButtonRow {
                ActionButton(Copy.useModel, prominent: true) { model.confirmModel() }
                ActionButton(Copy.cancel) { model.cancelModelConfirmation() }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.photoHeading).font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .photoHeading)
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Text(Copy.choosePhoto).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
            .controlSize(.large)
            .disabled(!model.canChoosePhoto)
            .accessibilityHint(Copy.choosePhotoHint)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                pickerItem = nil
                Task { model.photoPicked(try? await item.loadTransferable(type: Data.self)) }
            }
            if !model.modelLoaded { Text(Copy.chooseModelFirst).font(.footnote) }
            if model.stage == .preparingPhoto || model.stage == .detecting {
                busy(model.stage == .preparingPhoto ? Copy.preparing : Copy.detecting)
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.reviewHeading).font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .reviewHeading)
            Text(model.summary).font(.headline)
            Text(Copy.reviewHint).font(.footnote)
            if model.faces.isEmpty { Text(Copy.noFaces) }
            Text(Copy.masksHeading).font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .masksHeading)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                MaskRow(model: model, item: item, number: offset + 1, photo: model.photo, focus: $focus)
            }
            AdaptiveButtonRow {
                ActionButton(Copy.addMask) { model.addMask() }
                ActionButton(Copy.undo) { model.undo() }.disabled(!model.canUndo)
            }
            ActionButton(model.activeMaskCount == 0 ? Copy.saveWithoutMasks : Copy.saveWithMasks, prominent: true) {
                model.save()
            }
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.savedHeading).font(.headline).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focus, equals: .savedHeading)
            if let data = model.jpeg?.data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Masked photo")
                    .accessibilityValue(Copy.masksApplied(masks: model.jpeg?.maskCount ?? 0))
            }
            ActionButton(Copy.saveAgain, prominent: true) { model.presentExporterAgain() }
            ActionButton(Copy.chooseAnother) { model.startOver() }
        }
    }

    private func failureSection(_ failure: DemoFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.message(for: failure)).font(.headline)
                .accessibilityFocused($focus, equals: .failure)
            ActionButton("OK") { model.dismissFailure() }
        }
        .accessibilityElement(children: .contain)
    }

    private func busy(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(text)
            if model.canCancel {
                ActionButton(Copy.cancel) { model.cancelRun() }
            } else if model.cancelBlockedByModelLoading {
                Text(Copy.modelLoadingNoCancel).font(.footnote)
            }
        }
    }

    private var statusLine: some View {
        Text(model.status)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("status")
    }
}

/// A large, bordered button whose whole width is the tap target and the border, at least 44 pt high; the text
/// scales with Dynamic Type and wraps instead of being cut. The label uses the primary text colour so its contrast
/// on the button background is high in light and dark mode.
struct ActionButton: View {
    let title: String
    var prominent = false
    let action: () -> Void

    init(_ title: String, prominent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.prominent = prominent
        self.action = action
    }

    var body: some View {
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var button: some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
            .tint(.primary)
            .controlSize(.large)
    }
}

/// Buttons side by side when they fit at the current text size, one above the other when they do not (the largest
/// accessibility sizes), so no label is broken in the middle of a word.
struct AdaptiveButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { content }
            VStack(spacing: 12) { content }
        }
    }
}
