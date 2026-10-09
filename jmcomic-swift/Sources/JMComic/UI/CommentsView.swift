import SwiftUI

/// 评论列表（JM 移动端 `/forum` 接口）。
///
/// 上游只显示评论数量、点不开，这里补上查看能力。
struct CommentsView: View {
    let albumId: String
    let albumTitle: String

    @Environment(\.dismiss) private var dismiss
    @State private var items: [AlbumComment] = []
    @State private var total = 0
    @State private var page = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var error: String?

    private var canLoadMore: Bool { !loading && !loadingMore && items.count < total }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                Text("评论").font(.headline)
                if total > 0 {
                    Text("共 \(total) 条").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            .padding(14)

            Divider()

            if loading {
                VStack { ProgressView() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, items.isEmpty {
                VStack(spacing: 8) {
                    Text("评论加载失败").foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    Button("重试") { Task { await load(next: 1) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack { Text("还没有评论").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { c in
                            row(c)
                            Divider().padding(.leading, c.isReply ? 40 : 14)
                        }
                        if canLoadMore {
                            Button(loadingMore ? "加载中…" : "加载更多") {
                                Task { await load(next: page + 1) }
                            }
                            .padding(14)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 620)
        .task(id: albumId) { await load(next: 1) }
        .navigationTitle(albumTitle)
    }

    @ViewBuilder
    private func row(_ c: AlbumComment) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if c.isReply {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(c.userName).font(.callout.weight(.medium)).lineLimit(1)
                if c.likes > 0 {
                    Label("\(c.likes)", systemImage: "hand.thumbsup")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if !c.time.isEmpty {
                    Text(c.time).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text(c.content)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, c.isReply ? 40 : 14)
        .padding(.trailing, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load(next: Int) async {
        if next <= 1 { loading = true } else { loadingMore = true }
        error = nil
        do {
            let result = try await JmClient.shared.comments(albumId: albumId, page: next)
            if next <= 1 {
                items = result.items
            } else {
                items.append(contentsOf: result.items)
            }
            total = result.total
            page = next
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        loadingMore = false
    }
}
