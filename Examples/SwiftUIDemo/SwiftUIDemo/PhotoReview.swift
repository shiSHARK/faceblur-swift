// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The photo with the detected faces (solid outlines, F1, F2, ...) and the masks (dashed outlines, M1, M2, ...).
/// Faces and masks differ by line style and label, never by colour alone.
struct PhotoReview: View {
    let photo: PhotoInfo
    let faces: [DetectedFace]
    let items: [MaskItem]

    var body: some View {
        Image(uiImage: photo.preview)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / CGFloat(max(photo.width, 1))
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(faces.enumerated()), id: \.offset) { index, face in
                            outline(face.box, scale: scale, dashed: false, label: "F\(index + 1)", ellipse: false)
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            outline(item.geometry.bounds, scale: scale, dashed: true,
                                    label: "M\(index + 1)\(item.isOn ? "" : " off")", ellipse: item.geometry.isEllipse,
                                    faint: !item.isOn)
                        }
                    }
                }
            }
            .clipped() // a mask near the border is expanded beyond the photo; show only the part inside it
    }

    private func outline(_ box: PixelRect, scale: CGFloat, dashed: Bool, label: String, ellipse: Bool,
                         faint: Bool = false) -> some View {
        let frame = CGRect(x: box.left * scale, y: box.top * scale, width: box.width * scale, height: box.height * scale)
        let dash: [CGFloat] = dashed ? [8, 5] : []
        return ZStack(alignment: .topLeading) {
            shape(ellipse).stroke(.black, style: StrokeStyle(lineWidth: 5, dash: dash))
            shape(ellipse).stroke(.white, style: StrokeStyle(lineWidth: 2.5, dash: dash))
            Text(label)
                .font(.caption.bold())
                .padding(.horizontal, 4)
                .background(.black)
                .foregroundStyle(.white)
                .offset(x: 2, y: 2)
        }
        .frame(width: frame.width, height: frame.height)
        .opacity(faint ? 0.6 : 1)
        .position(x: frame.midX, y: frame.midY)
    }

    private func shape(_ ellipse: Bool) -> AnyShape {
        ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle())
    }
}
