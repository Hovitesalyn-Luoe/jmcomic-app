import SwiftUI

/// 本地个性化推荐。
///
/// 算法（刻意不用 ML，够用即可）：
/// 1. 画像：从「历史 + 收藏」的本子（本地缓存的 Album 带标签）统计标签/作者频次
/// 2. 候选：用 Top 标签走现有 search 接口各拉一页（不动热门/最新接口）
/// 3. 过滤：排除历史与收藏里已看过的
/// 4. 排序：与画像标签重合度高的优先
///
/// 数据全部本地计算，不上传。
struct PersonalizedView: View {

    @StateObject private var library = LibraryStore.shared
    @State private var items: [AlbumMeta] = []
    @State private var profileTags: [String] = []
    @State private var loading = true
    @State private var error: String?
    @State private var path: [Route] = []
    /// 当前页滚动位置（顶部可见项 id），交给 ScrollMemory 记忆/回顶
    @State private var scrolledID: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if loading {
                    ProgressView("正在按你的口味找…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    emptyHint
                } else {
                    grid
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .album(let meta):
                    AlbumDetailView(meta: meta, path: $path)
                case .author(let name):
                    AuthorWorksView(author: name, path: $path)
                }
            }
        }
        .navigationTitle("为你推荐")
        .toolbar {
            // 每次打开本来就会重算；想要立即刷新就点这里
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("重新推荐")
            }
        }
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("为你推荐").font(.title2.weight(.semibold))
            if !profileTags.isEmpty {
                Text("根据你看过的：\(profileTags.joined(separator: " · "))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.secondary)
            if let error {
                Text("推荐失败：\(error)").foregroundStyle(.secondary)
            } else if profileTags.isEmpty {
                Text("还没有足够的口味数据。多读几本、收藏几本，推荐会更准。")
                    .foregroundStyle(.secondary)
            } else {
                Text("没找到新的推荐，之后再来看看。").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
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
                    .id(meta.id)
                }
            }
            .scrollTargetLayout()
            .padding(18)
        }
        .scrollMemory(page: "personalized", scrolledID: $scrolledID, topID: items.first?.id, atRoot: path.isEmpty)
    }

    // MARK: - 算法

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }

        let rec = await library.recommendations()
        profileTags = rec.profileTags
        items = rec.items
    }
}
