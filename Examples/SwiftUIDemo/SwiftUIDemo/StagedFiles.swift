// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The system file exporter stages the JPEG it is handed as a file in the app's own temporary folder, named after the
/// default file name: `tmp/<name>.jpeg` on iOS 18.0, `tmp/<UUID>/<name>.jpeg` on iOS 27.0 (observed on the
/// simulators: a save moves the file to the chosen place, a cancel leaves it in tmp). The app deletes every such file
/// (and the UUID folder that holds it) as soon as the exporter is closed, and once more at launch in case the app was
/// ended while the exporter was open. This is the only file code in the demo, and it only lists and deletes.
enum StagedFiles {
    static let exportName = "masked-photo"

    static func removeExport() {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
        for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            let url = folder.appendingPathComponent(name)
            let inside = (try? manager.contentsOfDirectory(atPath: url.path)) ?? []
            if name.hasPrefix(exportName) || inside.contains(where: { $0.hasPrefix(exportName) }) {
                try? manager.removeItem(at: url)
            }
        }
    }
}
