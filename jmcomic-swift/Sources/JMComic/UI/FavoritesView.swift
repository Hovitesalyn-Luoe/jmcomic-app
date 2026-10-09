import SwiftUI

/// 我的收藏页：按自建分组浏览，右键可移除/移动分组。
/// 收藏数据只存本地（FavoriteStore），不走服务端，也不上传。
struct FavoritesView: View {

    @ObservedObject private var favorites = FavoriteStore.shared
    @State private var folder = "默认"
    @State private var path: [Route] = []
    /// 当前页滚动位置（顶部可见项 id），交给 ScrollMemory 记忆/回顶
    @State private var scrolledID: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 12) {
                header
                grid
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
        .navigationTitle("我的收藏")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("我的收藏").font(.title2.weight(.semibold))
            HStack(spacing: 12) {
                Picker("分组", selection: $folder) {
                    ForEach(favorites.folders, id: \.self) { f in
                        Text("\(f)（\(favorites.count(in: f))）").tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 180)

                if folder != "默认" {
                    Button("删除此分组（内容退回默认）", role: .destructive) {
                        favorites.removeFolder(folder)
                        folder = "默认"
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var grid: some View {
        let shown = favorites.entries(in: folder)
        return ScrollView {
            if shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "heart").font(.largeTitle).foregroundStyle(.secondary)
                    Text("这个分组还没有收藏").foregroundStyle(.secondary)
                }
                .padding(60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                    ForEach(shown) { entry in
                        Button { path.append(.album(entry.meta)) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(albumId: entry.meta.id, width: 150)
                                Text(entry.meta.title).font(.callout).lineLimit(2)
                                    .frame(width: 150, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .id(entry.meta.id)
                        .contextMenu {
                            Button("移除收藏") { favorites.remove(entry.meta.id) }
                            Divider()
                            ForEach(favorites.folders.filter { $0 != entry.folder }, id: \.self) { f in
                                Button("移动到「\(f)」") { favorites.move(entry.meta.id, to: f) }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(18)
            }
        }
        .scrollMemory(page: "favorites", scrolledID: $scrolledID, topID: shown.first?.id)
    }
}
