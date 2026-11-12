// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// One mask in the list, with button controls only (no gestures).
struct MaskRow: View {
    let model: DemoViewModel
    let item: MaskItem
    let number: Int
    let photo: PhotoInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(position)
            Text(item.isOn ? "On: this area will be covered" : "Off: this area stays uncovered")
            Button(item.isOn ? "Remove mask \(number)" : "Restore mask \(number)") { model.toggle(item.id) }
                .demoButton()
            if item.isAdded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                    control(Copy.left, "Move mask \(number) left") { model.move(item.id, .left) }
                    control(Copy.right, "Move mask \(number) right") { model.move(item.id, .right) }
                    control(Copy.up, "Move mask \(number) up") { model.move(item.id, .up) }
                    control(Copy.down, "Move mask \(number) down") { model.move(item.id, .down) }
                    control(Copy.smaller, "Make mask \(number) smaller") { model.resize(item.id, larger: false) }
                    control(Copy.larger, "Make mask \(number) larger") { model.resize(item.id, larger: true) }
                }
                Button(Copy.deleteAdded) { model.deleteAdded(item.id) }
                    .demoButton()
                    .accessibilityLabel("Delete mask \(number)")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    private var title: String {
        switch item.kind {
        case .detected: "Mask \(number): detected face"
        case .added: "Mask \(number): added by you"
        }
    }

    private var position: String {
        guard let photo else { return "" }
        let x = Int((item.geometry.centerX / Double(max(photo.width, 1)) * 100).rounded())
        let y = Int((item.geometry.centerY / Double(max(photo.height, 1)) * 100).rounded())
        return "Centre \(x) % from the left, \(y) % from the top"
    }

    private func control(_ title: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .tint(.primary)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(label)
    }
}
