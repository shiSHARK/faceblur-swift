// SPDX-License-Identifier: Apache-2.0
import CoreTransferable
import UniformTypeIdentifiers

/// The masked JPEG, handed to the system file exporter. The app holds it in memory and writes no file; the system
/// exporter stages it as a file in the app's tmp folder while it is open (StagedFiles.swift deletes that file) and
/// writes the final copy where the person chooses.
struct MaskedJPEG: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { $0.data }
    }
}
