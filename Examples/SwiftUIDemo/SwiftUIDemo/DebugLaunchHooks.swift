// SPDX-License-Identifier: Apache-2.0
#if DEBUG
import Foundation

/// Debug builds only (compiled out of Release): lets the simulator UI test hand over a model file and a photo that
/// the system pickers would return. They go through the same view-model calls as the pickers. Nothing is read
/// unless the test sets the environment variables.
enum DebugLaunchHooks {
    @MainActor
    static func run(_ model: DemoViewModel) async {
        let env = ProcessInfo.processInfo.environment
        if let path = env["FACEBLUR_DEMO_MODEL"] {
            model.modelFilePicked(.success(URL(fileURLWithPath: path)))
        }
        guard let photoPath = env["FACEBLUR_DEMO_PHOTO"] else { return }
        while model.stage != .choosePhoto {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
        model.photoPicked(try? Data(contentsOf: URL(fileURLWithPath: photoPath)))
    }
}
#endif
