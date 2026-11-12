// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import UIKit

/// Hides the app's content in the app switcher, the iOS counterpart of Android's FLAG_SECURE. While the scene is not
/// active, an opaque window above everything (sheets and pickers included) covers the screen.
@MainActor
final class PrivacyShield {
    private var window: UIWindow?

    var isCovering: Bool { window != nil }

    func update(for phase: ScenePhase) {
        if phase == .active { uncover() } else { cover() }
    }

    func cover() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState != .unattached }) ?? scenes.first else { return }
        let shield = UIWindow(windowScene: scene)
        shield.windowLevel = .alert + 1
        let host = UIHostingController(rootView: PrivacyCover())
        host.view.backgroundColor = .systemBackground
        shield.rootViewController = host
        shield.isHidden = false
        window = shield
    }

    func uncover() {
        window?.isHidden = true
        window = nil
    }
}

/// What the switcher shows instead of the photo.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            Label(Copy.title, systemImage: "eye.slash")
                .font(.title2)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}
