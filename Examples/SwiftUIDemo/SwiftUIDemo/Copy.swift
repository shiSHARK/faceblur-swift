// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Every string the person reads, in one place. The wording makes only three claims: masks are opaque, the saved
/// JPEG carries no metadata, FaceBlur contains no network code.
enum Copy {
    static let title = "FaceBlur demo"
    static let intro = "Covers faces with opaque masks and saves a JPEG without metadata. Detection can miss "
        + "faces, so check every result before you share it. FaceBlur contains no network code."

    static let modelHeading = "1. Model"
    static let chooseModel = "Choose model file"
    static let chooseModelFirst = "Choose a model first"
    static let hashing = "Reading the model file"
    static let confirmHint = "Compare this SHA-256 with the value published for the model. Only \"Use this model\" "
        + "loads it, and only with exactly this hash."
    static let useModel = "Use this model"
    static let cancel = "Cancel"
    static let modelLoadingNoCancel = "Loading the model cannot be cancelled once it has started."
    static let modelLoaded = "Model loaded"
    static let changeModel = "Choose another model"

    static let photoHeading = "2. Photo"
    static let choosePhoto = "Choose a photo"
    static let choosePhotoHint = "Opens the system photo picker."
    static let preparing = "Preparing the photo"
    static let detecting = "Looking for faces"

    static let reviewHeading = "3. Review"
    static let masksHeading = "Masks"
    static let addMask = "Add a mask"
    static let undo = "Undo"
    static let smaller = "Smaller"
    static let larger = "Larger"
    static let left = "Left"
    static let right = "Right"
    static let up = "Up"
    static let down = "Down"
    static let deleteAdded = "Delete this mask"
    static let saveWithMasks = "Apply masks and save JPEG"
    static let saveWithoutMasks = "Save JPEG without masks"
    static let saving = "Applying masks and writing the JPEG"
    static let saveAgain = "Save JPEG"
    static let chooseAnother = "Choose another photo"
    static let reviewHint = "Masks are drawn here as outlines. Faces the detector missed stay uncovered: add a "
        + "mask for each one."

    static let noFaces = "No faces were detected. Add a mask where a face is, or save without masks."
    static let cancelled = "Cancelled. Nothing was changed."
    static let tooLateToCancel = "Too late to cancel. The masks were applied."
    static let notSaved = "Not saved. Use Save JPEG to choose where to put the file."

    static func facesAndMasks(faces: Int, masks: Int) -> String {
        "\(faces) \(faces == 1 ? "face" : "faces") detected, \(masks) \(masks == 1 ? "mask" : "masks") "
            + "will be applied"
    }

    static func modelLoaded(name: String) -> String { "\(Copy.modelLoaded): \(name)" }
    static func saved(masks: Int) -> String { "Saved. \(masks) \(masks == 1 ? "mask" : "masks") applied." }
    static func masksApplied(masks: Int) -> String {
        "\(masks) \(masks == 1 ? "mask" : "masks") applied. Choose where to save the JPEG."
    }

    static func message(for failure: DemoFailure) -> String {
        switch failure {
        case .modelFileUnreadable: "The model file could not be read. Nothing was loaded."
        case .modelFileUnsuitable: "This file is too large or empty for a face model. Nothing was loaded."
        case .modelDoesNotMatch: "The file does not match the SHA-256 you confirmed. Nothing was loaded."
        case .modelRejected: "The library did not accept this model. Nothing was loaded."
        case .runtimeUnavailable: "The ONNX runtime is not available in this build."
        case .photoUnreadable: "This photo could not be read."
        case .photoTooLarge: "This photo is too large to process."
        case .notEnoughMemory: "Not enough memory to mask this photo. It was not masked."
        case .outputCheckFailed: "The masked photo failed the library's output check. Nothing was saved."
        case .other: "Something went wrong. Nothing was saved."
        }
    }
}
