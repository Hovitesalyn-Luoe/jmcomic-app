import SwiftUI
import AppKit

enum Route: Hashable {
    case album(AlbumMeta)
    /// 作者作品页（JM 没有作者实体，按作者名搜索即为"该作者的所有作品"）
    case author(String)
}

enum Feed: String, CaseIterable, Identifiable {
    case hot = "热门"
    case latest = "最新"
    case history = "历史"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .hot: return "flame"
        case .latest: return "clock.badge"
        case .history: return "book.closed"
        }
    }
}

/// 滚动偏移追踪（浏览位置恢复用）
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// 直接把底层 NSScrollView 滚到指定偏移。
/// scrollPosition/scrollTo 对懒加载视口外的目标不可靠，这是最终兜底：
/// 一次性定位（targetY 消费后置 nil），不干扰后续用户滚动。
private struct ScrollRestorer: NSViewRepresentable {
    var targetY: Double?
    let onRestored: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let targetY, let scroll = Self.findScrollView(nsView) else { return }
        let y = CGFloat(targetY)
        if abs(scroll.contentView.bounds.origin.y - y) > 1 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        DispatchQueue.main.async { onRestored() }
    }

    private static func findScrollView(_ v: NSView) -> NSScrollView? {
        var cur: NSView? = v
        while let c = cur {
            if let s = c as? NSScrollView { return s }
            cur = c.superview
        }
        return nil
    }
}

/// 侧边栏选中项：内容页 / 推荐 / 收藏 / 本地 / 设置（设置是独立页面，不再是弹窗）
enum SidebarItem: Hashable {
    case feed(Feed)
    case personalized
    case categories
    case recent
    case favorites
    case local
    case settings
}

struct BrowseView: View {

    @State private var selection: SidebarItem = .feed(.hot)
    /// 侧边栏是否展开（⌘S 切换，见 App.swift 的命令）
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var path: [Route] = []

    @StateObject private var library = LibraryStore.shared
    @StateObject private var downloads = DownloadStore.shared

    /// 每个 tab 完全独立的浏览状态：切走不丢、重启后也从缓存恢复
    private struct FeedState {
        var items: [AlbumMeta] = []
        var page = 1
        var totalPages = 1
        var scrollID: String?
        var scrollOffset: Double = 0
        var loading = false
        var error: String?

        init() {}
        func toCache() -> FeedCacheEntry {
            FeedCacheEntry(items: items, page: page, totalPages: totalPages,
                           scrollID: scrollID, scrollOffset: scrollOffset)
        }
        init(from c: FeedCacheEntry) {
            items = c.items
            page = c.page
            totalPages = c.totalPages
            scrollID = c.scrollID
            scrollOffset = c.scrollOffset ?? 0
        }
    }
    @State private var feedStates: [Feed: FeedState] = [:]
    /// 当前 feed 的滚动锚点（scrollPosition 双向绑定）
    @State private var scrollID: String?
    /// 当前 feed 的滚动偏移（像素，滚动时记录；返回/切回时用 NSScrollView 精确恢复）
    @State private var scrollOffset: Double = 0
    /// 恢复目标：非 nil 时 ScrollRestorer 会把滚动条定位到这里
    @State private var restoreTarget: Double?

    // 搜索是临时视图，不进 tab 缓存，避免污染热门/最新已加载的内容
    @State private var searching = false
    @State private var query = ""
    @State private var searchItems: [AlbumMeta] = []

    private var feed: Feed {
        if case .feed(let f) = selection { return f }
        return .hot
    }

    private var state: FeedState {
        get { feedStates[feed] ?? FeedState() }
        nonmutating set { feedStates[feed] = newValue }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { sidebarVisible ? .all : .detailOnly },
            set: { sidebarVisible = ($0 != .detailOnly) }
        )) {
            List(selection: $selection) {
                Section("内容") {
                    ForEach(Feed.allCases.filter { $0 != .history }) { f in
                        Label(f.rawValue, systemImage: f.icon).tag(SidebarItem.feed(f))
                    }
                    Label("为你推荐", systemImage: "sparkles").tag(SidebarItem.personalized)
                    Label("分类", systemImage: "square.grid.2x2").tag(SidebarItem.categories)
                }
                Section("浏览") {
                    Label("历史", systemImage: "book.closed")
                        .badge(library.history.count).tag(SidebarItem.feed(.history))
                    Label("最近浏览", systemImage: "clock")
                        .badge(library.recentlyViewed.count).tag(SidebarItem.recent)
                    Label("我的收藏", systemImage: "heart")
                        .badge(FavoriteStore.shared.entries.count).tag(SidebarItem.favorites)
                }
                Section("本地") {
                    Label("本地漫画", systemImage: "arrow.down.circle")
                        .badge(downloads.library.count).tag(SidebarItem.local)
                }
                Section("系统") {
                    Label("设置", systemImage: "gearshape").tag(SidebarItem.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) {
                // 快速保护：一键最小化，隐私开关/快捷键在设置页配
                Button {
                    NSApp.keyWindow?.miniaturize(nil)
                } label: {
                    Label("保护（最小化）", systemImage: "shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击立即最小化窗口，防旁人看到屏幕")
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        } detail: {
            switch selection {
            case .settings:
                SettingsView()
            case .favorites:
                FavoritesView()
            case .local:
                LocalLibraryView()
            case .personalized:
                PersonalizedView()
            case .categories:
                CategoriesView()
            case .recent:
                RecentView()
            case .feed:
                NavigationStack(path: $path) {
                    grid
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .album(let meta):
                                AlbumDetailView(meta: meta, path: $path)
                            case .author(let name):
                                AuthorWorksView(author: name, path: $path)
                            }
                        }
                }
            }
        }
        .onChange(of: selection) { old, new in
            if case .feed(let f) = old {
                feedStates[f]?.scrollID = scrollID
                feedStates[f]?.scrollOffset = scrollOffset
                if let st = feedStates[f] {
                    library.saveFeedCache(f.rawValue, st.toCache())
                }
            }
            switch new {
            case .settings, .favorites, .local, .personalized, .categories, .recent:
                path = []
            case .feed(let f):
                searching = false
                query = ""
                scrollID = feedStates[f]?.scrollID
                // 返回/切回时按记录的偏移精确恢复（scrollTo 对懒加载不可靠）
                restoreTarget = feedStates[f]?.scrollOffset
                // 未初始化才加载：优先磁盘缓存恢复位置，否则网络
                if feedStates[f] == nil {
                    Task { await restoreOrLoad(f) }
                }
            }
        }
        .onChange(of: path) { _, newPath in
            if newPath.isEmpty {
                // 从详情返回：恢复滚动位置（此时 scrollOffset 还是 push 前的值）
                restoreTarget = feedStates[feed]?.scrollOffset ?? scrollOffset
            } else {
                // 进入详情：保存当前位置，防止返回后滚动重建把偏移归零
                feedStates[feed]?.scrollOffset = scrollOffset
            }
        }
        .task { await restoreOrLoad(.hot) }
        .searchable(text: $query, prompt: "搜索本子或作者")
        .onSubmit(of: .search) { Task { await runSearch() } }
        .toolbar {
            // 刷新当前列表（热门/最新）；不碰搜索框位置
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload(feed) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("刷新")
                .disabled(searching || feed == .history)
            }
        }
    }

    // MARK: - 内容页（热门/最新/历史）

    @ViewBuilder
    private var grid: some View {
        // 历史走本地库（与热门/最新网络源完全隔离）；搜索是临时视图
        let shown = feed == .history ? library.history
                   : (searching ? searchItems : state.items)
        let st = state
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                // 滚动偏移追踪：记录当前滚动位置，返回/切回时精确恢复
                GeometryReader { g in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self,
                        value: g.frame(in: .named("jmfeed")).minY)
                }
                .frame(height: 0)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 18) {
                    ForEach(shown) { meta in
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
                // 记住/恢复滚动位置：切 tab 不再回顶
                .scrollPosition(id: $scrollID)
                .padding(18)

                if st.loading {
                    ProgressView().padding(.bottom, 24)
                } else if canLoadMore {
                    Button("加载更多") { Task { await loadMore() } }
                        .padding(.bottom, 26)
                }

                // 精确恢复：直接操作底层 NSScrollView，懒加载也不受影响
                ScrollRestorer(targetY: restoreTarget) {
                    restoreTarget = nil
                }
            }
            .coordinateSpace(name: "jmfeed")
            .onPreferenceChange(ScrollOffsetKey.self) { minY in
                // 内容顶相对视口顶的偏移（向下为正）
                scrollOffset = -minY
            }
            .overlay(alignment: .bottomTrailing) {
                // 需要回顶时点这里，而不是强制每次切换都回顶
                if scrollID != nil && scrollID != shown.first?.id {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(shown.first?.id, anchor: .top)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(Color.accentColor.opacity(0.9))
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .buttonStyle(.plain)
                    .help("回到顶部")
                    .padding(20)
                }
            }
        }
        .overlay {
            if let error = st.error, shown.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                    Text(error).foregroundStyle(.secondary)
                    Button("重试") { Task { await reload(feed) } }
                }
            } else if shown.isEmpty && !st.loading && !searching {
                Text(feed == .history ? "还没有阅读记录" : "没有结果")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(searching ? "搜索：\(query)" : feed.rawValue)
    }

    /// 恢复或加载：磁盘缓存优先（回到上次浏览位置），否则网络拉取
    private func restoreOrLoad(_ f: Feed) async {
        if let cached = library.cachedFeed(f.rawValue), !cached.items.isEmpty {
            let s = FeedState(from: cached)
            feedStates[f] = s
            if f == feed {
                scrollID = cached.scrollID
                scrollOffset = cached.scrollOffset ?? 0
                restoreTarget = cached.scrollOffset ?? 0
            }
            return
        }
        await reload(f)
    }

    private var canLoadMore: Bool {
        !searching && feed != .history && state.page < state.totalPages
    }

    private func reload(_ f: Feed) async {
        guard f != .history else { return }
        var s = feedStates[f] ?? FeedState()
        s.page = 1
        s.items = []
        feedStates[f] = s
        await fetch(f, reset: true)
    }

    private func loadMore() async {
        let f = feed
        if let cur = feedStates[f] {
            feedStates[f]?.page = cur.page + 1
        }
        await fetch(f, reset: false)
    }

    /// 抓取时锁定当时的 feed，切走也不会写错 tab
    private func fetch(_ f: Feed, reset: Bool) async {
        guard f != .history else { return }
        feedStates[f]?.loading = true
        feedStates[f]?.error = nil
        let page = feedStates[f]?.page ?? 1
        do {
            let result: PagedAlbums
            switch f {
            case .hot: result = try await JmClient.shared.hot(page: page)
            case .latest: result = try await JmClient.shared.latest(page: page)
            case .history: return
            }
            if reset {
                feedStates[f]?.items = await library.filterByExclusions(result.items)
            } else {
                var cur = feedStates[f]?.items ?? []
                cur += await library.filterByExclusions(result.items)
                feedStates[f]?.items = cur
            }
            feedStates[f]?.totalPages = max(result.totalPages, 1)
            // 拉取完成即落盘，重启后可恢复
            if let st = feedStates[f] {
                library.saveFeedCache(f.rawValue, st.toCache())
            }
        } catch {
            feedStates[f]?.error = error.localizedDescription
        }
        feedStates[f]?.loading = false
    }

    private func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            searching = false
            await reload(feed)
            return
        }
        // 纯数字输入：视为专辑 ID，直接打开详情（搜索接口不认 ID）
        if text.allSatisfy(\.isNumber) {
            searching = false
            path.append(.album(AlbumMeta(id: text, title: "专辑 \(text)", authors: [])))
            return
        }
        searching = true
        searchItems = []
        feedStates[feed]?.loading = true
        feedStates[feed]?.error = nil
        do {
            let result = try await JmClient.shared.search(text, page: 1)
            searchItems = result.items
        } catch {
            feedStates[feed]?.error = error.localizedDescription
        }
        feedStates[feed]?.loading = false
    }
}
