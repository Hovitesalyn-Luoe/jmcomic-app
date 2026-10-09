import SwiftUI

/// 最近浏览：打开过详情页的本子（即使没阅读也记），持久化到磁盘，
/// 进程被杀/重启也不丢——找到好看的本子随手点开就会出现在这里。
struct RecentView: View {

    @ObservedObject private var library = LibraryStore.shared
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(alignment: .leading, spacing: 12) {
                Text("最近浏览").font(.title2.weight(.semibold))
                    .padding(.horizontal, 20).padding(.top, 14)
                if library.recentlyViewed.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock").font(.largeTitle).foregroundStyle(.secondary)
                        Text("打开过的本子会出现在这里（无需阅读）。")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                            ForEach(library.recentlyViewed) { meta in
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
                    }
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
        .navigationTitle("最近浏览")
    }
}
