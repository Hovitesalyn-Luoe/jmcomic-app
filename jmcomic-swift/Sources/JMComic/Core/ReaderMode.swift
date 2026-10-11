import SwiftUI

/// 阅读方式：单页翻页 / 连续长条 / 双页对开
enum ReaderMode: String, CaseIterable, Identifiable {
    case single       // 一次一页（图适配窗口）
    case continuous   // 长条连续滚动
    case spread       // 双页对开（第 1 页单独，之后两两成对）

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "单页"
        case .continuous: return "连续"
        case .spread: return "双页"
        }
    }

    var icon: String {
        switch self {
        case .single: return "doc"
        case .continuous: return "scroll"
        case .spread: return "book"
        }
    }
}

/// 双页对开的翻页方向：日漫右→左（默认），或者左→右。
enum SpreadDirection: String, CaseIterable, Identifiable {
    case rightToLeft
    case leftToRight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightToLeft: return "右 → 左（日漫）"
        case .leftToRight: return "左 → 右（国漫 / 韩漫）"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightToLeft: return "右 → 左"
        case .leftToRight: return "左 → 右"
        }
    }
}

/// 翻页方式：上下滚动（默认，保持原有手感）或左右翻页（一屏一页/一对，用双指左右滑）
enum PagingStyle: String, CaseIterable, Identifiable {
    case vertical
    case horizontal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "上下滚动"
        case .horizontal: return "左右翻页"
        }
    }

    var shortLabel: String {
        switch self {
        case .vertical: return "上下"
        case .horizontal: return "左右"
        }
    }
}

/// 画面适配方式：图片怎么嵌阅读窗口。
enum FitMode: String, CaseIterable, Identifiable {
    case window   // 适应窗口：整屏（单页 / 对开跨页）恰好嵌进窗口，打开即契合
    case width    // 适应宽度：铺满窗口宽度，高度自适应往下滚
    case manual   // 手动：用「大小」滑块自己缩放

    var id: String { rawValue }

    var label: String {
        switch self {
        case .window: return "适应窗口"
        case .width: return "适应宽度"
        case .manual: return "手动"
        }
    }
}

/// 阅读器相关偏好的读写（两个阅读器共用）。
enum ReaderPrefs {
    static let modeKey = "readerMode"
    static let directionKey = "readerSpreadDirection"
    static let pagingKey = "readerPagingStyle"
    /// 旧版本用的布尔键（true = 单页）；首次读取时迁移到新键
    static let legacySinglePageKey = "readerSinglePage"

    static func currentMode(defaults: UserDefaults = .standard) -> ReaderMode {
        if let raw = defaults.string(forKey: modeKey), let mode = ReaderMode(rawValue: raw) {
            return mode
        }
        // 迁移旧偏好
        let legacy = defaults.bool(forKey: legacySinglePageKey)
        let mode: ReaderMode = legacy ? .single : .continuous
        defaults.set(mode.rawValue, forKey: modeKey)
        return mode
    }

    static func currentDirection(defaults: UserDefaults = .standard) -> SpreadDirection {
        guard let raw = defaults.string(forKey: directionKey),
              let dir = SpreadDirection(rawValue: raw) else { return .rightToLeft }
        return dir
    }

    static func currentPaging(defaults: UserDefaults = .standard) -> PagingStyle {
        guard let raw = defaults.string(forKey: pagingKey),
              let style = PagingStyle(rawValue: raw) else { return .vertical }
        return style
    }

    // MARK: - 每本漫画单独的画面适配 / 间距 / 大小
    //
    // 不同作品宽窄喜好不同，所以按作品 ID 分开存。

    static let fitModeKeyPrefix = "readerFitMode_"
    /// 旧版本的布尔键（true = 适应宽度）；首次读取时迁移到 fitMode
    static let legacyFitWidthKeyPrefix = "readerFitWidth_"
    static let gapKeyPrefix = "readerGap_"

    static func fitMode(_ albumId: String, defaults: UserDefaults = .standard) -> FitMode {
        if let raw = defaults.string(forKey: fitModeKeyPrefix + albumId),
           let mode = FitMode(rawValue: raw) {
            return mode
        }
        // 迁移旧的 fitWidth 布尔偏好：开 = 适应宽度，关 = 适应窗口（新默认）
        let mode: FitMode
        if defaults.object(forKey: legacyFitWidthKeyPrefix + albumId) != nil {
            mode = defaults.bool(forKey: legacyFitWidthKeyPrefix + albumId) ? .width : .window
        } else {
            mode = .window
        }
        defaults.set(mode.rawValue, forKey: fitModeKeyPrefix + albumId)
        return mode
    }

    static func setFitMode(_ mode: FitMode, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: fitModeKeyPrefix + albumId)
    }

    /// 裁掉贴边黑带（只影响显示）。默认关，按作品记。
    static let trimBlackKeyPrefix = "readerTrimBlack_"

    static func trimBlack(_ albumId: String, defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: trimBlackKeyPrefix + albumId) != nil else { return false }
        return defaults.bool(forKey: trimBlackKeyPrefix + albumId)
    }

    static func setTrimBlack(_ on: Bool, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(on, forKey: trimBlackKeyPrefix + albumId)
    }

    /// 一"屏"里每页的显示尺寸（双页等高对开，像真书摊开）。
    /// - ratios: 每页 高/宽，与 pages 一一对应
    /// - window: 阅读区尺寸；gap: 页间距；scale: 手动模式的大小系数
    /// 适应窗口：整屏恰好嵌进窗口；适应宽度：铺满窗口宽度；手动：按 scale 缩放。
    static func screenPageSizes(ratios: [CGFloat], window: CGSize, gap: CGFloat,
                                fit: FitMode, scale: Double) -> [CGSize] {
        guard !ratios.isEmpty else { return [] }
        let gaps = gap * CGFloat(max(ratios.count - 1, 0))

        switch fit {
        case .window, .width:
            // 等高对开：以屏高 h 为基准，每页宽 = h / ratio（ratio = 高/宽）
            let invSum = ratios.reduce(CGFloat(0)) { $0 + 1 / max($1, 0.0001) }
            var h = (window.width - gaps) / invSum
            if fit == .window { h = min(h, window.height) }   // 整屏嵌进窗口
            h = max(h, 1)
            return ratios.map { CGSize(width: h / $0, height: h) }
        case .manual:
            let totalW = max(1, min(window.width, 1000) * scale)
            if ratios.count == 2 {
                // 手动保持旧手感：一人一半宽，高度各随比例
                let half = max(1, (totalW - gap) / 2)
                return ratios.map { CGSize(width: half, height: half * $0) }
            }
            let r = ratios[0]
            return [CGSize(width: totalW, height: totalW * r)]
        }
    }

    static let albumModePrefix = "readerAlbumMode_"
    static let albumPagingPrefix = "readerAlbumPaging_"

    /// 某本作品单独指定的阅读方式（没设过就是 nil，用全局默认）
    static func albumMode(_ albumId: String, defaults: UserDefaults = .standard) -> ReaderMode? {
        defaults.string(forKey: albumModePrefix + albumId).flatMap(ReaderMode.init(rawValue:))
    }

    static func setAlbumMode(_ mode: ReaderMode, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: albumModePrefix + albumId)
    }

    static func albumPaging(_ albumId: String, defaults: UserDefaults = .standard) -> PagingStyle? {
        defaults.string(forKey: albumPagingPrefix + albumId).flatMap(PagingStyle.init(rawValue:))
    }

    static func setAlbumPaging(_ style: PagingStyle, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(style.rawValue, forKey: albumPagingPrefix + albumId)
    }

    static let sizeKeyPrefix = "readerSize_"

    /// 画面大小系数（1.0 = 默认）
    static func size(albumId: String, defaults: UserDefaults = .standard) -> Double {
        let v = defaults.double(forKey: sizeKeyPrefix + albumId)
        return v > 0 ? v : 1.0
    }

    static func setSize(_ size: Double, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(size, forKey: sizeKeyPrefix + albumId)
    }

    /// 两张画面之间的距离（pt，0…60）
    static func gap(albumId: String, defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: gapKeyPrefix + albumId)
    }

    static func setGap(_ gap: Double, albumId: String, defaults: UserDefaults = .standard) {
        defaults.set(gap, forKey: gapKeyPrefix + albumId)
    }

    /// 把页序拆成"屏"：单页/连续时一屏一页；双页时封面单独、之后两两成对。
    static func screens(pageCount: Int, mode: ReaderMode) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard mode == .spread else { return (0..<pageCount).map { [$0] } }
        var out: [[Int]] = [[0]]           // 第 1 页（封面）单独
        var i = 1
        while i < pageCount {
            if i + 1 < pageCount { out.append([i, i + 1]) } else { out.append([i]) }
            i += 2
        }
        return out
    }

    /// 某一页属于第几屏（跳页、还原进度用）
    static func screenIndex(of page: Int, in screens: [[Int]]) -> Int {
        for (i, group) in screens.enumerated() where group.contains(page) { return i }
        return 0
    }
}
