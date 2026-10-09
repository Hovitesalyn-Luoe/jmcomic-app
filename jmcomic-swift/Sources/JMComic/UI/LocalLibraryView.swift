import SwiftUI

/// 本地漫画库：已下载的本子（CBZ / 散图文件夹）。
/// 持久化：文件在下载目录，索引在 downloads.json（加密）。
/// 「扫描导入」可从外部目录重建索引（换机器/恢复备份时用）。
/// 阅读进度与在线阅读共用同一份历史。
struct LocalLibraryView: View {

    @ObservedObject private var downloads = DownloadStore.shared
    @State private var importNotice: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                header
                if downloads.library.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .navigationDestination(for: DownloadedAlbum.self) { album in
                LocalAlbumDetailView(album: album)
            }
        }
        .navigationTitle("本地漫画")
    }

    private var header: some View {
        HStack {
            Text("本地漫画").font(.title2.weight(.semibold))
            Spacer()
            Button("扫描导入") { importFromDisk() }
                .font(.caption)
        }
        .padding(.horizontal, 20).padding(.top, 14)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
            Text("还没有下载。在本子详情页点「下载整本」，或「扫描导入」已有文件。")
                .foregroundStyle(.secondary)
            if let importNotice {
                Text(importNotice).font(.caption).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 网格滚动位置（顶部可见项 id）
    @State private var scrolledID: String?

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                ForEach(downloads.library) { album in
                    NavigationLink(value: album) {
                        VStack(alignment: .leading, spacing: 6) {
                            CoverImage(albumId: album.meta.id, width: 150)
                            Text(album.meta.title).font(.callout).lineLimit(2)
                                .frame(width: 150, alignment: .leading)
                            Text("\(album.chapters.count) 话 · \(album.totalPages) 页")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("在 Finder 中显示") {
                            if let first = album.chapters.first {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: first.path)])
                            }
                        }
                        Divider()
                        Button("删除（连文件）", role: .destructive) {
                            downloads.delete(album.meta.id, removeFiles: true)
                        }
                    }
                }
            }
                .scrollTargetLayout()
            .padding(18)
        }
            .scrollMemory(page: "local", scrolledID: $scrolledID, topID: downloads.library.first?.id)
    }

    private func importFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "扫描导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let n = downloads.importFolder(url)
        importNotice = n > 0 ? "已导入 \(n) 本" : "没有找到可导入的本子（需要 本子目录/章节.cbz 或图片文件夹 的结构）"
    }
}

/// 本地漫画详情页：样式与在线阅读详情页一致（封面/标题/继续阅读/章节列表），
/// 进度状态共用 LibraryStore —— 读完回来自动同步「继续阅读第 N 页」。
struct LocalAlbumDetailView: View {

    let album: DownloadedAlbum
    @State private var reading: DownloadedChapter?
    @StateObject private var library = LibraryStore.shared

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
                            Button {
                                reading = ch
                            } label: {
                                Label("继续阅读：第 \(pos.pageIndex + 1) 页",
                                      systemImage: "book")
                                    .frame(minWidth: 110)
                            }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                        } else {
                            Text("还没读过，从第一话开始")
                                .font(.caption).foregroundStyle(.secondary)
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
            LocalReaderView(chapter: chapter, meta: album.meta)
                .frame(minWidth: 700, minHeight: 500)
        }
    }

    private func chapterRow(_ c: DownloadedChapter, currentChapterID: String?) -> some View {
        Button {
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
    private func chapterInfo(_ c: DownloadedChapter) -> String {
        let fmt = c.format == .cbz ? "CBZ" : "散图"
        return c.pageCount > 0 ? "\(c.pageCount) 页 · \(fmt)" : fmt
    }
}
