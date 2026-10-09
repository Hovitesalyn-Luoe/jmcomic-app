import SwiftUI

/// 各标签页的滚动位置记忆。
///
/// - 位置用"顶部可见项的 id"表示：恢复时把它写回 `scrollPosition` 即可，
///   纯 SwiftUI 实现（ScrollViewReader / scrollPosition），不依赖 AppKit 兜底。
/// - 只存在内存里：同一次运行内切走再切回会回到原处，重启 App 不保留。
@MainActor
final class ScrollMemory: ObservableObject {
    static let shared = ScrollMemory()

    /// pageKey → 顶部可见项 id
    private var positions: [String: String] = [:]
    /// pageKey → 回顶请求计数（自增一次 = 收到一次"回到顶部"）
    @Published private(set) var topRequests: [String: Int] = [:]
    /// pageKey → 还原请求计数（从详情页返回根视图时自增，用来重新定位）
    @Published private(set) var restoreRequests: [String: Int] = [:]
    /// 最近显示过的页面键（详情页关闭时用它来还原"刚才那个列表"）
    private var lastVisiblePage: String?

    func position(for page: String) -> String? { positions[page] }

    func save(_ id: String?, for page: String) {
        guard let id, !id.isEmpty else { return }
        positions[page] = id
    }

    func requestTop(for page: String) { topRequests[page, default: 0] += 1 }

    func topRequest(for page: String) -> Int { topRequests[page] ?? 0 }

    func requestRestore(for page: String) { restoreRequests[page, default: 0] += 1 }

    /// 页面出现时登记（用于详情页关闭时知道该还原谁）
    func noteVisible(_ page: String) { lastVisiblePage = page }

    /// 详情页关闭 → 请当前列表重新定位到记忆的位置
    func requestRestoreForLastVisible() {
        guard let page = lastVisiblePage else { return }
        requestRestore(for: page)
    }

    func restoreRequest(for page: String) -> Int { restoreRequests[page] ?? 0 }
}

/// 给任意滚动视图挂上"记忆位置 + 响应回顶"。
/// 用法：
/// ```
/// @State private var scrolledID: String?
/// ...
/// ScrollView { ... }        // 子项必须有 .id(...)
///     .scrollMemory(page: "hot", scrolledID: $scrolledID, topID: items.first?.id)
/// ```
private struct ScrollMemoryModifier: ViewModifier {
    let page: String
    @Binding var scrolledID: String?
    let topID: String?
    /// false = 只响应"回到顶部"，不记忆/不还原位置（静态页面用）
    var remember: Bool = true
    /// 当前是否在根视图（导航栈为空）。从详情页返回时由 false 变 true，
    /// 这个时刻才是"该还原位置"的时机 —— 快速进出详情页时列表不会被重建，
    /// 光靠 onAppear 抓不到。
    var atRoot: Bool = true
    @ObservedObject private var memory = ScrollMemory.shared

    /// 还原位置。
    ///
    /// 两个坑都要躲开：
    /// 1) 从详情页返回时 ScrollView 已重建、内容回到顶部，而绑定里的值没变过，
    ///    直接再赋同一个值 SwiftUI 不会滚动 —— 所以先清空再写回；
    /// 2) 懒加载的封面还没铺好时，这次定位会被随后的布局变化冲掉（表现为归顶），
    ///    所以短时间内多试几次；一旦用户自己滚动了（绑定变成别的值）立刻收手。
    private func restoreIfNeeded(force: Bool = false) {
        guard remember, let saved = memory.position(for: page) else { return }
        guard force || scrolledID == nil else { return }
        Task { @MainActor in
            for attempt in 0..<5 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(attempt < 3 ? 120 : 300))
                    // 用户自己滚过了就不再抢
                    if let current = scrolledID, current != saved { return }
                }
                scrolledID = nil
                try? await Task.sleep(for: .milliseconds(16))   // 让出一帧，逼它重新定位
                scrolledID = saved
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: $scrolledID)
            .onChange(of: scrolledID) { _, newValue in
                if remember { memory.save(newValue, for: page) }
            }
            // 内容就绪（topID 从 nil 变成有值）后还原上次位置
            .onChange(of: topID) { _, _ in restoreIfNeeded() }
            // 每次出现都登记 + 强制还原一次（首次无记忆则无操作）
            .onAppear {
                memory.noteVisible(page)
                restoreIfNeeded(force: true)
            }
            // 详情页关闭时的通用还原请求
            .onChange(of: memory.restoreRequest(for: page)) { _, _ in
                restoreIfNeeded(force: true)
            }
            // 从详情页返回根视图：立即还原（快进快出也能回到原位）
            .onChange(of: atRoot) { _, isRoot in
                if isRoot { restoreIfNeeded(force: true) }
            }
            // 工具栏「回到顶部」
            .onChange(of: memory.topRequest(for: page)) { _, _ in
                if let topID { scrolledID = topID }
            }
    }
}

extension View {
    func scrollMemory(page: String, scrolledID: Binding<String?>, topID: String?,
                      remember: Bool = true, atRoot: Bool = true) -> some View {
        modifier(ScrollMemoryModifier(page: page, scrolledID: scrolledID, topID: topID,
                                      remember: remember, atRoot: atRoot))
    }
}
