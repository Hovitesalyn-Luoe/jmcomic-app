/// 阅读会话的生命周期：**静默定位期 → 就位 → 记录**。
///
/// 恢复进度、静默定位、进度记录的状态只在这一处演化——它们曾经散落在
/// init / reset / 行出现 / 兜底滚动四个地方互相踩，双页"记不住进度"、
/// 连续"先闪第一页"都是这么来的。
struct ReaderSession {
    /// 打开时恢复到的页（0 起）
    var restorePage = 0
    /// 当前所在页
    var visiblePage = 0
    /// 静默定位期：列表隐藏、行出现不算"当前页"、不写进度
    var positioning = true

    /// 可以写进度了吗
    var recordAllowed: Bool { !positioning }
    /// 列表可见吗（静默期隐藏，就位后淡入）
    var listVisible: Bool { !positioning }

    /// 某一行出现在视野里。静默期忽略（防止把恢复位置冲掉）；就位后更新当前页。
    /// 返回是否有效（无效时调用方不许写进度）。
    mutating func rowAppeared(first: Int) -> Bool {
        guard !positioning else { return false }
        visiblePage = first
        return true
    }

    /// 定位落定，进入正常阅读（开始记录进度）
    mutating func positioned() {
        positioning = false
    }
}
