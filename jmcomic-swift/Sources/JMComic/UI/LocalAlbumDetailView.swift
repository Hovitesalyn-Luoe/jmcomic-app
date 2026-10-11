import SwiftUI
import AppKit

/// 本地漫画详情页：样式与在线阅读详情页一致（封面/标题/继续阅读/章节列表），
/// 进度状态共用 LibraryStore —— 读完回来自动同步「继续阅读第 N 页」。
struct LocalAlbumDetailView: View {

    let album: DownloadedAlbum
    @State var reading: DownloadedChapter?
    /// 本次阅读是否「从头开始」（不恢复进度）
    @State var startOver = false
    @StateObject var library = LibraryStore.shared

    var body: some View {
        let pos = library.position(for: album.meta.id)
        let currentChapterID = pos?.chapterId
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 18) {
                    CoverImage(albumId: album.meta.id, width: 170)

                    VStack(alignment: .leading, spacing: 9) {
                        Text(album.meta.title).font(.title2.weight(.semibold)).lineLimit(3)
                        Text("本地漫画 · \(album.chapters.count) 话 · \(album.totalPages) 页")
                            .foregroundStyle(.secondary)

                        if let pos,
                           let ch = album.chapters.first(where: { $0.chapterId == pos.chapterId }) {
                            HStack(spacing: 10) {
                                Button {
                                    startOver = false
                                    reading = ch
                                } label: {
                                    Label("继续阅读：第 \(pos.pageIndex + 1) 页",
                                          systemImage: "book")
                                        .frame(minWidth: 110)
                                }
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)

                                Button("从头开始") {
                                    startOver = true
                                    reading = album.chapters.first
                                }
                            }
                        } else if let first = album.chapters.first {
                            Button {
                                startOver = true
                                reading = first
                            } label: {
                                Label("从第一话开始阅读", systemImage: "book")
                                    .frame(minWidth: 110)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("章节 (\(album.chapters.count))").font(.headline)
                    ForEach(album.chapters) { c in
                        chapterRow(c, currentChapterID: currentChapterID)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(album.meta.title)
        // 关闭本地详情 → 让本地漫画列表回到记忆位置
        .onDisappear { ScrollMemory.shared.requestRestoreForLastVisible() }
        .sheet(item: $reading) { chapter in
            LocalReaderView(chapter: chapter, meta: album.meta, restart: startOver)
                .frame(minWidth: 700, minHeight: 500)
        }
    }

    func chapterRow(_ c: DownloadedChapter, currentChapterID: String?) -> some View {
        Button {
            startOver = false
            reading = c
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.chapterTitle).font(.callout).lineLimit(1)
                    Text(chapterInfo(c))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if currentChapterID == c.chapterId {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Image(systemName: "book")
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 导入的 CBZ 没数过页数，显示格式标识而不是 0 页
    func chapterInfo(_ c: DownloadedChapter) -> String {
        let fmt = c.format == .cbz ? "CBZ" : "散图"
        return c.pageCount > 0 ? "\(c.pageCount) 页 · \(fmt)" : fmt
    }
}
