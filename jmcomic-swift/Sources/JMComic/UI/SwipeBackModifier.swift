import SwiftUI

/// 把「两指向右滑返回」做成一个独立组件，任何页面一行就能挂上：
///
/// ```swift
/// .swipeBackToPrevious { path.removeLast() }
/// // 弹窗打开时临时关掉：
/// .swipeBackToPrevious(enabled: !showingSheet) { dismiss() }
/// ```
///
/// 行为：小球从内容左缘（侧栏分界线）长出来 → 跟手 → 滑到行程 90% 后松手才触发；
/// 中途松手或往回拉则收回；指针停在可横向滚动的内容附近时放行给那个组件。
private struct SwipeBackModifier: ViewModifier {
    let enabled: Bool
    let onCommit: () -> Void

    @StateObject private var controller = SwipeBackController()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                if controller.offset > 0.5 {
                    BackBall(progress: min(1, controller.offset / controller.trigger))
                        .offset(x: controller.offset - 30)
                        .allowsHitTesting(false)
                }
            }
            .onAppear {
                controller.onCommit = onCommit
                if enabled { controller.start() }
            }
            .onChange(of: enabled) { _, on in
                on ? controller.start() : controller.stop()
            }
            .onDisappear { controller.stop() }
    }
}

extension View {
    /// 两指向右滑返回（小球从分界线滑出，滑到位松手触发 onCommit）
    func swipeBackToPrevious(enabled: Bool = true, onCommit: @escaping () -> Void) -> some View {
        modifier(SwipeBackModifier(enabled: enabled, onCommit: onCommit))
    }
}
