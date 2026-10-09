import SwiftUI
import AppKit


/// 触控板「双指向右 → 返回」手势。
///
/// 为什么用 NSEvent 监听：两根手指滑动发出的是 scrollWheel 事件（精确增量），
/// 不是 .swipe 事件；SwiftUI 也没有暴露"可交互式返回"。这里读增量驱动一个
/// 「返回小球」，滑到位立刻返回。
///
/// 与横滑组件的关系：指针停在可以左右滚动的内容上时（例如"相关作品"横排），
/// 那个滚动视图本来就会吃掉横向滚动，这里再做命中检测直接放行。
@MainActor
final class SwipeBackController: ObservableObject {
    /// 小球当前位置（0 = 贴在分界线上）
    @Published var offset: CGFloat = 0

    /// 小球行程
    let maxTravel: CGFloat = 112 * 0.85   // 95.2pt
    /// 滑到行程的 90% 并松手才触发返回（跟着 maxTravel 自动缩放）
    var trigger: CGFloat { maxTravel * 0.9 }
    /// 横滑组件的容错边距：指针落在组件范围外这么多以内，也算"在横滑组件上"，
    /// 避免只差几像素就误触发返回。
    static let scrollerSlop: CGFloat = 20

    private var monitor: Any?
    private var active = false
    private var decided = false
    private var stepCount = 0
    /// 返回动作（由视图注入）
    var onCommit: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        offset = 0
        active = false
        decided = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // 先处理"结束"，再谈方向：
        // 手指离开时那一下增量是 0，方向判断会把它当成纵向滑动丢掉，
        // 于是永远等不到 .ended（实测：开始 4 次、结束 0 次）。
        let isEnd = (event.phase == .ended || event.phase == .cancelled
                     || event.momentumPhase == .ended)
        if isEnd {
            guard active, !decided else { active = false; return false }
            active = false
            decided = true
            if offset >= trigger {
                // 滑到底 + 松手 → 返回
                withAnimation(.easeOut(duration: 0.18)) { offset = maxTravel }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    self?.onCommit?()
                    withAnimation(.easeOut(duration: 0.15)) { self?.offset = 0 }
                }
            } else {
                // 没滑到底（或者中途往回拉了）→ 收回，不返回
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { offset = 0 }
            }
            return true
        }

        guard abs(dx) > abs(dy) else { return false }   // 只处理横向为主的滑动

        switch event.phase {
        case .began:
            let overScroller = Self.isOverHorizontalScroller(event)
            guard !overScroller else { return false }
            active = true
            decided = false
            offset = 0        // 从分界线开始，保证小球是"长出来"的
            stepCount = 0
        case .changed:
            guard active, !decided else { return false }
        default:
            return false
        }

        // 只有最开头两三下放缓，保证小球是"从分界线长出来"的；
        // 之后 1:1 跟手（之前全程限幅 12pt，快速滑动时会追不上手指、像划不动）。
        var step = dx
        if stepCount < 3 {
            let maxStep: CGFloat = 12
            step = max(-maxStep, min(maxStep, step))
        }
        stepCount += 1
        offset = min(maxTravel, max(0, offset + step))

        // 到位只是"准备好返回"（小球推到底），真正的判定在松手那一刻
        return true
    }

    // MARK: - 命中检测：指针是否落在"可以左右滚动"的视图里

    /// 只靠 hitTest 不够：SwiftUI 会在上面盖一层处理手势的视图，命中不到内部的
    /// NSScrollView（实测在"相关作品"横排上滑照样触发了返回）。所以再做一次兜底：
    /// 遍历窗口里所有 NSScrollView，凡是"能横滚"且范围盖住指针的都算命中。
    private static func isOverHorizontalScroller(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow,
              let root = window.contentView else { return false }
        let point = root.convert(event.locationInWindow, from: nil)

        // ① 顺着命中链往上找
        var view = root.hitTest(point)
        while let cur = view {
            if let scroll = cur as? NSScrollView, isHorizontal(scroll) {
                return true
            }
            view = cur.superview
        }

        // ② 兜底：窗口里所有能横滚的视图，范围盖住指针就算命中
        for sub in allSubviews(root) {
            guard let scroll = sub as? NSScrollView, isHorizontal(scroll) else { continue }
            let frame = scroll.convert(scroll.bounds, to: nil)
            // 容错：向外放宽 scrollerSlop，指针擦边也算
            let relaxed = frame.insetBy(dx: -Self.scrollerSlop, dy: -Self.scrollerSlop)
            if relaxed.contains(event.locationInWindow) {
                let inside = frame.contains(event.locationInWindow)
                return true
            }
        }
        return false
    }

    private static func isHorizontal(_ scroll: NSScrollView) -> Bool {
        if scroll.hasHorizontalScroller { return true }
        let docWidth = scroll.documentView?.frame.width ?? 0
        return docWidth > scroll.contentView.bounds.width + 1
    }

    private static func allSubviews(_ view: NSView) -> [NSView] {
        var out: [NSView] = []
        for sub in view.subviews {
            out.append(sub)
            out.append(contentsOf: allSubviews(sub))
        }
        return out
    }
}
