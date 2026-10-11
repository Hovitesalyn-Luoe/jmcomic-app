import SwiftUI
import CoreGraphics
import ImageIO

/// 本地章节阅读器外壳（CBZ / 散图文件夹）：解压、扫图、比例预取。
/// 阅读本体（排布、翻页、顶栏、进度）在 [ReaderCore]，两套阅读器共用一份。
///
/// CBZ 先用系统 ditto 解压到缓存目录（Application Support/JMComic/LocalCache），
/// 解压一次后直接读缓存，不重复解压。图片由 ImageIO 直接从本地文件解码，不走网络。
struct LocalReaderView: View {

    let chapter: DownloadedChapter
    /// 所属本子（本地阅读进度与在线阅读共用同一份历史）
    let meta: AlbumMeta

    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = LibraryStore.shared

    @State private var pages: [URL] = []
    @State private var failed: String?
    /// 每页 高/宽（读文件头拿到，不解码）
    @State private var ratios: [URL: CGFloat] = [:]
    /// 打开时恢复到第几页
    @State private var restorePage: Int?

    var body: some View {
        Group {
            if let failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(failed).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if pages.isEmpty {
                ProgressView("读取本地章节…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ReaderCore(
                    albumId: meta.id,
                    title: chapter.chapterTitle,
                    loadToken: 0,
                    pageCount: pages.count,
                    restorePage: restorePage,
                    ratioProvider: { ratios[pages[$0]] ?? (1807.0 / 1280.0) },
                    pageKeyProvider: { pages[$0].path },
                    loadImage: { await Self.decode(pages[$0]) },
                    record: { library.recordLocal(meta: meta, chapter: chapter, page: $0) },
                    prefetch: { _ in },
                    headerExtra: { EmptyView() },
                    footer: { EmptyView() }
                )
            }
        }
        .background(Color(white: 0.11))
        .task { await prepare() }
    }

    // MARK: - 图片列表准备

    private func prepare() async {
        let urls: [URL]?
        if chapter.format == .cbz {
            urls = await extractCBZ()
        } else {
            urls = Self.folderPages(URL(fileURLWithPath: chapter.path))
        }
        // 读每页像素尺寸（只读文件头，不解码）：画面适配要按比例排
        var rs: [URL: CGFloat] = [:]
        if let urls {
            for u in urls {
                if let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                   let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                   let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0 {
                    rs[u] = h / w
                }
            }
        }
        await MainActor.run {
            guard let urls, !urls.isEmpty else {
                failed = "本地文件读取失败（可能已被移动或删除）"
                return
            }
            ratios = rs
            pages = urls
            // 与在线阅读共用进度：同一话则从上次页码继续
            if let saved = library.position(for: meta.id),
               saved.chapterId == chapter.chapterId {
                restorePage = min(saved.pageIndex, max(0, urls.count - 1))
            }
        }
    }

    /// CBZ：解压到缓存目录（已解压则直接复用）
    private func extractCBZ() async -> [URL]? {
        let src = URL(fileURLWithPath: chapter.path)
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let cache = base.appendingPathComponent("JMComic/LocalCache",
                                                isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = DownloadStore.sanitize(src.deletingPathExtension().lastPathComponent)
        let dest = cache.appendingPathComponent(name, isDirectory: true)

        let existing = Self.folderPages(dest)
        if existing == nil || existing!.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-xk", src.path, dest.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do {
                try p.run()
                p.waitUntilExit()
            } catch { return nil }
            guard p.terminationStatus == 0 else { return nil }
        }
        return Self.folderPages(dest)
    }

    /// 目录里的图片按文件名排序（下载时就是 0001.jpg 这样命名）
    private static func folderPages(_ dir: URL) -> [URL]? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }
        let exts = ["jpg", "jpeg", "png", "webp", "gif"]
        return items
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 本地文件解码
    private static func decode(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
