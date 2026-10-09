import Foundation

enum JmError: LocalizedError {
    case noDomain
    case badResponse(Int)
    case decryptFailed
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDomain: return "没有可用域名，请检查网络或代理设置"
        case .badResponse(let code): return "服务器返回 HTTP \(code)"
        case .decryptFailed: return "响应解密失败"
        case .parseFailed(let what): return "解析失败：\(what)"
        }
    }
}

/// 禁漫移动端 API 客户端。
///
/// 与 Java 版的差异：这里不用「占位域名 + 拦截器改写」那套，
/// 直接在发请求时挑当前最优域名，失败就换下一个。行为等价但少一层间接。
actor JmClient {

    private let session: URLSession
    private var domains: [String] = JmConstants.fallbackDomains
    private var failures: [String: Int] = [:]
    private var didBootstrap = false
    /// 缓存排序后的域名列表，仅在 failures 变化时重新计算
    private var _cachedOrderedDomains: [String]?
    private var _failuresVersion = 0
    private var _lastFailuresMutation = 0

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["user-agent": JmConstants.userAgent]
        /*
         * 关掉 URLSession 自带的磁盘缓存。
         * 它会在 Caches 下另建 Cache.db，把每张封面/页面的完整 URL（含本子 ID）
         * 明文记下来，而且 ImageStore.clearDisk() 根本清不到，等于绕过「清除本地数据」。
         * 图片缓存由 ImageStore 统一管，这里只要不留第二份。
         */
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Cookie 同理：本应用不需要会话态，留着只是多一处可追溯痕迹
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: config)
    }

    // MARK: - 域名

    /// 从域名服务器拉取最新可用域名。只做一次。
    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        for server in JmConstants.domainServers {
            guard let url = URL(string: server) else { continue }
            do {
                let (data, _) = try await session.data(from: url)
                guard let body = String(data: data, encoding: .utf8) else { continue }
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let plain = JmCrypto.decrypt(base64: trimmed, timestamp: "",
                                                   secret: JmConstants.domainServerSecret),
                      let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
                else { continue }
                // 服务端字段为 Server / Setting，取并集
                let list = ((obj["Server"] as? [String]) ?? []) + ((obj["Setting"] as? [String]) ?? [])
                let unique = Array(NSOrderedSet(array: list)) as? [String] ?? []
                if !unique.isEmpty {
                    domains = unique
                    failures.removeAll()
                    return
                }
            } catch {
                continue
            }
        }
    }

    /// 失败次数最少的域名优先（缓存排序结果，仅在 failures 变化时重算）
    private var orderedDomains: [String] {
        if let cached = _cachedOrderedDomains, _failuresVersion == _lastFailuresMutation {
            return cached
        }
        let sorted = domains.sorted { (failures[$0] ?? 0) < (failures[$1] ?? 0) }
        _cachedOrderedDomains = sorted
        _lastFailuresMutation = _failuresVersion
        return sorted
    }

    // MARK: - 请求

    /// 发一个签名 GET，返回解密后的 JSON 对象。逐个域名重试。
    private func getJSON(path: String, query: [URLQueryItem] = [],
                         secret: String = JmConstants.tokenSecret) async throws -> [String: Any] {
        try await bootstrap()
        var lastError: Error = JmError.noDomain

        for host in orderedDomains {
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = host
            comps.path = "/" + path
            comps.queryItems = query.isEmpty ? nil : query
            guard let url = comps.url else { continue }

            let ts = String(Int(Date().timeIntervalSince1970))
            let t = JmCrypto.token(timestamp: ts, secret: secret, appVersion: JmConstants.appVersion)
            var req = URLRequest(url: url)
            req.setValue(t.token, forHTTPHeaderField: "token")
            req.setValue(t.param, forHTTPHeaderField: "tokenparam")

            do {
                let (data, response) = try await session.data(for: req)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = JmError.badResponse(code)
                    continue
                }
                guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let encoded = envelope["data"] as? String else {
                    failures[host, default: 0] += 1
                    _failuresVersion += 1
                    lastError = JmError.parseFailed("响应结构异常")
                    continue
                }
                guard let plain = JmCrypto.decrypt(base64: encoded, timestamp: ts,
                                                   secret: JmConstants.dataSecret),
                      let obj = try? JSONSerialization.jsonObject(with: plain) else {
                    lastError = JmError.decryptFailed
                    continue
                }
                failures[host] = 0
                _failuresVersion += 1
                if let dict = obj as? [String: Any] { return dict }
                if let arr = obj as? [Any] { return ["list": arr] }
                throw JmError.parseFailed("未知的 JSON 结构")
            } catch {
                failures[host, default: 0] += 1
                _failuresVersion += 1
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// 下载原始字节（图片、封面）。不签名、不解密。
    func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw JmError.badResponse(code) }
        return data
    }

    func coverURL(albumId: String) async -> URL? {
        await bootstrap()
        guard let host = orderedDomains.first else { return nil }
        return URL(string: "https://\(host)/media/albums/\(albumId)_3x4.jpg")
    }

    // MARK: - 业务接口

    func hot(page: Int) async throws -> PagedAlbums {
        // 原来的取法是"空关键词 search + o=mv,t=w"。JM 已把它作废：
        // 现在恒定返回 {"total":0,"content":[]}（服务器原话），于是热门页永远"没有结果"。
        // 改用分类筛选接口的总列表并按"最多观看"排序，语义与原来的热门一致。
        let json = try await getJSON(path: "categories/filter", query: [
            .init(name: "page", value: String(page)),
            .init(name: "o", value: "mv"),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func latest(page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "latest", query: [
            .init(name: "page", value: String(page)),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func search(_ text: String, page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "search", query: [
            .init(name: "main_tag", value: "0"),
            .init(name: "search_query", value: text),
            .init(name: "page", value: String(page)),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    /// 热门标签（服务端真实数据；纯数组/{"list":[...]} 两种格式都被归一化）
    func hotTags() async throws -> [String] {
        let json = try await getJSON(path: "hot_tags")
        guard let list = json["list"] as? [Any] else { return [] }
        return list.compactMap { $0 as? String }
    }

    /// 分类筛选：c 为大类 slug（doujin/single/short/hanman/meiman/cosplay/3D 等），
    /// o 为排序（mv=最多观看）。与 Java 版 getCategories 对齐。
    func categories(_ category: String, order: String = "mv", page: Int) async throws -> PagedAlbums {
        let json = try await getJSON(path: "categories/filter", query: [
            .init(name: "page", value: String(page)),
            .init(name: "order", value: ""),
            .init(name: "c", value: category),
            .init(name: "o", value: order),
        ])
        return JmParser.parsePaged(json, page: page)
    }

    func album(id: String) async throws -> Album {
        let json = try await getJSON(path: "album", query: [
            .init(name: "comicName", value: ""),
            .init(name: "id", value: id),
        ])
        return try JmParser.parseAlbum(json, fallbackId: id)
    }

    private var chapterCache: [String: Chapter] = [:]
    private var chapterCacheOrder: [String] = []
    private let chapterCacheLimit = 50

    func chapter(id: String, sort: Int, title: String) async throws -> Chapter {
        if let cached = chapterCache[id] { return cached }
        let json = try await getJSON(path: "chapter", query: [
            .init(name: "id", value: id),
        ])
        let chapter = try JmParser.parseChapter(json, id: id, sort: sort, title: title)
        chapterCache[id] = chapter
        chapterCacheOrder.append(id)
        // LRU 淘汰
        while chapterCacheOrder.count > chapterCacheLimit {
            let oldest = chapterCacheOrder.removeFirst()
            chapterCache.removeValue(forKey: oldest)
        }
        return chapter
    }

    /// 章节列表可能很长，不要让它们占住内存不放；也顺带清掉缓存中的过期条目
    func clearChapterCache() {
        chapterCache.removeAll()
        chapterCacheOrder.removeAll()
    }
}
