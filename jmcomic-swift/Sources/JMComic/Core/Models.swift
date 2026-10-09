import Foundation

/// 列表页里的本子摘要
struct AlbumMeta: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let authors: [String]

    var authorText: String { authors.isEmpty ? "未知作者" : authors.joined(separator: ", ") }
}

/// 章节摘要
struct ChapterMeta: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let sort: Int

    var displayTitle: String {
        title.trimmingCharacters(in: .whitespaces).isEmpty ? "第 \(sort) 话" : title
    }
}

/// 本子详情
struct Album: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let title: String
    let description: String
    let authors: [String]
    let tags: [String]
    let likes: String
    let views: String
    let commentCount: Int
    let totalPhotos: Int
    let chapters: [ChapterMeta]
    /// 服务端 related_list：同系列续作 / 相关作品，无需自己算
    let related: [AlbumMeta]
    let seriesId: String

    var authorText: String { authors.isEmpty ? "未知作者" : authors.joined(separator: ", ") }
    var isSeries: Bool { seriesId != "0" && !seriesId.isEmpty }
}

/// 一页漫画
struct ComicPage: Identifiable, Hashable, Sendable {
    let id: String          // 用 URL 作为唯一标识，天然可做缓存键
    let url: URL
    let photoId: Int
    let scrambleId: Int
    let filenameWithoutExtension: String
    let isGif: Bool

    var segmentCount: Int {
        isGif ? 0 : JmCrypto.segmentCount(scrambleId: scrambleId,
                                          photoId: photoId,
                                          filenameWithoutExtension: filenameWithoutExtension)
    }
}

/// 章节详情
struct Chapter: Sendable {
    let id: String
    let title: String
    let sort: Int
    let pages: [ComicPage]
}

/// 评论（JM 移动端 /forum 接口）
struct AlbumComment: Identifiable, Sendable {
    let id: String
    let userName: String
    let content: String
    /// 已格式化的时间；取不到就是空串
    let time: String
    let likes: Int
    /// 是回复（parent_CID 非 0）
    let isReply: Bool
}

/// 分页结果
struct PagedAlbums: Sendable {
    let items: [AlbumMeta]
    let totalPages: Int
    let page: Int

    var hasMore: Bool { page < totalPages }
}
