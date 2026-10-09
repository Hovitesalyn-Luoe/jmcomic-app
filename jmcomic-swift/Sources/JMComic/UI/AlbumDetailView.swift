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

struct AlbumDetailView: View {

    let meta: AlbumMeta
    @Binding var path: [Route]

    @StateObject private var library = LibraryStore.shared
    @StateObject private var downloads = DownloadStore.shared
    @StateObject private var favorites = FavoriteStore.shared
    @State private var album: Album?
    @State private var previews: [CGImage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var reading: Album?
    @State private var readingChapter = 0
    @State private var showPreviewViewer = false
    @State private var previewIndex = 0
    @State private var previewFailed = false

    var body: some View {
        ScrollView {
            if let album {
                detail(album)
            } else if loading {
                ProgressView("加载中…").padding(60)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await load() } }
                }
                .padding(60)
            }
        }
        .navigationTitle(meta.title)
        .task { await load() }
        // 预览只读图，不写历史/进度（见 loadPreviews）
        .task(id: album?.id) {
            if let album { await loadPreviews(album) }
        }
        .sheet(item: $reading) { album in
            ReaderView(album: album, chapterIndex: readingChapter)
                // id 变化强制重建：修「点第 10 话却打开第 1 话」（sheet item 相同时复用旧实例）
                .id(readingChapter)
                .frame(minWidth: 900, idealWidth: 1080, minHeight: 600, idealHeight: 860)
        }
        // 预览查看器：与阅读器完全隔离，只读图，不写历史/进度
        .sheet(isPresented: $showPreviewViewer) {
            PreviewViewer(images: previews, startIndex: previewIndex)
                .frame(minWidth: 600, minHeight: 500)
        }
    }

    /// 下载三态：未下载 → 下载中（进度+取消）→ 已下载
    private func downloadRow(_ album: Album) -> some View {
        if let task = downloads.task(for: album.id) {
            return AnyView(
                HStack(spacing: 10) {
                    ProgressView(value: task.progress)
                        .frame(width: 130)
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                    if let err = task.error {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                    if task.failed > 0 {
                        Text("\(task.failed) 页失败").font(.caption).foregroundStyle(.orange)
                    }
                    Button("取消") { downloads.cancel(album.id) }
                        .buttonStyle(.borderless).font(.caption)
                }
            )
        }
        if downloads.isDownloaded(album.id) {
            return AnyView(
                Label("已下载", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
            )
        }
        return AnyView(
            Button {
                downloads.start(album: album)
            } label: {
                Label("下载整本", systemImage: "arrow.down.circle")
                    .frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
            .help("整本下载到本地（设置页可改格式与位置）")
        )
    }

    /// 收藏/取消收藏（本地分组，见 FavoriteStore）
    private func favoriteButton(_ album: Album) -> some View {
        let saved = favorites.contains(album.id)
        return Button {
            favorites.toggle(album)
        } label: {
            Label(saved ? "已收藏" : "收藏", systemImage: saved ? "heart.fill" : "heart")
                .frame(minWidth: 70)
        }
        .buttonStyle(.bordered)
        .foregroundStyle(saved ? .pink : .primary)
    }

    /// 预览（右侧竖列）：从中间区域随机 3 页（避开封面/目录页），只读图不写历史进度。
    /// 带固定占位框，加载完成填图不跳版、不突兀。
    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("预览").font(.caption).foregroundStyle(.secondary)
            if previews.isEmpty {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
                    .frame(width: 170, height: 400)
                    .overlay {
                        if previewFailed {
                            Text("预览不可用").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(previews.enumerated()), id: \.offset) { i, img in
                        Button {
                            previewIndex = i
                            showPreviewViewer = true
                        } label: {
                            Image(decorative: img, scale: 1.0)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 170, height: 126)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 170)
    }

    /// 从第一章中间区域（跳过开头封面/目录）随机 3 页，并发解码；不写历史/进度
    private func loadPreviews(_ album: Album) async {
        guard let ch = album.chapters.first else { return }
        guard let chapter = try? await JmClient.shared.chapter(id: ch.id, sort: ch.sort,
                                                              title: ch.displayTitle)
        else {
            await MainActor.run { previewFailed = true }
            return
        }
        let n = chapter.pages.count
        // 从第 5 页之后随机（开头几页常是封面/目录/广告），避开最后一页
        let lo = min(4, max(0, n - 1))
        let hi = max(lo + 1, n - 1)
        let pool = Array(lo..<hi)
        let chosen = pool.shuffled().prefix(min(3, pool.count)).sorted()
        guard !chosen.isEmpty else { return }
        var imgs: [CGImage?] = Array(repeating: nil, count: chosen.count)
        await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, idx) in chosen.enumerated() {
                group.addTask { (i, await ImageStore.shared.page(chapter.pages[idx])) }
            }
            for await (i, img) in group { imgs[i] = img }
        }
        await MainActor.run {
            previews = imgs.compactMap { $0 }
            previewFailed = previews.isEmpty
        }
    }

    private func detail(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                // 左列：封面 + 简介（简介与封面顶端对齐）
                VStack(alignment: .leading, spacing: 8) {
                    CoverImage(albumId: album.id, width: 170)
                    if !album.description.isEmpty {
                        Text("简介").font(.subheadline.weight(.semibold))
                        Text(album.description)
                            .font(.callout)
                            .lineLimit(8)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .frame(width: 170, alignment: .leading)

                VStack(alignment: .leading, spacing: 9) {
                    Text(album.title).font(.title2.weight(.semibold)).lineLimit(3)
                    // 作者可点击：跳到"该作者的所有作品"（JM 没有作者实体，按作者名搜索）
                    if album.authors.isEmpty {
                        Text("未知作者").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(album.authors.enumerated()), id: \.offset) { idx, name in
                                if idx > 0 {
                                    Text("，").foregroundStyle(.secondary)
                                }
                                Button {
                                    path.append(.author(name))
                                } label: {
                                    Text(name).underline()
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .help("查看 \(name) 的所有作品")
                            }
                        }
                    }

                    // 专辑 ID：可选中 / 一键复制（方便搜索、分享）
                    HStack(spacing: 6) {
                        Text("ID \(album.id)")
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(album.id, forType: .string)
                        } label: { Image(systemName: "doc.on.doc").font(.caption) }
                        .buttonStyle(.borderless)
                        .help("复制专辑 ID")
                    }

                    HStack(spacing: 14) {
                        stat("eye", album.views)
                        stat("hand.thumbsup", album.likes)
                        stat("text.bubble", "\(album.commentCount)")
                        stat("doc.on.doc", "\(album.totalPhotos)")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            readingChapter = resumeChapterIndex(album)
                            reading = album
                        } label: {
                            Label(resumeLabel(album), systemImage: "book")
                                .frame(minWidth: 110)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)

                        if library.position(for: album.id) != nil {
                            Button("从头开始") {
                                readingChapter = 0
                                reading = album
                            }
                        }
                    }
                    .padding(.top, 4)

                    HStack(spacing: 10) {
                        downloadRow(album)
                        favoriteButton(album)
                    }
                }
                // 右侧预览列
                previewColumn
                Spacer(minLength: 0)
            }

            if !album.tags.isEmpty {
                FlowTags(tags: album.tags)
            }

            if album.chapters.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("章节 (\(album.chapters.count))").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                        ForEach(Array(album.chapters.enumerated()), id: \.element.id) { i, c in
                            Button {
                                readingChapter = i
                                reading = album
                            } label: {
                                Text(c.displayTitle)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                            }
                            .background(readMark(album, c) ? Color.accentColor.opacity(0.18)
                                                          : Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 你问的「续作」—— 服务端 related_list 直接给,不需要自己算
            if !album.related.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("相关作品 / 续作").font(.headline)
                        if album.isSeries {
                            Text("同系列").font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(album.related) { rel in
                                Button {
                                    path.append(.album(rel))
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        CoverImage(albumId: rel.id, width: 108)
                                        Text(rel.title).font(.caption).lineLimit(2)
                                            .frame(width: 108, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(22)
    }

    private func stat(_ icon: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(value.isEmpty ? "-" : value)
        }
    }

    private func readMark(_ album: Album, _ c: ChapterMeta) -> Bool {
        library.position(for: album.id)?.chapterId == c.id
    }

    private func resumeChapterIndex(_ album: Album) -> Int {
        guard let saved = library.position(for: album.id),
              let idx = album.chapters.firstIndex(where: { $0.id == saved.chapterId })
        else { return 0 }
        return idx
    }

    private func resumeLabel(_ album: Album) -> String {
        guard let saved = library.position(for: album.id) else { return "开始阅读" }
        return "继续第 \(saved.pageIndex + 1) 页"
    }

    private func load() async {
        // 打开详情即记入「最近浏览」（持久化，进程被杀也不丢）
        library.recordView(meta)
        if let cached = library.album(meta.id) {
            album = cached
            loading = false
        }
        do {
            let fresh = try await JmClient.shared.album(id: meta.id)
            album = fresh
            library.cache(fresh)
            loading = false
        } catch {
            if album == nil {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}

/// 标签自动换行（胶囊样式）。可传点击回调（分类页点标签搜索用）。
struct FlowTags: View {
    let tags: [String]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                if let onTap {
                    Button {
                        onTap(t)
                    } label: {
                        tagView(t)
                    }
                    .buttonStyle(.plain)
                } else {
                    tagView(t)
                }
            }
        }
    }

    private func tagView(_ t: String) -> some View {
        Text(t).font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.primary.opacity(0.08))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}

/// 预览查看器：与阅读器完全隔离的看图窗口。
///
/// 只显示已解码的预览图：左右切换、双击放大，**不调任何 record**——
/// 不会写历史、不会写进度、不会污染任何阅读状态。
/// 用完即走，随时可关。
private struct PreviewViewer: View {
    let images: [CGImage]
    @State var startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var zoomed = false

    init(images: [CGImage], startIndex: Int) {
        self.images = images
        self.startIndex = startIndex
        _index = State(initialValue: min(max(startIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            // 点图片旁边的黑边：直接关闭（不用 Esc/按钮）
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            if !images.isEmpty {
                Image(decorative: images[index], scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomed ? 2 : 1)
                    .onTapGesture(count: 2) { zoomed.toggle() }
                    // 图片上单击不关闭（空操作拦截，避免误关）
                    .onTapGesture(count: 1) {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 左右切换
            HStack {
                Button { prev() } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Spacer()
                Button { next() } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= images.count - 1)
            }
            .buttonStyle(.plain)
            .font(.title2)
            .padding(.horizontal, 18)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("预览 \(index + 1) / \(images.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered).font(.caption)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func prev() {
        guard index > 0 else { return }
        index -= 1
        zoomed = false
    }

    private func next() {
        guard index < images.count - 1 else { return }
        index += 1
        zoomed = false
    }
}
