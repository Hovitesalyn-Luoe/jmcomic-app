import SwiftUI
import CoreGraphics

/// 封面。宽高比固定 3:4，加载中不撑变版面。
struct CoverImage: View {
    let albumId: String
    var width: CGFloat = 132

    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(white: 0.16))
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: width, height: width * 4 / 3)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: albumId) {
            let img = await ImageStore.shared.cover(albumId: albumId)
            await MainActor.run { self.image = img }
        }
    }
}
