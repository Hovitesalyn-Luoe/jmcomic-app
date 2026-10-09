import SwiftUI

/// 分类/标签浏览页（腾讯视频式：左侧固定分类栏，右侧直接切换内容，不跳页面）。
///
/// 数据来源：
/// - 官方大类（同人/单本/短篇/韩漫/美漫/cosplay/3D/其他）→ categories/filter
/// - 官方子分类（中文/日语/CG/青年漫…）→ categories/filter
/// - 常用分类词 → 搜索
/// - 热门标签（hot_tags 动态）→ 搜索
struct CategoriesView: View {

    /// 左侧分类项：分类 slug 走官方筛选，关键词走搜索
    private enum SideItem: Hashable {
        case category(slug: String, name: String)
        case keyword(String)
        var name: String {
            switch self {
            case .category(_, let name): return name
            case .keyword(let k): return k
            }
        }
        /// 持久化用的稳定键：分类用 slug，标签加 k: 前缀
        /// （"其他"在官方分类和子分类里都存在，只用名字会串）
        var storageKey: String {
            switch self {
            case .category(let slug, _): return "c:" + slug
            case .keyword(let k): return "k:" + k
            }
        }
    }

    private static let categories: [(String, String)] = [
        ("doujin", "同人"), ("single", "单本"), ("short", "短篇"),
        ("hanman", "韩漫"), ("meiman", "美漫"),
        ("doujin_cosplay", "cosplay"), ("3D", "3D"), ("another", "其他"),
    ]
    private static let subCategories: [(String, String)] = [
        ("chinese", "中文"), ("japanese", "日语"), ("CG", "CG"),
        ("youth", "青年漫"), ("other", "其他"),
    ]
    /// 常用分类词（服务端没有全量标签接口，用搜索覆盖常用标签）
    private static let keywords: [String] = [
        "純愛", "NTR", "百合", "偽娘", "獸人", "觸手",
        "科幻", "奇幻", "校園", "辦公室", "兄妹", "老師",
        "偶像", "足控", "癡女", "人妻", "女僕", "亂倫",
        "中出", "全彩", "AI繪圖",
    ]

    @State private var selected: Set<SideItem> = []
    @State private var items: [AlbumMeta] = []
    @State private var loading = false
    @State private var error: String?
    @State private var hotTags: [String] = []
    @State private var path: [Route] = []
    @StateObject private var library = LibraryStore.shared
    /// 请求序号：防快速切换时旧请求覆盖新结果（竞态）
    @State private var loadSeq = 0

    var body: some View {
        NavigationStack(path: $path) {
            HStack(spacing: 0) {
                leftBar
                Divider()
                rightPane
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
        .navigationTitle("分类")
        .task {
            await loadTags()
            // 恢复上次的勾选，并直接把结果取回来（回到上次的状态）
            restoreSelectionIfNeeded()
        }
    }

    // MARK: - 记住上次的勾选

    private static let savedSelectionKey = "categorySelectionKeys"

    private func saveSelection() {
        UserDefaults.standard.set(selected.map(\.storageKey), forKey: Self.savedSelectionKey)
    }

    private static func item(forStorageKey key: String) -> SideItem? {
        if key.hasPrefix("k:") {
            let k = String(key.dropFirst(2))
            return k.isEmpty ? nil : .keyword(k)
        }
        if key.hasPrefix("c:") {
            let slug = String(key.dropFirst(2))
            if let hit = (categories + subCategories).first(where: { $0.0 == slug }) {
                return .category(slug: hit.0, name: hit.1)
            }
        }
        return nil
    }

    private func restoreSelectionIfNeeded() {
        guard selected.isEmpty else { return }
        let keys = UserDefaults.standard.stringArray(forKey: Self.savedSelectionKey) ?? []
        let restored = keys.compactMap { Self.item(forStorageKey: $0) }
        guard !restored.isEmpty else { return }
        selected = Set(restored)
        loadSeq += 1
        let seq = loadSeq
        Task { await load(selected, seq: seq) }
    }

    // MARK: - 左栏（固定分类列表）

    private var leftBar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                sectionTitle("官方分类")
                ForEach(Self.categories, id: \.0) { slug, name in
                    itemRow(.category(slug: slug, name: name))
                }
                sectionTitle("子分类")
                ForEach(Self.subCategories, id: \.0) { slug, name in
                    itemRow(.category(slug: slug, name: name))
                }
                sectionTitle("常用")
                ForEach(Self.keywords, id: \.self) { k in
                    itemRow(.keyword(k))
                }
                if !hotTags.isEmpty {
                    sectionTitle("热门标签")
                    ForEach(hotTags, id: \.self) { t in
                        itemRow(.keyword(t))
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 170)
        .background(Color.primary.opacity(0.03))
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.caption).foregroundStyle(.secondary)
            .padding(.top, 10).padding(.bottom, 2)
    }

    private func itemRow(_ item: SideItem) -> some View {
        let isOn = selected.contains(item)
        return Button {
            var new = selected
            if new.contains(item) { new.remove(item) } else { new.insert(item) }
            selected = new
            saveSelection()
            // 立即清掉旧结果，避免显示与当前选择无关的内容
            items = []
            error = nil
            loadSeq += 1
            let seq = loadSeq
            Task { await load(new, seq: seq) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.caption2)
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右栏（内容）

    @ViewBuilder
    private var rightPane: some View {
        if selected.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                Text("在左侧勾选分类/标签（可多选）\n多个标签 = 组合搜索；混选分类 = 并集")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            VStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(error).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty && !loading {
            Text("没有符合条件的作品").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(selectedNames).font(.headline).lineLimit(1)
                    Spacer()
                    Button("清除选择") {
                        selected.removeAll()
                        saveSelection()
                        items = []
                    }
                    .buttonStyle(.borderless).font(.caption)
                    if loading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 18).padding(.top, 12)

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
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private var selectedNames: String {
        selected.map(\.name).sorted().joined(separator: " + ")
    }

    // MARK: - 加载

    private func loadTags() async {
        if let tags = try? await JmClient.shared.hotTags() {
            hotTags = tags
        }
    }

    /// 多选加载：
    /// - 纯标签：逐个标签单独搜索，取 **id 交集**（精准「都包含」），单标签直接搜
    /// - 混选分类：各分类拉取 + 标签搜索，并集去重
    /// seq 序号过期（期间又点了别的）则丢弃结果，防竞态覆盖。
    private func load(_ sel: Set<SideItem>, seq: Int) async {
        guard seq == loadSeq, !sel.isEmpty else { return }
        loading = true
        error = nil
        defer { if seq == loadSeq { loading = false } }
        let keywords = sel.compactMap { item -> String? in
            if case .keyword(let k) = item { return k }
            return nil
        }
        let cats = sel.compactMap { item -> String? in
            if case .category(let s, _) = item { return s }
            return nil
        }
        do {
            let raw: [AlbumMeta]
            if cats.isEmpty {
                if keywords.count <= 1 {
                    let r = try await JmClient.shared.search(keywords.first ?? "", page: 1)
                    raw = r.items
                } else {
                    // 多标签：并发搜索，取 id 交集 = 全部标签都包含的作品
                    var results: [[AlbumMeta]] = []
                    await withTaskGroup(of: [AlbumMeta].self) { group in
                        for k in keywords {
                            group.addTask {
                                (try? await JmClient.shared.search(k, page: 1))?.items ?? []
                            }
                        }
                        for await r in group { results.append(r) }
                    }
                    guard let first = results.first else {
                        raw = []
                        if seq == loadSeq { items = [] }
                        return
                    }
                    var common = Set(first.map(\.id))
                    for r in results.dropFirst() {
                        common.formIntersection(Set(r.map(\.id)))
                    }
                    raw = first.filter { common.contains($0.id) }
                }
            } else {
                // 含分类：各分类并集 + 标签并集
                var map: [String: AlbumMeta] = [:]
                for slug in cats {
                    if let r = try? await JmClient.shared.categories(slug, page: 1) {
                        for m in r.items { map[m.id] = m }
                    }
                }
                if !keywords.isEmpty,
                   let r = try? await JmClient.shared.search(keywords.joined(separator: " "), page: 1) {
                    for m in r.items { map[m.id] = m }
                }
                raw = Array(map.values)
            }
            guard seq == loadSeq else { return }
            items = await library.filterByExclusions(raw)
        } catch {
            if seq == loadSeq { self.error = error.localizedDescription }
        }
    }
}
