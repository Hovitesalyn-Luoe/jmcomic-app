import SwiftUI
import CoreGraphics

/// 滚动偏移追踪（浏览位置恢复 / 阅读器沉浸顶栏共用）
struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
