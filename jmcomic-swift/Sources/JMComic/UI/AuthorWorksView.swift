import SwiftUI

/// 作者作品页。
///
/// JM 的服务端没有"作者"这个实体（本子的作者只是一个文本字段），
/// 所以"看该作者的所有作品"= 用作者名去搜索。卡片样式与浏览页保持一致。
struct AuthorWorksView: View {
    let author: String
    @Binding var path: [Route]

    @State private var items: [AlbumMeta] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var page = 1
    @State private var totalPages = 1

    private var canLoadMore: Bool { !loading && page < totalPages }

    var body: some View {
        ScrollView {
            if let errorText, items.isEmpty {
                Text(errorText)
                    .foregroundStyle(.secondary)
                    .padding(24)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                ForEach(items) { meta in
                    Button { path.append(.album(meta)) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(albumId: meta.id, width: 150)
                            Text(meta.title).font(.callout).lineLimit(2)
                                .frame(width: 150, alignment: .leading)
                            Text(meta.authorText).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).frame(width: 150, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)

            if loading {
                ProgressView().padding(.bottom, 24)
            } else if canLoadMore {
                Button("加载更多") { Task { await load(next: page + 1) } }
                    .padding(.bottom, 26)
            } else if items.isEmpty {
                Text("没有找到该作者的作品")
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 26)
            }
        }
        .navigationTitle("作者：\(author)")
        .task(id: author) { await load(next: 1) }
    }

    private func load(next: Int) async {
        loading = true
        errorText = nil
        do {
            let result = try await JmClient.shared.search(author, page: next)
            if next <= 1 {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            page = next
            totalPages = max(1, result.totalPages)
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }
}
