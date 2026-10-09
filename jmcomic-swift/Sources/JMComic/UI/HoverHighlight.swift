import SwiftUI
import AppKit

/// 可点内容的悬停反馈：淡蓝底 + 强调色 + 手型光标。
///
/// 为什么不用 `.help(...)`：那是系统 tooltip，要停 1~2 秒才出现，
/// 用户挪上去没反应会以为"这里不能点"。这个修饰器鼠标一进入立刻生效。
private struct HoverHighlight: ViewModifier {
    @State private var hovering = false
    var cornerRadius: CGFloat = 5
    /// 未悬停时的颜色（默认次级灰；链接类内容可传 .primary 之类）
    var idleColor: Color = .secondary

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(hovering ? Color.accentColor.opacity(0.18) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .foregroundStyle(hovering ? Color.accentColor : idleColor)
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

extension View {
    /// 悬停立即高亮 + 手型光标（用于"看起来像文字、其实能点"的内容）
    func hoverHighlight(cornerRadius: CGFloat = 5, idleColor: Color = .secondary) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius, idleColor: idleColor))
    }
}
