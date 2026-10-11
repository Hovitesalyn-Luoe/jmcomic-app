import SwiftUI
import AppKit

enum Route: Hashable {
    case album(AlbumMeta)
    /// 作者作品页（JM 没有作者实体，按作者名搜索即为"该作者的所有作品"）
    case author(String)
}

enum Feed: String, CaseIterable, Identifiable {
    case hot = "热门"
    case latest = "最新"
    case history = "历史"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .hot: return "flame"
        case .latest: return "clock.badge"
        case .history: return "book.closed"
        }
    }
}
/// 侧边栏选中项：内容页 / 推荐 / 收藏 / 本地 / 设置（设置是独立页面，不再是弹窗）
enum SidebarItem: Hashable {
    case feed(Feed)
    case personalized
    case categories
    case recent
    case favorites
    case local
    case settings

    /// 滚动位置记忆用的页面键（只在内存里用，重启不保留）
    var scrollKey: String {
        switch self {
        case .feed(let f): return "feed-\(f.rawValue)"
        case .personalized: return "personalized"
        case .categories: return "categories"
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .local: return "local"
        case .settings: return "settings"
        }
    }
}
