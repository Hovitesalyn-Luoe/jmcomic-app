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

    func position(for page: String) -> String? { positions[page] }

    func save(_ id: String?, for page: String) {
        guard let id, !id.isEmpty else { return }
        positions[page] = id
    }

    func requestTop(for page: String) { topRequests[page, default: 0] += 1 }

    func topRequest(for page: String) -> Int { topRequests[page] ?? 0 }
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
    @ObservedObject private var memory = ScrollMemory.shared

    func body(content: Content) -> some View {
        content
            .scrollPosition(id: $scrolledID)
            .onChange(of: scrolledID) { _, newValue in
                if remember { memory.save(newValue, for: page) }
            }
            // 内容就绪（topID 从 nil 变成有值）后，若还没有位置就还原上次的
            .onChange(of: topID) { _, _ in
                if remember, scrolledID == nil, let saved = memory.position(for: page) {
                    scrolledID = saved
                }
            }
            // 工具栏「回到顶部」
            .onChange(of: memory.topRequest(for: page)) { _, _ in
                if let topID { scrolledID = topID }
            }
    }
}

extension View {
    func scrollMemory(page: String, scrolledID: Binding<String?>, topID: String?,
                      remember: Bool = true) -> some View {
        modifier(ScrollMemoryModifier(page: page, scrolledID: scrolledID, topID: topID, remember: remember))
    }
}
