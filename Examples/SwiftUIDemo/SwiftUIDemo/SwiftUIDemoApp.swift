// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct SwiftUIDemoApp: App {
    @State private var model = DemoViewModel(engine: FaceBlurEngine())
    @State private var shield = PrivacyShield()
    @Environment(\.scenePhase) private var scenePhase

    init() { StagedFiles.removeExport() }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // The system takes the app-switcher snapshot when the scene leaves the foreground: cover first.
                .onChange(of: scenePhase, initial: true) { _, phase in shield.update(for: phase) }
                #if DEBUG
                .task { await DebugLaunchHooks.run(model) }
                #endif
        }
    }
}
