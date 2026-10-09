import SwiftUI

/// 检查更新：读本仓库最新 Release，和当前构建的发布标记比对。
///
/// - 设置页的「检查更新」和启动时的自动检查共用这一份逻辑；
/// - 先按系统代理请求，失败再直连试一次：
///   实测有些代理规则会把 api.github.com 走到不可用的线路，直连反而通；
/// - 启动自动检查由设置里的开关控制（默认开）。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repo = "Hovitesalyn-Luoe/jmcomic-app"
    /// 启动自动检查开关（默认开）
    static let autoCheckKey = "autoCheckUpdatesOnLaunch"

    enum State {
        case idle
        case checking
        case latest(String)
        case newer(String, String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 启动检查发现新版本时置上，界面据此弹窗；用户关掉后清空
    @Published var pendingTag: String?
    private var pendingPage: String?
    private var didLaunchCheck = false

    var currentTag: String {
        (Bundle.main.object(forInfoDictionaryKey: "JMReleaseTag") as? String) ?? "开发版"
    }

    static var autoCheckEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCheckKey) as? Bool ?? true
    }

    // MARK: - 对外

    func check() {
        state = .checking
        Task {
            do {
                let (tag, page) = try await Self.fetchLatestRelease()
                if Self.isNewer(tag, than: currentTag) {
                    state = .newer(tag, page)
                } else {
                    state = .latest(tag)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// 启动时检查一次（受开关控制，且每次运行只做一次）
    func checkOnLaunch() {
        guard !didLaunchCheck else { return }
        didLaunchCheck = true
        guard Self.autoCheckEnabled else { return }
        Task {
            do {
                let (tag, page) = try await Self.fetchLatestRelease()
                if Self.isNewer(tag, than: currentTag) {
                    pendingTag = tag
                    pendingPage = page
                    state = .newer(tag, page)
                } else {
                    state = .latest(tag)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func openPending() {
        defer { dismiss() }
        guard let pendingPage, let url = URL(string: pendingPage) else { return }
        NSWorkspace.shared.open(url)
    }

    func openReleasePage(_ page: String) {
        guard let url = URL(string: page) else { return }
        NSWorkspace.shared.open(url)
    }

    func dismiss() {
        pendingTag = nil
        pendingPage = nil
    }

    // MARK: - 实现

    private static func fetchLatestRelease() async throws -> (tag: String, page: String) {
        var lastError: Error = URLError(.unknown)
        for useProxy in [true, false] {
            do {
                return try await fetchLatestRelease(useProxy: useProxy)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func fetchLatestRelease(useProxy: Bool) async throws -> (tag: String, page: String) {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }
        let config = URLSessionConfiguration.ephemeral
        if !useProxy { config.connectionProxyDictionary = [:] }   // 空字典 = 本次不走代理
        let session = URLSession(configuration: config)
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw URLError(.badServerResponse) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let tag = (obj?["tag_name"] as? String) ?? ""
        let page = (obj?["html_url"] as? String) ?? ""
        guard !tag.isEmpty else { throw URLError(.cannotParseResponse) }
        return (tag, page)
    }

    /// 从 tag 里取构建序号（v1.2.0-fix3 → 3）；取不到返回 nil
    private static func buildNumber(of tag: String) -> Int? {
        guard let r = tag.range(of: "fix", options: .backwards) else { return nil }
        let digits = tag[r.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// 线上版本是否比当前新（按构建序号比；取不到序号就退化为"不相等"）
    static func isNewer(_ latest: String, than current: String) -> Bool {
        if let a = buildNumber(of: latest), let b = buildNumber(of: current) { return a > b }
        return latest != current
    }
}
