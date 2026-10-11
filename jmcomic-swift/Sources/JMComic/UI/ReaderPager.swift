import SwiftUI
import CoreGraphics

extension ReaderCore {

    // MARK: - 内容

    @ViewBuilder
    var content: some View {
        if pageCount <= 0 {
            centered { Text("这一话没有图片").foregroundStyle(.secondary) }
        } else if horizontalPaging {
            horizontalPager
        } else {
            pageList
        }
    }

    // MARK: - 左右翻页

    var horizontalPager: some View {
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
                session.positioned()
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
            session.visiblePage = first
            sliderPage = Double(first + 1)
            if session.recordAllowed { record(first) }
            jumpTarget = nil
        }
    }

    func turn(_ delta: Int) {
        let target = currentScreen + delta
        guard screens.indices.contains(target) else { return }
        turnDirection = delta
        withAnimation(.easeInOut(duration: 0.2)) { currentScreen = target }
        pageTurn.clearFlags()
        let first = screens[target].first ?? 0
        session.visiblePage = first
        sliderPage = Double(first + 1)
        prefetch(first)
        if session.recordAllowed { record(first) }
    }

    // MARK: - 连续滚动 / 翻页列表

    var pageList: some View {
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
                                    // 静默定位期：行出现不算"当前页"、不写进度（ReaderSession 把关）
                                    guard session.rowAppeared(first: first) else { return }
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
                .opacity(session.listVisible ? 1 : 0)
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
                    session.positioning = true
                    let target = max(session.visiblePage, 0)
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
                        withAnimation(.easeOut(duration: 0.2)) { session.positioned() }
                    }
                }
            }
        }
    }

    // MARK: - 排布

    /// 一"屏"的排布：双页等高对开（按方向决定谁在左），其它模式一屏一页；
    /// 每页尺寸由画面适配方式算出（适应窗口 = 整屏恰好嵌进窗口，打开即契合）
    @ViewBuilder
    func screenRow(_ group: [Int], geo: GeometryProxy) -> some View {
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
    func pageCell(_ index: Int, width: CGFloat) -> some View {
        if index >= 0, index < pageCount {
            ReaderPageCell(index: index, width: width, ratio: ratio(index),
                           trimBlack: trimBlack, pageKey: pageKeyProvider(index),
                           loadImage: loadImage) {
                trimRevision += 1
            }
        }
    }

    /// 页面高/宽比（裁黑开着时用裁后的比例）
    func ratio(_ index: Int) -> CGFloat {
        _ = trimRevision   // 裁剪框算完后布局要重排
        if trimBlack, let t = TrimCache.shared.cached(pageKeyProvider(index)) { return t.ratio }
        return ratioProvider(index)
    }

}

