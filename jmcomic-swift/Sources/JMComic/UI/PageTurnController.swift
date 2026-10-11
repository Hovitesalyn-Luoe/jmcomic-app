import SwiftUI
import AppKit

/// 阅读器「双指左右滑翻页」。
///
/// 不做跟手（页面不跟手指走）：识别到一次横向双指滑动、位移越过阈值就翻一页，
/// 翻页动画交给视图的滑动过渡。这样行为最好预测，也不会出现"弹一下"。
///
/// 方向：日漫（右→左）"手指向右 = 下一页"；国漫（左→右）相反。
/// 触控板自然滚动会影响增量符号，所以整体乘一个 directionSign。
@MainActor
final class PageTurnController: ObservableObject {
    /// +1 = 下一页，-1 = 上一页
    var onTurn: ((Int) -> Void)?
    /// +1：手指向右 = 下一页（RTL）；-1：手指向左 = 下一页（LTR）
    var directionSign: CGFloat = 1

    private var monitor: Any?
    private var accumulated: CGFloat = 0
    private var accumulatedY: CGFloat = 0
    private var active = false
    /// 手势方向已确认是"横向翻页"（而不是纵向滚动）
    private var committed = false
    private var fired = false

    /// 横向位移越过这个距离就翻页
    private let threshold: CGFloat = 40
    /// 判定手势方向所需的最小位移（第一帧增量常为 0，方向要靠积累判断）
    private let directionEpsilon: CGFloat = 10

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
        reset()
    }

    /// 一次手势结束后清标志（翻页动画播完后调用）
    func clearFlags() {
        reset()
    }

    private func reset() {
        accumulated = 0
        accumulatedY = 0
        active = false
        committed = false
        fired = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas else { return false }
        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        switch event.phase {
        case .began:
            // 手势第一帧增量经常是 0，这里不判方向（判了会把整个手势作废），
            // 等 .changed 里积累了位移再确认是横向翻页还是纵向滚动。
            reset()
            active = true
        case .changed:
            guard active, !fired else { return false }
        case .ended, .cancelled:
            // 先收尾再谈方向：手指离开那一下增量为 0，不能在这里做任何方向过滤
            reset()
            return false
        default:
            return false
        }

        accumulated += dx
        accumulatedY += dy

        if !committed {
            // 纵向明显 → 这是滚动不是翻页，整个手势放手不管
            if abs(accumulatedY) >= directionEpsilon, abs(accumulatedY) > abs(accumulated) {
                active = false
                return false
            }
            // 横向位移攒够了才认定是翻页手势（从这里开始吞事件）
            guard abs(accumulated) >= directionEpsilon else { return false }
            committed = true
        }

        if abs(accumulated) >= threshold, !fired {
            fired = true
            let next = (accumulated * directionSign) > 0
            onTurn?(next ? 1 : -1)
        }
        return true
    }
}
