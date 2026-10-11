import SwiftUI

/// 在线阅读器外壳：章节加载 / 章节切换 / 下一话 / 预取。
/// 阅读本体（排布、翻页、顶栏、进度）在 [ReaderCore]，两套阅读器共用一份。
struct ReaderView: View {

    let album: Album
    @State var chapterIndex: Int
    /// 「从头开始」入口：本次阅读不恢复进度，从第一页起
    var restart: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryStore.shared

    @State private var chapter: Chapter?
    @State private var loading = true
    @State private var error: String?
    @State private var knownRatios: [String: CGFloat] = [:]
    /// 打开时恢复到第几页（只在进度记录的那一话生效）
    @State private var restorePage: Int?

    private var chapterMeta: ChapterMeta { album.chapters[chapterIndex] }

    var body: some View {
        Group {
            if loading {
                ProgressView("加载中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadChapter() } }
                        .buttonStyle(.link)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let chapter, !chapter.pages.isEmpty {
                ReaderCore(
                    albumId: album.id,
                    title: album.title,
                    loadToken: chapterIndex,
                    pageCount: chapter.pages.count,
                    restorePage: restorePage,
                    ratioProvider: { knownRatios[chapter.pages[$0].id] ?? (1807.0 / 1280.0) },
                    pageKeyProvider: { chapter.pages[$0].id },
                    loadImage: { await ImageStore.shared.page(chapter.pages[$0]) },
                    record: { library.record(album: album, chapter: chapterMeta, page: $0) },
                    prefetch: { prefetch(around: $0, in: chapter) },
                    headerExtra: { chapterPicker },
                    footer: { nextChapterFooter }
                )
            } else {
                Text("这一话没有图片").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(white: 0.11))
        .task(id: chapterIndex) { await loadChapter() }
        .onDisappear { library.flushState() }
    }

    // MARK: - 顶栏附加：章节选择

    @ViewBuilder
    private var chapterPicker: some View {
        if album.chapters.count > 1 {
            Picker("", selection: $chapterIndex) {
                ForEach(Array(album.chapters.enumerated()), id: \.offset) { i, c in
                    Text(c.displayTitle).tag(i)
                }
            }
            .labelsHidden()
            .frame(width: 160)
        }
    }

    // MARK: - 列表尾部：下一话

    @ViewBuilder
    private var nextChapterFooter: some View {
        if chapterIndex + 1 < album.chapters.count {
            Button {
                chapterIndex += 1
            } label: {
                Label("下一话：\(album.chapters[chapterIndex + 1].displayTitle)",
                      systemImage: "arrow.down.circle")
                    .padding(.vertical, 18)
            }
            .buttonStyle(.borderless)
            .onAppear {
                // 连续模式：滚到底（footer 露出）自动切下一话；
                // 切章后新话第一页 onAppear 会记录进度，历史自动同步
                let mode = ReaderPrefs.albumMode(album.id) ?? ReaderPrefs.currentMode()
                guard mode == .continuous else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if chapterIndex + 1 < album.chapters.count {
                        chapterIndex += 1
                    }
                }
            }
        }
    }

    // MARK: - 加载

    private func loadChapter() async {
        loading = true
        error = nil
        let meta = chapterMeta
        do {
            let c = try await JmClient.shared.chapter(id: meta.id, sort: meta.sort,
                                                     title: meta.displayTitle)
            // 比例预取：排布要按每页真实比例算
            var ratios: [String: CGFloat] = [:]
            for p in c.pages {
                ratios[p.id] = await ImageStore.shared.aspectRatio(for: p)
            }
            knownRatios = ratios
            // 恢复位置只在进度记录的那一话生效（「从头开始」不恢复）
            if !restart,
               let saved = library.position(for: album.id), saved.chapterId == meta.id {
                restorePage = min(saved.pageIndex, max(0, c.pages.count - 1))
            } else {
                restorePage = nil
            }
            chapter = c
            loading = false
            await ImageStore.shared.prefetch(Array(c.pages.prefix(4)))
        } catch {
            self.error = error.localizedDescription
            loading = false
        }
    }

    private func prefetch(around index: Int, in chapter: Chapter) {
        let upper = min(index + 5, chapter.pages.count)
        guard index + 1 < upper else { return }
        let slice = Array(chapter.pages[(index + 1)..<upper])
        Task { await ImageStore.shared.prefetch(slice) }
    }
}
