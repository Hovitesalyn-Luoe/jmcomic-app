import SwiftUI
import AppKit

/// 直接把底层 NSScrollView 滚到指定偏移。
/// scrollPosition/scrollTo 对懒加载视口外的目标不可靠，这是最终兜底：
/// 一次性定位（targetY 消费后置 nil），不干扰后续用户滚动。
struct ScrollRestorer: NSViewRepresentable {
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
