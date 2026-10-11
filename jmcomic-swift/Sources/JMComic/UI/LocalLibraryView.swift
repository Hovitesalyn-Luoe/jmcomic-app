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
                        AlbumCard(albumId: album.meta.id, title: album.meta.title, subtitle: "\(album.chapters.count) 话 · \(album.totalPages) 页")
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

