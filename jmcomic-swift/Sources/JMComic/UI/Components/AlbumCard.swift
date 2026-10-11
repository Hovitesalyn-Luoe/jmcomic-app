import SwiftUI

/// 通用本子卡片：封面 + 标题 + 可选副标题。
/// 列表网格（浏览/最近/收藏/作者/推荐/分类/本地）共用这一张。
struct AlbumCard: View {
    let albumId: String
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverImage(albumId: albumId, width: width)
            Text(title).font(.callout).lineLimit(2)
                .frame(width: width, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).frame(width: width, alignment: .leading)
            }
        }
    }
}
