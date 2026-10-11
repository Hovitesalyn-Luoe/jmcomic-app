import SwiftUI
import CoreGraphics

// MARK: - 页显示单元

/// 核心里的一页：加载 →（可选裁黑）→ 显示。支持双击局部放大。
/// 图怎么来由 [loadImage] 决定（在线=ImageStore 下载缓存；本地=ImageIO 读文件）。
struct ReaderPageCell: View {
    let index: Int
    /// 显示宽度（高度按 ratio 推）
    let width: CGFloat
    /// 高/宽（裁黑开着时是裁后的比例）
    let ratio: CGFloat
    /// 裁掉贴边黑带（只影响显示）
    let trimBlack: Bool
    /// 裁剪缓存键：唯一到"某一张图"（图片 URL/路径），不同本子同页号不许撞
    let pageKey: String
    let loadImage: (Int) async -> CGImage?
    /// 分析完裁剪框、布局该按新比例重排时调用
    let onTrim: () -> Void

    @State private var image: CGImage?
    @State private var failed = false
    @State private var zoomed = false
    @State private var zoomAnchor = UnitPoint(x: 0.5, y: 0.5)

    private var targetSize: CGSize {
        CGSize(width: width, height: (width * ratio).rounded())
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: targetSize.width, height: targetSize.height)
                    .scaleEffect(zoomed ? 2 : 1, anchor: zoomAnchor)
                    .onTapGesture(count: 2, coordinateSpace: .local) { loc in
                        let h = max(targetSize.height, 1)
                        zoomAnchor = UnitPoint(x: loc.x / max(width, 1), y: loc.y / h)
                        zoomed.toggle()
                    }
            } else {
                Rectangle()
                    .fill(Color(white: 0.13))
                    .frame(width: targetSize.width, height: targetSize.height)
                    .overlay {
                        if failed {
                            VStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("加载失败").font(.caption)
                                Button("重试") { failed = false; load() }
                                    .buttonStyle(.link)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .clipped()
        .task(id: index) { load() }
    }

    private func load() {
        Task {
            guard let img = await loadImage(index) else {
                await MainActor.run { self.failed = true }
                return
            }
            if trimBlack {
                // 黑带分析放后台：逐行扫全图不便宜
                let trim = await Task.detached(priority: .utility) {
                    TrimCache.shared.trim(for: pageKey, image: img)
                }.value
                let shown = img.cropping(to: trim.rect) ?? img
                await MainActor.run {
                    self.image = shown
                    onTrim()
                }
            } else {
                await MainActor.run { self.image = img }
            }
        }
    }
}

// MARK: - 阅读核心

/// 在线/本地共用的阅读核心：画面排布（单页/连续/双页、适应窗口、裁黑）、
/// 翻页（双指滑/键盘/跳页条）、沉浸顶栏、进度恢复与记录。
///
/// 两套阅读器的差异全部从外部注入：
/// - 图从哪来：[loadImage]
/// - 比例：[ratioProvider]
/// - 进度/预取：[record] / [prefetch]
/// - 顶栏附加控件与列表尾部：[headerExtra]（章节选择）/ [footer]（下一话）
struct ReaderCore<Header: View, Footer: View>: View {

    // MARK: 注入

    /// 偏好按作品记的键
    let albumId: String
    let title: String
    /// 换章/换文件时换这个值，核心状态整体重置并重新定位
    let loadToken: Int
    let pageCount: Int
    /// 打开时恢复到第几页（0 起；nil 从头）
    let restorePage: Int?
    /// 每页 高/宽（不带裁剪修正，修正由核心做）
    let ratioProvider: (Int) -> CGFloat
    /// 每页唯一键（图片 URL/路径，裁剪缓存用）
    let pageKeyProvider: (Int) -> String
    let loadImage: (Int) async -> CGImage?
    let record: (Int) -> Void
    let prefetch: (Int) -> Void
    @ViewBuilder var headerExtra: () -> Header
    @ViewBuilder var footer: () -> Footer

    /// 首帧就带恢复锚点布局：不然 LazyVStack 先摆第一页、锚点随后才生效，肉眼就是"闪一下"
    init(albumId: String,
         title: String,
         loadToken: Int,
         pageCount: Int,
         restorePage: Int?,
         ratioProvider: @escaping (Int) -> CGFloat,
         pageKeyProvider: @escaping (Int) -> String,
         loadImage: @escaping (Int) async -> CGImage?,
         record: @escaping (Int) -> Void,
         prefetch: @escaping (Int) -> Void,
         @ViewBuilder headerExtra: @escaping () -> Header,
         @ViewBuilder footer: @escaping () -> Footer) {
        self.albumId = albumId
        self.title = title
        self.loadToken = loadToken
        self.pageCount = pageCount
        self.restorePage = restorePage
        self.ratioProvider = ratioProvider
        self.pageKeyProvider = pageKeyProvider
        self.loadImage = loadImage
        self.record = record
        self.prefetch = prefetch
        self.headerExtra = headerExtra
        self.footer = footer

        let mode = ReaderPrefs.albumMode(albumId) ?? ReaderPrefs.currentMode()
        // 偏好初值必须在这里读：首帧若用默认值（连续），会先挂错布局、
        // 把恢复位置冲掉（双页进度"记不住"的根源）
        _readerMode = State(initialValue: mode)
        _paging = State(initialValue: ReaderPrefs.albumPaging(albumId) ?? ReaderPrefs.currentPaging())
        _fitMode = State(initialValue: ReaderPrefs.fitMode(albumId))
        _trimBlack = State(initialValue: ReaderPrefs.trimBlack(albumId))
        _pageGap = State(initialValue: ReaderPrefs.gap(albumId: albumId))
        _pageSize = State(initialValue: ReaderPrefs.size(albumId: albumId))

        let initialScreens = ReaderPrefs.screens(pageCount: pageCount, mode: mode)
        let target = ReaderPrefs.screenIndex(of: restorePage ?? 0, in: initialScreens)
        _visiblePage = State(initialValue: restorePage ?? 0)
        _sliderPage = State(initialValue: Double((restorePage ?? 0) + 1))
        _currentScreen = State(initialValue: target)
        _scrollTarget = State(initialValue: target)
    }

    // MARK: 阅读状态

    @Environment(\.dismiss) private var dismiss

    @State private var visiblePage = 0
    /// 恢复定位完成前不写进度，防止打开瞬间把旧进度覆盖成第一页
    @State private var allowRecord = true

    // 沉浸顶栏：点击才出现，出现后 3 秒自动收起
    @State private var chromeVisible = false
    @State private var chromeHideTask: Task<Void, Never>?
    // 键盘监听（方向键翻页）
    @State private var keyboardMonitor: Any?
    // 跳页：统一入口（键盘/跳页条/翻页都写这里，列表消费）
    @State private var jumpTarget: Int?
    @State private var sliderPage = 1.0
    /// 恢复锚点（scrollPosition 双保险定位）
    @State private var scrollTarget: Int?

    // 阅读偏好用 @AppStorage：设置里改完立刻生效（也会自动落盘）
    /// 当前生效的阅读方式（进入时读该作品的记录，没记过才用设置里的默认）
    @State private var readerMode: ReaderMode = .continuous
    @AppStorage(ReaderPrefs.directionKey) private var spreadDirection: SpreadDirection = ReaderPrefs.currentDirection()
    /// 当前生效的翻页方式（同样按作品记）
    @State private var paging: PagingStyle = .vertical

    /// 左右翻页：当前第几屏
    @State private var currentScreen = 0
    /// 翻页动画方向（+1 下一页）
    @State private var turnDirection = 1
    @StateObject private var pageTurn = PageTurnController()

    private var horizontalPaging: Bool { paging == .horizontal && readerMode != .continuous }

    /// 连续（长条）一页比窗口高，"适应窗口"没法整页嵌，按铺满宽度算
    private var effectiveFit: FitMode {
        readerMode == .continuous && fitMode == .window ? .width : fitMode
    }

    // 每本漫画单独记：画面适配方式 + 宽度系数 + 间距 + 裁黑
    @State private var fitMode: FitMode = .window
    @State private var pageGap: Double = 0
    @State private var pageSize: Double = 1.0
    /// 裁掉贴边黑带（默认关，按作品记）
    @State private var trimBlack = false
    /// 裁剪框算完后的布局重排信号
    @State private var trimRevision = 0
    /// 顶栏「画面」弹窗（适配方式 / 大小 / 间距 / 裁黑）
    @State private var showDisplayOptions = false

    private var screens: [[Int]] {
        ReaderPrefs.screens(pageCount: pageCount, mode: readerMode)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            content
                .background(Color(white: 0.11))
        }
        .contentShape(Rectangle())
        // 单击任意处：切换控制栏（双击放大不受影响）
        .onTapGesture(count: 1) { toggleChrome() }
        .overlay(alignment: .top) {
            toolbar
                .offset(y: chromeVisible ? 0 : -70)
                .animation(.easeOut(duration: 0.22), value: chromeVisible)
        }
        .overlay(alignment: .bottom) {
            jumpBar
                .offset(y: chromeVisible ? 0 : 90)
                .animation(.easeOut(duration: 0.22), value: chromeVisible)
        }
        .onChange(of: readerMode) { _, m in ReaderPrefs.setAlbumMode(m, albumId: albumId) }
        .onChange(of: paging) { _, st in ReaderPrefs.setAlbumPaging(st, albumId: albumId) }
        .onChange(of: fitMode) { _, m in ReaderPrefs.setFitMode(m, albumId: albumId) }
        .onChange(of: trimBlack) { _, on in
            ReaderPrefs.setTrimBlack(on, albumId: albumId)
            trimRevision += 1
        }
        .onChange(of: showDisplayOptions) { _, open in
            if open {
                // 画面弹窗开着：掐掉自动收起计时，别在哥哥调画面时把顶栏收走
                chromeHideTask?.cancel()
            } else {
                showChromeTemporarily()
            }
        }
        .task(id: loadToken) { reset() }
        .onAppear { installKeyboard() }
        .onDisappear {
            if let m = keyboardMonitor { NSEvent.removeMonitor(m); keyboardMonitor = nil }
        }
    }

    /// 换章/换文件：读偏好、恢复位置
    private func reset() {
        fitMode = ReaderPrefs.fitMode(albumId)
        trimBlack = ReaderPrefs.trimBlack(albumId)
        pageGap = ReaderPrefs.gap(albumId: albumId)
        pageSize = ReaderPrefs.size(albumId: albumId)
        readerMode = ReaderPrefs.albumMode(albumId) ?? ReaderPrefs.currentMode()
        paging = ReaderPrefs.albumPaging(albumId) ?? ReaderPrefs.currentPaging()

        let target = restorePage ?? 0
        visiblePage = target
        sliderPage = Double(target + 1)
        currentScreen = ReaderPrefs.screenIndex(of: target, in: screens)
        scrollTarget = currentScreen
        allowRecord = target == 0
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if pageCount <= 0 {
            centered { Text("这一话没有图片").foregroundStyle(.secondary) }
        } else if horizontalPaging {
            horizontalPager
        } else {
            pageList
        }
    }

    // MARK: - 左右翻页

    private var horizontalPager: some View {
        GeometryReader { geo in
            // 套一层纵向滚动：条漫一页很高，左右翻页模式下也要能上下看
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ZStack {
                        if screens.indices.contains(currentScreen) {
                            screenRow(screens[currentScreen], geo: geo)
                                .id(currentScreen)
                                // 先只做平滑过渡：不加任何方向性的位移动效
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .id("screenTop")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // 换屏后回顶：上一屏可能已滚到半腰，新屏要从头看
                .onChange(of: currentScreen) { _, _ in
                    proxy.scrollTo("screenTop", anchor: .top)
                }
            }
        }
        .onAppear {
            // currentScreen 由 init/reset 定位，这里不许再反推（会把恢复位置冲掉）
            pageTurn.onTurn = { delta in turn(delta) }
            // 日漫（右→左）时"手指向右 = 下一页"，左→右时相反
            pageTurn.directionSign = spreadDirection == .rightToLeft ? 1 : -1
            pageTurn.start()
            // 左右翻页的恢复定位是瞬时的（currentScreen 直接到位），
            // 稍等布局落定后就开始记录进度
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                allowRecord = true
            }
        }
        .onDisappear { pageTurn.stop() }
        .onChange(of: spreadDirection) { _, dir in
            pageTurn.directionSign = dir == .rightToLeft ? 1 : -1
        }
        .onChange(of: jumpTarget) { _, t in
            guard let t else { return }
            let target = ReaderPrefs.screenIndex(of: t, in: screens)
            guard screens.indices.contains(target) else { jumpTarget = nil; return }
            turnDirection = target >= currentScreen ? 1 : -1
            withAnimation(.easeInOut(duration: 0.2)) { currentScreen = target }
            pageTurn.clearFlags()
            let first = screens[target].first ?? 0
            visiblePage = first
            sliderPage = Double(first + 1)
            if allowRecord { record(first) }
            jumpTarget = nil
        }
    }

    private func turn(_ delta: Int) {
        let target = currentScreen + delta
        guard screens.indices.contains(target) else { return }
        turnDirection = delta
        withAnimation(.easeInOut(duration: 0.2)) { currentScreen = target }
        pageTurn.clearFlags()
        let first = screens[target].first ?? 0
        visiblePage = first
        sliderPage = Double(first + 1)
        prefetch(first)
        if allowRecord { record(first) }
    }

    // MARK: - 连续滚动 / 翻页列表

    private var pageList: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: pageGap) {
                        // 滚动偏移追踪：用于沉浸式顶栏（滚动隐藏，停止显示）
                        GeometryReader { g in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: g.frame(in: .named("jmscroll")).minY)
                        }
                        .frame(height: 0)

                        ForEach(Array(screens.enumerated()), id: \.offset) { sIndex, group in
                            screenRow(group, geo: geo)
                                .id(sIndex)
                                .onAppear {
                                    let first = group.first ?? 0
                                    // 恢复定位完成前：行出现不算"当前页"，防止把恢复位置冲掉
                                    guard allowRecord else { return }
                                    visiblePage = first
                                    sliderPage = Double(first + 1)
                                    prefetch(first)
                                    record(first)
                                }
                        }
                        footer()
                    }
                    .frame(maxWidth: .infinity)
                    .scrollTargetLayout()
                    .scrollPosition(id: $scrollTarget)
                }
                .coordinateSpace(name: "jmscroll")
                .scrollIndicators(readerMode == .continuous ? .automatic : .hidden)
                // 静默定位期间隐藏，就位后淡入
                .opacity(allowRecord ? 1 : 0)
                .onPreferenceChange(ScrollOffsetKey.self) { _ in
                    // 滚动中收起控制栏
                    hideChrome()
                }
                .onChange(of: jumpTarget) { _, t in
                    guard let t else { return }
                    let target = ReaderPrefs.screenIndex(of: t, in: screens)
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    jumpTarget = nil
                }
                .onAppear {
                    // 挂载先静默定位：LazyVStack 首帧总会先摆第 0 行，锚点下一帧才生效，
                    // 这几十毫秒里把列表藏起来，就位后淡入——肉眼不再"先第一页再闪"
                    allowRecord = false
                    let target = max(visiblePage, 0)
                    if target > 0 {
                        // 锚点未生效时的兜底：密集重试 scrollTo（都在淡入前完成）
                        for d in [0.01, 0.05, 0.12] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                                let scr = ReaderPrefs.screenIndex(of: target, in: screens)
                                proxy.scrollTo(scr, anchor: .top)
                            }
                        }
                    }
                    // 定位落定后淡入并开始记录进度
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        withAnimation(.easeOut(duration: 0.2)) { allowRecord = true }
                    }
                }
            }
        }
    }

    // MARK: - 排布

    /// 一"屏"的排布：双页等高对开（按方向决定谁在左），其它模式一屏一页；
    /// 每页尺寸由画面适配方式算出（适应窗口 = 整屏恰好嵌进窗口，打开即契合）
    @ViewBuilder
    private func screenRow(_ group: [Int], geo: GeometryProxy) -> some View {
        let sizes = ReaderPrefs.screenPageSizes(
            ratios: group.map { ratio($0) },
            window: geo.size, gap: pageGap, fit: effectiveFit, scale: pageSize)
        if readerMode == .spread, group.count == 2 {
            HStack(alignment: .top, spacing: pageGap) {
                if spreadDirection == .leftToRight {
                    pageCell(group[0], width: sizes[0].width)
                    pageCell(group[1], width: sizes[1].width)
                } else {
                    // 日漫：后一页在左，前一页在右
                    pageCell(group[1], width: sizes[1].width)
                    pageCell(group[0], width: sizes[0].width)
                }
            }
        } else {
            pageCell(group.first ?? 0, width: sizes[0].width)
        }
    }

    @ViewBuilder
    private func pageCell(_ index: Int, width: CGFloat) -> some View {
        if index >= 0, index < pageCount {
            ReaderPageCell(index: index, width: width, ratio: ratio(index),
                           trimBlack: trimBlack, pageKey: pageKeyProvider(index),
                           loadImage: loadImage) {
                trimRevision += 1
            }
        }
    }

    /// 页面高/宽比（裁黑开着时用裁后的比例）
    private func ratio(_ index: Int) -> CGFloat {
        _ = trimRevision   // 裁剪框算完后布局要重排
        if trimBlack, let t = TrimCache.shared.cached(pageKeyProvider(index)) { return t.ratio }
        return ratioProvider(index)
    }

    // MARK: - 顶栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Label("关闭", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(title)

            headerExtra()

            if pageCount > 0 {
                Text("\(min(visiblePage + 1, pageCount)) / \(pageCount)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            Menu {
                Picker("阅读方式", selection: $readerMode) {
                    ForEach(ReaderMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if readerMode != .continuous {
                    Divider()
                    Picker("翻页方式", selection: $paging) {
                        ForEach(PagingStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.inline)
                }
                if readerMode == .spread {
                    Divider()
                    Picker("双页方向", selection: $spreadDirection) {
                        ForEach(SpreadDirection.allCases) { dir in
                            Text(dir.shortLabel).tag(dir)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(readerMode.label, systemImage: readerMode.icon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help("阅读方式：单页 / 连续 / 双页（双页时第 1 页单独，之后两两对开）")

            Button {
                showDisplayOptions.toggle()
            } label: {
                Label("画面", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .help("画面：适配方式 / 大小 / 间距 / 裁黑（按作品记住）")
            .popover(isPresented: $showDisplayOptions, arrowEdge: .top) {
                displayOptions
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    // MARK: - 底部跳页条

    private var jumpBar: some View {
        // Slider 的 range 不能是 1...1（Normalizing 断言会崩），只有一页时不渲染
        Group {
            if pageCount > 1 {
                HStack(spacing: 10) {
                    Image(systemName: "book")
                        .font(.caption).foregroundStyle(.secondary)
                    Slider(value: $sliderPage, in: 1...Double(pageCount), step: 1) { editing in
                        if editing {
                            // 拖动期间保持顶栏可见：先唤出、再暂停自动收起计时
                            showChromeTemporarily()
                            chromeHideTask?.cancel()
                        } else {
                            jumpTarget = min(max(Int(sliderPage) - 1, 0), pageCount - 1)
                            showChromeTemporarily()
                        }
                    }
                    .frame(maxWidth: 300)
                    // 只镜像滑块：右→左阅读时拖动方向与翻页方向一致（文字不翻）
                    .scaleEffect(x: spreadDirection == .rightToLeft ? -1 : 1)
                    Text("\(Int(sliderPage)) / \(pageCount)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 70, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - 顶栏行为

    /// 点击切换控制栏：出现时再点一次就收起
    private func toggleChrome() {
        if chromeVisible { hideChrome() } else { showChromeTemporarily() }
    }

    /// 显示控制栏，3 秒后自动收起
    private func showChromeTemporarily() {
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = true }
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // 弹窗开着或计时被取消：不收（弹窗关闭时会重新计时）
            guard !Task.isCancelled, !showDisplayOptions else { return }
            hideChrome()
        }
    }

    /// 收起控制栏（并取消自动收起计时）
    private func hideChrome() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
        withAnimation(.easeOut(duration: 0.18)) { chromeVisible = false }
    }

    /// 顶栏「画面」弹窗：适配方式 / 大小 / 间距 / 裁黑（都按作品记）
    private var displayOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("画面适配", selection: $fitMode) {
                ForEach(FitMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("适应窗口=整屏恰好嵌进窗口（打开即契合）；适应宽度=铺满宽度往下滚；手动=自己拖大小。")
                .font(.caption2).foregroundStyle(.secondary)

            if fitMode == .manual {
                HStack(spacing: 8) {
                    Text("大小").font(.caption).frame(width: 32, alignment: .leading)
                    Slider(value: $pageSize, in: 0.5...1.5, step: 0.05) { editing in
                        if !editing { ReaderPrefs.setSize(pageSize, albumId: albumId) }
                    }
                    .frame(width: 180)
                    Text("\(Int(pageSize * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }

            HStack(spacing: 8) {
                Text("间距").font(.caption).frame(width: 32, alignment: .leading)
                Slider(value: $pageGap, in: 0...60, step: 1) { editing in
                    if !editing { ReaderPrefs.setGap(pageGap, albumId: albumId) }
                }
                .frame(width: 180)
                Text("\(Int(pageGap))pt")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Toggle(isOn: $trimBlack) {
                Text("裁掉贴边黑带").font(.caption)
            }
            Text("只裁整条贯穿的纯黑边带（扫描件黑边），画面里的黑不碰；默认关。")
                .font(.caption2).foregroundStyle(.secondary)

            Text("都按作品记住。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - 键盘

    private func installKeyboard() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved]) { ev in
            // 鼠标移动不唤出控制栏：按需求"不点击就不出现"
            if ev.type == .mouseMoved { return ev }
            switch ev.keyCode {
            case 123:            // ← 上一页
                self.pageStep(-1)
                return nil
            case 124, 49:        // → / 空格 下一页
                self.pageStep(1)
                return nil
            default:
                return ev
            }
        }
    }

    private func pageStep(_ delta: Int) {
        let total = max(pageCount, 1)
        let target = max(0, min(visiblePage + delta, total - 1))
        guard target != visiblePage else { return }
        jumpTarget = target
        hideChrome()
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 滚动偏移追踪（沉浸式顶栏用）
private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
