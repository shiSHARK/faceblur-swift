// SPDX-License-Identifier: Apache-2.0
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: DemoViewModel
    @State private var showModelImporter = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(Copy.title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text(Copy.intro)
                    modelSection
                    photoSection
                    if model.stage == .review { reviewSection }
                    if model.stage == .saved { savedSection }
                    if let failure = model.failure { failureSection(failure) }
                    statusLine
                }
                .padding()
            }
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
        .onChange(of: model.status) { _, text in
            if !text.isEmpty { AccessibilityNotification.Announcement(text).post() }
        }
    }

    // MARK: Sections

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.modelHeading).font(.headline).accessibilityAddTraits(.isHeader)
            if let name = model.loadedModelName, model.stage != .confirmModel, model.stage != .hashingModel {
                Text(Copy.modelLoaded(name: name))
                if model.stage == .choosePhoto {
                    Button(Copy.changeModel) { showModelImporter = true }.demoButton()
                }
            } else if model.stage == .confirmModel, let candidate = model.candidate {
                confirmation(candidate)
            } else if model.stage == .hashingModel || model.stage == .loadingModel {
                busy(model.stage == .hashingModel ? Copy.hashing : Copy.modelLoadingNoCancel)
            } else {
                Button(Copy.chooseModel) { showModelImporter = true }
                    .frame(maxWidth: .infinity)
                    .demoButton()
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
            HStack {
                Button(Copy.useModel) { model.confirmModel() }.demoButton(prominent: true)
                Button(Copy.cancel) { model.cancelModelConfirmation() }.demoButton()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.photoHeading).font(.headline).accessibilityAddTraits(.isHeader)
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
            if let photo = model.photo {
                PhotoReview(photo: photo, faces: model.faces, items: model.items)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Photo preview")
                    .accessibilityValue(model.summary)
            }
            Text(model.summary).font(.headline)
            Text(Copy.reviewHint).font(.footnote)
            if model.faces.isEmpty { Text(Copy.noFaces) }
            Text(Copy.masksHeading).font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(Array(model.items.enumerated()), id: \.element.id) { offset, item in
                MaskRow(model: model, item: item, number: offset + 1, photo: model.photo)
            }
            HStack {
                Button(Copy.addMask) { model.addMask() }.demoButton()
                Button(Copy.undo) { model.undo() }.demoButton().disabled(!model.canUndo)
            }
            Button(model.activeMaskCount == 0 ? Copy.saveWithoutMasks : Copy.saveWithMasks) { model.save() }
                .demoButton(prominent: true)
        }
    }

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.reviewHeading).font(.headline).accessibilityAddTraits(.isHeader)
            if let data = model.jpeg?.data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Masked photo")
                    .accessibilityValue(Copy.masksApplied(masks: model.jpeg?.maskCount ?? 0))
            }
            Button(Copy.saveAgain) { model.presentExporterAgain() }.demoButton(prominent: true)
            Button(Copy.chooseAnother) { model.startOver() }.demoButton()
        }
    }

    private func failureSection(_ failure: DemoFailure) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.message(for: failure)).font(.headline)
            Button("OK") { model.dismissFailure() }.demoButton()
        }
        .accessibilityElement(children: .contain)
    }

    private func busy(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(text)
            if model.canCancel {
                Button(Copy.cancel) { model.cancelRun() }.demoButton()
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

extension View {
    /// Large, bordered, at least 44 pt high; text scales with Dynamic Type. The label uses the primary text colour so
    /// its contrast on the button background is high in light and dark mode.
    func demoButton(prominent: Bool = false) -> some View {
        modifier(DemoButton(prominent: prominent))
    }
}

private struct DemoButton: ViewModifier {
    let prominent: Bool
    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent).tint(.primary).controlSize(.large).frame(minHeight: 44)
        } else {
            content.buttonStyle(.bordered).tint(.primary).controlSize(.large).frame(minHeight: 44)
        }
    }
}
