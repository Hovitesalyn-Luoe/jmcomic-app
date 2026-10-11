import SwiftUI
import CoreGraphics

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
        let startPage = restorePage ?? 0
        _session = State(initialValue: ReaderSession(restorePage: startPage,
                                                     visiblePage: startPage,
                                                     positioning: startPage > 0))
        _sliderPage = State(initialValue: Double(startPage + 1))
        _currentScreen = State(initialValue: target)
        _scrollTarget = State(initialValue: target)
    }

    // MARK: 阅读状态

    @Environment(\.dismiss) var dismiss

    /// 阅读会话生命周期（恢复 / 静默定位 / 记录），状态只在 ReaderSession 里演化
    @State var session = ReaderSession()

    // 沉浸顶栏：点击才出现，出现后 3 秒自动收起
    @State var chromeVisible = false
    @State var chromeHideTask: Task<Void, Never>?
    // 键盘监听（方向键翻页）
    @State var keyboardMonitor: Any?
    // 跳页：统一入口（键盘/跳页条/翻页都写这里，列表消费）
    @State var jumpTarget: Int?
    @State var sliderPage = 1.0
    /// 恢复锚点（scrollPosition 双保险定位）
    @State var scrollTarget: Int?

    // 阅读偏好用 @AppStorage：设置里改完立刻生效（也会自动落盘）
    /// 当前生效的阅读方式（进入时读该作品的记录，没记过才用设置里的默认）
    @State var readerMode: ReaderMode = .continuous
    @AppStorage(ReaderPrefs.directionKey) var spreadDirection: SpreadDirection = ReaderPrefs.currentDirection()
    /// 当前生效的翻页方式（同样按作品记）
    @State var paging: PagingStyle = .vertical

    /// 左右翻页：当前第几屏
    @State var currentScreen = 0
    /// 翻页动画方向（+1 下一页）
    @State var turnDirection = 1
    @StateObject var pageTurn = PageTurnController()

    var horizontalPaging: Bool { paging == .horizontal && readerMode != .continuous }

    /// 连续（长条）一页比窗口高，"适应窗口"没法整页嵌，按铺满宽度算
    var effectiveFit: FitMode {
        readerMode == .continuous && fitMode == .window ? .width : fitMode
    }

    // 每本漫画单独记：画面适配方式 + 宽度系数 + 间距 + 裁黑
    @State var fitMode: FitMode = .window
    @State var pageGap: Double = 0
    @State var pageSize: Double = 1.0
    /// 裁掉贴边黑带（默认关，按作品记）
    @State var trimBlack = false
    /// 裁剪框算完后的布局重排信号
    @State var trimRevision = 0
    /// 顶栏「画面」弹窗（适配方式 / 大小 / 间距 / 裁黑）
    @State var showDisplayOptions = false

    var screens: [[Int]] {
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
        session = ReaderSession(restorePage: target, visiblePage: target,
                                positioning: target > 0)
        sliderPage = Double(target + 1)
        currentScreen = ReaderPrefs.screenIndex(of: target, in: screens)
        scrollTarget = currentScreen
    }
}
