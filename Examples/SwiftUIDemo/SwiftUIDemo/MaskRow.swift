// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// One mask in the list, with button controls only (no gestures).
struct MaskRow: View {
    let model: DemoViewModel
    let item: MaskItem
    let number: Int
    let photo: PhotoInfo?
    let focus: AccessibilityFocusState<FocusTarget?>.Binding
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The narrowest a move button may get; it grows with the text size so a word is never broken in the middle.
    @ScaledMetric(relativeTo: .body) private var minimumButtonWidth = 96.0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityFocused(focus, equals: .maskTitle(item.id))
            Text(position)
            Text(item.isOn ? "On: this area will be covered" : "Off: this area stays uncovered")
            ActionButton(item.isOn ? "Remove mask \(number)" : "Restore mask \(number)") { model.toggle(item.id) }
            if item.isAdded {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    control(Copy.left, "Move mask \(number) left") { model.move(item.id, .left) }
                    control(Copy.right, "Move mask \(number) right") { model.move(item.id, .right) }
                    control(Copy.up, "Move mask \(number) up") { model.move(item.id, .up) }
                    control(Copy.down, "Move mask \(number) down") { model.move(item.id, .down) }
                    control(Copy.smaller, "Make mask \(number) smaller") { model.resize(item.id, larger: false) }
                    control(Copy.larger, "Make mask \(number) larger") { model.resize(item.id, larger: true) }
                }
                ActionButton(Copy.deleteAdded(number: number)) { model.deleteAdded(item.id) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
    }

    /// Several buttons per row at normal sizes, one per row at the accessibility sizes.
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: minimumButtonWidth), spacing: 8)]
    }

    private var title: String {
        switch item.kind {
        case .detected: "Mask \(number): detected face"
        case .added: "Mask \(number): added by you"
        }
    }

    private var position: String {
        guard let photo else { return "" }
        return Copy.centre(x: DemoViewModel.percent(item.geometry.centerX, of: photo.width),
                           y: DemoViewModel.percent(item.geometry.centerY, of: photo.height))
    }

    private func control(_ title: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(.bordered)
            .tint(.primary)
            .controlSize(.large)
            .accessibilityLabel(label)
    }
}
