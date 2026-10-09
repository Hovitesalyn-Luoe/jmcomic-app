import Foundation
import Network
import CryptoKit
import CommonCrypto
import Security

// MARK: - 局域网同步服务（Mac 端）
//
// 给 iPhone 端（jmcomic-ios）提供局域网直连同步：
//   1. POST /pair            一次性配对码 + 设备名 → 换长期会话 token（存 iPhone 钥匙串）
//   2. GET  /metadata/pull   返回加密元数据包（favorites + state 双层 base64）
//   3. POST /metadata/push   接收 iPhone 的加密包并合并进本地 stores
//   4. GET  /downloads/list  已下载专辑清单（albumId/title/files[path,size]）
//   5. GET  /downloads/file?path=相对路径    单文件传输（严格限制在下载根目录内）
//
// 安全三门槛：二维码/配对码 → /pair 换会话 token → Bearer 访问业务端点；
// 加密 payload 与 SyncStore 备份格式同构：salt(16)‖nonce(12)‖ciphertext‖tag(16)，
// PBKDF2-SHA256、210000 轮、32 字节密钥，AES-GCM。
// 会话 token 随机生成（SecRandomCopyBytes）；同一 IP 连续鉴权失败 ≥5 次封禁 10 分钟。

/// 已配对设备记录（持久化在 UserDefaults；会话 token 本体存钥匙串）
struct LanDevice: Codable, Identifiable, Hashable {
    var id: String          // deviceId（UUID）
    var name: String        // 配对时上报的设备名
    var pairedAt: Date
}

/// 下载清单条目（iOS 端按此解析传输进度）
struct LanDownloadFile: Codable, Hashable {
    /// 相对下载根目录的路径，统一用「/」分隔，例如 "本子A/第1话.cbz"
    let path: String
    let size: Int
}

struct LanDownloadAlbum: Codable, Hashable {
    let albumId: String
    let title: String
    let files: [LanDownloadFile]
}

@MainActor
final class LanSyncServer: ObservableObject {

    static let shared = LanSyncServer()

    // MARK: - 常量

    static let bonjourType = "_jmsync._tcp"
    /// 钥匙串 service 名；account = deviceId，value = "<sessionToken>|<配对时所用配对码>"
    static let keychainService = "local.jmcomic-lansync"

    private enum Keys {
        static let enabled = "lanSyncEnabled"
        static let pairCode = "lansyncPairCode"
        static let devices = "lansyncDevices"
    }

    /// 请求头区上限 / body 上限（防恶意大包）
    static let maxHeadBytes = 64 * 1024
    static let maxBodyBytes = 64 * 1024 * 1024
    /// 单连接从建立到响应发出的兜底超时（一请求一连接的模型下足够宽裕）
    static let connectionTimeout: TimeInterval = 30
    /// 同 IP 连续鉴权失败阈值与封禁时长
    static let banThreshold = 5
    static let banSeconds: TimeInterval = 600

    // MARK: - 发布状态（设置页绑定）

    @Published var enabled: Bool = UserDefaults.standard.bool(forKey: Keys.enabled) {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled { beginListening() } else { stopListening() }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var lastError: String?

    /// 当前配对码（8 位易读串）。重新生成后旧码立即失效，但已配对设备不受影响——
    /// 其加密密钥用的是配对那一刻的配对码（已随 token 一并存进钥匙串）。
    @Published private(set) var pairCode: String

    @Published private(set) var devices: [LanDevice]

    // MARK: - 内部状态

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.jmcomic-lansync.server")
    private struct Rate { var fails = 0; var blockedUntil: Date? }
    private var rates: [String: Rate] = [:]
    /// deviceId → (sessionToken, 配对时配对码) 内存缓存，避免每次请求都查钥匙串
    private var tokenCache: [String: (token: String, code: String)] = [:]
    private let defaults: UserDefaults
    /// 下载根目录提供者（自检注入临时目录，避免碰用户真实数据）；仅主线程访问
    let downloadsRootProvider: () -> URL
    private var downloadsRootCache: URL?

    // MARK: - 初始化（shared 用默认参数；SelfCheck 注入独立 defaults + 临时目录）

    init(defaults: UserDefaults = .standard,
         downloadsRoot: URL? = nil,
         keychainServiceOverride: String? = nil) {
        self.defaults = defaults
        self._keychainService = keychainServiceOverride ?? Self.keychainService
        self.downloadsRootProvider = { downloadsRoot ?? DownloadStore.shared.root }

        if let raw = defaults.string(forKey: Keys.pairCode), Self.isValidPairCode(raw) {
            pairCode = raw
        } else {
            let fresh = Self.generatePairCode()
            pairCode = fresh
            defaults.set(fresh, forKey: Keys.pairCode)
        }
        if let data = defaults.data(forKey: Keys.devices),
           let list = try? JSONDecoder().decode([LanDevice].self, from: data) {
            devices = list
        } else {
            devices = []
        }
    }

    /// 自检用钥匙串隔离后缀（不设则用正式 service）
    private let _keychainService: String

    var downloadsRoot: URL {
        if let c = downloadsRootCache { return c }
        let r = downloadsRootProvider()
        downloadsRootCache = r
        return r
    }

    // MARK: - 对外信息（设置页展示）

    /// 本机局域网 IPv4（优先 en0），取不到返回 nil
    static func primaryIPv4() -> String? {
        var candidates: [(name: String, ip: String)] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return nil }
        defer { freeifaddrs(ifaddrPtr) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cursor {
            defer { cursor = p.pointee.ifa_next }
            guard let sa = p.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                                nil, 0, NI_NUMERICHOST)
            guard r == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("127.") else { continue }
            var name = String(cString: p.pointee.ifa_name)
            if let pct = name.firstIndex(of: "%") { name = String(name[..<pct]) }
            candidates.append((name, ip))
        }
        // 有线/无线物理网卡优先，虚拟接口（bridge/utun 等）垫底
        let rank: (String) -> Int = { n in
            if n.hasPrefix("en") { return 0 }
            if n.hasPrefix("ether") { return 1 }
            return 2
        }
        return candidates.sorted {
            rank($0.name) != rank($1.name) ? rank($0.name) < rank($1.name) : $0.name < $1.name
        }.first?.ip
    }

    /// 二维码自包含配置串（iOS 端按此精确格式解析）：
    ///
    ///     jmsync|v1|<ip>|<port>|<pairCode>
    ///
    /// 字段以竖线分隔，共 5 段；v1 为协议版本；pairCode 即当前 8 位配对码，
    /// 同时它也是元数据包的 PBKDF2 派生密码原文。
    func qrConfigString() -> String? {
        guard let ip = Self.primaryIPv4(), let port = listeningPort else { return nil }
        return "jmsync|v1|\(ip)|\(port)|\(pairCode)"
    }

    var addressText: String? {
        guard let ip = Self.primaryIPv4(), let port = listeningPort else { return nil }
        return "\(ip):\(port)"
    }

    // MARK: - 生命周期

    /// App 启动时恢复持久化开关（不开设置页也能继续服务 iPhone 连接）
    func applyStartupState() {
        if enabled { beginListening() }
    }

    /// 启动监听。loopbackOnly 仅限自检：只绑 127.0.0.1，绝不对外广播。
    func beginListening(loopbackOnly: Bool = false) {
        guard listener == nil else { return }
        lastError = nil
        let params = NWParameters.tcp
        if loopbackOnly {
            // 随机端口绑回环地址（仅自检可达）
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        }
        guard let l = try? NWListener(using: params) else {
            lastError = "无法创建监听器"; return
        }
        if !loopbackOnly {
            let hostName = ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init)
            l.service = NWListener.Service(name: (hostName ?? "JMComic"),
                                           type: Self.bonjourType)
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            Task { @MainActor in
                switch state {
                case .ready:
                    self.listeningPort = l.port.flatMap { UInt16($0.rawValue) }
                    self.running = true
                    self.lastError = nil
                case .failed(let err):
                    self.lastError = "监听失败：\(err)"
                    self.running = false
                    self.listeningPort = nil
                case .cancelled:
                    self.running = false
                    self.listeningPort = nil
                default:
                    break
                }
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in self.accept(conn) }
        }
        listener = l
        l.start(queue: queue)
    }

    /// 关停：取消 NWListener 并随之注销 Bonjour 广播，端口立即不可达。
    func stopListening() {
        listener?.cancel()
        listener = nil
        running = false
        listeningPort = nil
    }

    /// 自检专用关停：额外清理测试实例产生的本地凭证与 UserDefaults suite，零残留。
    func shutdownForTests(suiteName: String?) {
        for d in devices {
            LocalSecrets.delete(service: _keychainService, account: d.id)
        }
        stopListening()
        devices = []
        saveDevices()
        if let s = suiteName { defaults.removePersistentDomain(forName: s) }
    }

    // MARK: - 配对码

    /// 易读字符表：去掉 I/L/O、0/1 等易混淆字符，共 31 个（8 位 ≈ 40 bit 强度）
    static let pairAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func generatePairCode() -> String {
        // SecRandomCopyBytes + 拒绝采样（248 = 31 × 8）保证每个字符均匀分布
        let alphabet = pairAlphabet
        precondition(alphabet.count == 31)
        var code = ""
        while code.count < 8 {
            var b: UInt8 = 0
            _ = SecRandomCopyBytes(kSecRandomDefault, 1, &b)
            guard b < 248 else { continue }
            code.append(alphabet[Int(b % 31)])
        }
        return code
    }

    static func isValidPairCode(_ s: String) -> Bool {
        s.count == 8 && s.allSatisfy { pairAlphabet.contains($0) }
    }

    /// 重新生成配对码：旧码立即作废（未换 session 的扫码流程失败），已配对设备不受影响
    func regeneratePairCode() {
        pairCode = Self.generatePairCode()
        defaults.set(pairCode, forKey: Keys.pairCode)
    }

    // MARK: - 设备管理

    func revoke(_ deviceID: String) {
        LocalSecrets.delete(service: _keychainService, account: deviceID)
        tokenCache.removeValue(forKey: deviceID)
        devices.removeAll { $0.id == deviceID }
        saveDevices()
    }

    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) {
            defaults.set(data, forKey: Keys.devices)
        }
    }

    // MARK: - HTTP 基础类型与解析（纯函数，无副作用，供自检直测）

    struct HTTPRequest {
        var method: String
        var path: String                 // 不含 query
        var query: [String: String]
        var headers: [String: String]    // key 全小写
        var body: Data

        var bearerToken: String? {
            guard let v = headers["authorization"] else { return nil }
            guard v.hasPrefix("Bearer ") else { return nil }
            let tok = String(v.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
            return tok.isEmpty ? nil : tok
        }
    }

    struct HTTPResponse {
        var status: Int
        var extraHeaders: [(String, String)]
        var body: Data

        static func json(_ status: Int, _ obj: [String: Any]) -> HTTPResponse {
            let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            return HTTPResponse(status: status,
                                extraHeaders: [("Content-Type", "application/json; charset=utf-8"),
                                               ("Cache-Control", "no-store")],
                                body: data)
        }

        static func binary(_ status: Int, contentType: String, _ data: Data) -> HTTPResponse {
            HTTPResponse(status: status,
                         extraHeaders: [("Content-Type", contentType),
                                        ("Cache-Control", "no-store")],
                         body: data)
        }

        func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
            for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            var out = Data(head.utf8)
            out.append(body)
            return out
        }

        static func statusText(_ code: Int) -> String {
            switch code {
            case 200: return "OK"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 413: return "Payload Too Large"
            case 500: return "Internal Server Error"
            default:  return "Status \(code)"
            }
        }
    }

    enum ParsedRequest {
        case complete(HTTPRequest)
        case needMore
        case invalid
    }

    private static let crlfcrlf = Data([0x0D, 0x0A, 0x0D, 0x0A])

    /// 手写最小 HTTP/1.1 解析：请求行 + headers + Content-Length 定长 body。
    /// 不支持 chunked（客户端都用定长发送），数据不全时返回 needMore 由调用方继续收包。
    static func parseRequest(_ data: Data) -> ParsedRequest {
        guard let headRange = data.firstRange(of: crlfcrlf) else {
            return data.count > maxHeadBytes ? .invalid : .needMore
        }
        let headLen = headRange.lowerBound - data.startIndex
        guard headLen <= maxHeadBytes else { return .invalid }
        let headText = String(decoding: data.prefix(headLen), as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return .invalid }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/") else { return .invalid }
        let method = parts[0].uppercased()
        guard method == "GET" || method == "POST" else { return .invalid }
        guard let (path, query) = splitTarget(parts[1]) else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = line[..<idx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        var contentLength = 0
        if let clStr = headers["content-length"] {
            guard let cl = Int(clStr), cl >= 0, cl <= maxBodyBytes else { return .invalid }
            contentLength = cl
        }
        let available = data.count - headLen - crlfcrlf.count
        guard available >= 0 else { return .invalid }
        if available < contentLength { return .needMore }
        let body = data.subdata(in: (headLen + crlfcrlf.count)..<(headLen + crlfcrlf.count + contentLength))
        return .complete(HTTPRequest(method: method, path: path, query: query,
                                     headers: headers, body: body))
    }

    /// target = "/downloads/file?path=a%2Fb.cbz" → ("/downloads/file", ["path": "a/b.cbz"])
    static func splitTarget(_ target: String) -> (String, [String: String])? {
        guard let qIdx = target.firstIndex(of: "?") else {
            return (percentDecode(target) ?? target, [:])
        }
        let rawPath = String(target[..<qIdx])
        let qs = String(target[target.index(after: qIdx)...])
        var query: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard kv.count == 2 else { continue }
            query[percentDecode(String(kv[0])) ?? String(kv[0])]
                = percentDecode(String(kv[1])) ?? String(kv[1])
        }
        guard let p = percentDecode(rawPath) else { return nil }
        return (p, query)
    }

    static func percentDecode(_ s: String) -> String? {
        s.removingPercentEncoding
    }

    /// 路径越权防护核心：拒绝 ".."/"." 组件与符号链接逃逸，
    /// canonical 化后必须仍落在下载根目录之内，且必须是存在的普通文件。
    static func resolveSafeDownloadPath(root: URL, relative: String) -> URL? {
        let cleaned = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("\0") else { return nil }
        let comps = cleaned.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !comps.isEmpty else { return nil }
        for c in comps where c == ".." || c == "." { return nil }
        let candidate = root.appendingPathComponent(comps.joined(separator: "/"))
        let rootReal = root.resolvingSymlinksInPath().path
        let candReal = candidate.resolvingSymlinksInPath().path
        guard candReal == rootReal || candReal.hasPrefix(rootReal + "/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candReal, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        return URL(fileURLWithPath: candReal)
    }

    // MARK: - 元数据打包 / 解包（与 SyncStore 完全同构；static 供 iOS 同构实现与自检）

    /// PBKDF2-SHA256，210000 轮，salt 与 SyncStore 相同长度（16B），输出 32B AES-256 密钥
    static func deriveKey(password: String, salt: Data) -> SymmetricKey {
        var keyData = Data(count: 32)
        let pw = Array(password.utf8)
        _ = keyData.withUnsafeMutableBytes { outBuf in
            salt.withUnsafeBytes { saltBuf in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pw, pw.count,
                                     saltBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                     210_000,
                                     outBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     32)
            }
        }
        return SymmetricKey(data: keyData)
    }

    /// 打包 {"favorites":b64,"state":b64} 外层再 PBKDF2+AES-GCM：
    /// 输出 salt(16)‖nonce(12)‖ciphertext‖tag(16)
    static func sealPayload(favorites: Data, state: Data, password: String) -> Data? {
        let payload: [String: Any] = [
            "favorites": favorites.base64EncodedString(),
            "state": state.base64EncodedString(),
        ]
        guard let plain = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = deriveKey(password: password, salt: salt)
        let sealed = try? AES.GCM.seal(plain, using: key)
        guard let sealed else { return nil }
        var out = salt
        out.append(contentsOf: sealed.nonce.withUnsafeBytes { Data($0) })
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    /// 解包 sealPayload 的产物。密码错误/密文被篡改/结构不对一律 nil。
    static func openPayload(_ data: Data, password: String) -> (favorites: Data, state: Data)? {
        // 格式：salt(16) || nonce(12) || ciphertext || tag(16)，用绝对索引切片防越界
        guard data.count > 16 + 12 + 16 else { return nil }
        let salt = data.prefix(16)
        let nonceData = data[16..<28]
        let ciphertext = data[28..<(data.count - 16)]
        let tag = data.suffix(16)
        let key = deriveKey(password: password, salt: salt)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: key),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any],
              let favB64 = obj["favorites"] as? String,
              let stB64 = obj["state"] as? String,
              let fav = Data(base64Encoded: favB64),
              let st = Data(base64Encoded: stB64)
        else { return nil }
        return (fav, st)
    }

    // MARK: - 钥匙串（每设备一条：<sessionToken>|<配对时配对码>）

    private func chainRecord(for deviceID: String) -> (token: String, code: String)? {
        if let hit = tokenCache[deviceID] { return hit }
        guard let data = LocalSecrets.read(service: _keychainService, account: deviceID),
                let raw = String(data: data, encoding: .utf8) else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let rec = (token: String(parts[0]), code: String(parts[1]))
        tokenCache[deviceID] = rec
        return rec
    }

    private static func randomHexString(_ byteCount: Int) -> String {
        var d = Data(count: byteCount)
        _ = d.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, byteCount, $0.baseAddress!)
        }
        return d.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 连接接收与读取循环

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        // 兜底超时：挂起不发完整请求的连接直接掐断
        let deadline = DispatchWorkItem { conn.cancel() }
        queue.asyncAfter(deadline: .now() + Self.connectionTimeout, execute: deadline)

        Task { @MainActor in
            var buffer = Data()
            while true {
                guard let chunk = await self.recv(conn) else {
                    deadline.cancel(); conn.cancel(); return
                }
                buffer.append(chunk)
                switch Self.parseRequest(buffer) {
                case .complete(let req):
                    deadline.cancel()
                    let ip = Self.remoteIPDescription(of: conn.endpoint)
                    let resp = await self.route(req, ip: ip)
                    self.deliver(resp, on: conn)
                    return
                case .invalid:
                    deadline.cancel()
                    self.deliver(.json(400, ["error": "bad request"]), on: conn)
                    return
                case .needMore:
                    if buffer.count > Self.maxHeadBytes + Self.maxBodyBytes {
                        deadline.cancel()
                        self.deliver(.json(413, ["error": "payload too large"]), on: conn)
                        return
                    }
                }
            }
        }
    }

    /// Network.framework 回调线程收包，桥接成 async（buffer 只在 MainActor 上拼接）
    private func recv(_ conn: NWConnection) async -> Data? {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if error != nil { cont.resume(returning: nil); return }
                if isComplete && data == nil { cont.resume(returning: nil); return }
                cont.resume(returning: data ?? Data())
            }
        }
    }

    private func deliver(_ resp: HTTPResponse, on conn: NWConnection) {
        let wire = resp.serialized()
        conn.send(content: wire, completion: .contentProcessed { _ in
            conn.cancel()   // 一请求一连接：发出即关
        })
    }

    static func remoteIPDescription(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            let text = "\(host)"
            if let pct = text.firstIndex(of: "%") { return String(text[..<pct]) }
            return text
        }
        return "unknown"
    }

    // MARK: - 限流封禁

    private func registerFailure(_ ip: String) {
        var r = rates[ip] ?? Rate()
        r.fails += 1
        if r.fails >= Self.banThreshold {
            r.blockedUntil = Date(timeIntervalSinceNow: Self.banSeconds)
        }
        rates[ip] = r
    }

    private func clearFailures(_ ip: String) {
        rates[ip]?.fails = 0
    }

    private func isBanned(_ ip: String) -> Bool {
        guard let until = rates[ip]?.blockedUntil else { return false }
        if until <= Date() { rates[ip]?.blockedUntil = nil; return false }
        return true
    }

    // MARK: - 路由

    private func route(_ req: HTTPRequest, ip: String) async -> HTTPResponse {
        // 封禁期内的 IP：所有端点（含 /pair）一律拒绝
        if isBanned(ip) {
            return .json(403, ["error": "连续失败过多，请稍后再试"])
        }

        if req.path == "/pair" {
            return req.method == "POST" ? respondPair(req, ip: ip)
                                        : .json(405, ["error": "method not allowed"])
        }

        // 业务端点全部要会话
        guard let token = req.bearerToken,
              let device = devices.first(where: { chainRecord(for: $0.id)?.token == token }),
              let record = chainRecord(for: device.id)
        else {
            registerFailure(ip)
            return .json(401, ["error": "无效会话"])
        }
        clearFailures(ip)

        switch (req.method, req.path) {
        case ("GET", "/metadata/pull"):
            return respondPull(pairCodeAtPairing: record.code)
        case ("POST", "/metadata/push"):
            return respondPush(req, pairCodeAtPairing: record.code)
        case ("GET", "/downloads/list"):
            return await respondDownloadsList()
        case ("GET", "/downloads/file"):
            return await respondDownloadFile(queryPath: req.query["path"] ?? "")
        default:
            if req.path.hasPrefix("/metadata") || req.path.hasPrefix("/downloads") {
                return .json(405, ["error": "method not allowed"])
            }
            return .json(404, ["error": "not found"])
        }
    }

    // MARK: - POST /pair

    private func respondPair(_ req: HTTPRequest, ip: String) -> HTTPResponse {
        // header X-Pair-Token 必须等于当前有效配对码
        guard req.headers["x-pair-token"] == pairCode else {
            registerFailure(ip)
            return .json(401, ["error": "配对码无效"])
        }
        let obj = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
        var name = (obj?["deviceName"] as? String) ?? ""
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.count > 40 { name = String(name.prefix(40)) }
        if name.isEmpty { name = "iPhone" }

        let sessionToken = Self.randomHexString(32)
        let deviceId = UUID().uuidString
        // 钥匙串一条记齐两样：会话 token + 配对时刻的配对码（后者是 pull/push 的派生密码）
        let stored = "\(sessionToken)|\(pairCode)"
        guard LocalSecrets.write(string: stored, service: _keychainService, account: deviceId) else {
                return .json(500, ["error": "本地凭证写入失败"])
            }
        tokenCache[deviceId] = (sessionToken, pairCode)
        devices.append(LanDevice(id: deviceId, name: name, pairedAt: Date()))
        saveDevices()
        clearFailures(ip)
        return .json(200, ["sessionToken": sessionToken, "deviceId": deviceId])
    }

    // MARK: - GET /metadata/pull

    private func respondPull(pairCodeAtPairing code: String) -> HTTPResponse {
        // 导出即备份：两个导出函数都是只读，零副作用
        let fav = FavoriteStore.shared.exportJSON() ?? Data("{\"entries\":[],\"folders\":[]}".utf8)
        let state = LibraryStore.shared.exportState() ?? Data("{\"positions\":{},\"history\":[]}".utf8)
        guard let sealed = Self.sealPayload(favorites: fav, state: state, password: code) else {
            return .json(500, ["error": "打包失败"])
        }
        return .binary(200, contentType: "application/octet-stream", sealed)
    }

    // MARK: - POST /metadata/push

    private func respondPush(_ req: HTTPRequest, pairCodeAtPairing code: String) -> HTTPResponse {
        guard let payload = Self.openPayload(req.body, password: code) else {
            return .json(400, ["error": "解密失败或数据格式错误"])
        }
        // 合并语义见 FavoriteStore.importJSON（按 id 去重、保留本地分组）
        // 与 LibraryStore.importState（进度 updatedAt 新者赢、历史按 id 并集）
        let favResult = FavoriteStore.shared.importJSON(payload.favorites)
        let stateResult = LibraryStore.shared.importState(payload.state)
        guard favResult >= 0 && stateResult >= 0 else {
            return .json(400, ["error": "数据格式无法解析"])
        }
        return .json(200, ["ok": true])
    }

    // MARK: - GET /downloads/list

    /// 扫描下载根目录：一级子目录=一本专辑，其内所有常规文件进入 files 清单。
    /// relative 路径统一「/」分隔；纯文件系统扫描，不依赖索引状态（导入的本子也能传）。
    nonisolated static func scanDownloads(root: URL) -> [LanDownloadAlbum] {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        let trimmedRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        guard let tops = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        var albums: [LanDownloadAlbum] = []
        for dir in tops {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let walker = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { continue }
            var files: [LanDownloadFile] = []
            for case let url as URL in walker {
                guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      vals.isRegularFile == true else { continue }
                // 半成品归档不进清单
                if url.lastPathComponent.hasSuffix(".part") { continue }
                let abs = url.standardizedFileURL.path
                var rel = abs.hasPrefix(trimmedRoot + "/") ? String(abs.dropFirst(trimmedRoot.count + 1)) : abs
                rel = rel.replacingOccurrences(of: "\\", with: "/")
                let size = vals.fileSize.flatMap(Int.init) ?? 0
                files.append(LanDownloadFile(path: rel, size: size))
            }
            guard !files.isEmpty else { continue }
            files.sort { $0.path < $1.path }
            albums.append(LanDownloadAlbum(albumId: DownloadStore.fallbackID(dir.path),
                                           title: dir.lastPathComponent,
                                           files: files))
        }
        return albums.sorted { $0.title < $1.title }
    }

    private func respondDownloadsList() async -> HTTPResponse {
        let root = downloadsRoot
        let albums = await Task.detached(priority: .utility) {
            Self.scanDownloads(root: root)
        }.value
        guard let data = try? JSONEncoder().encode(albums) else {
            return .json(500, ["error": "清单编码失败"])
        }
        return .binary(200, contentType: "application/json", data)
    }

    // MARK: - GET /downloads/file

    private func respondDownloadFile(queryPath: String) async -> HTTPResponse {
        guard !queryPath.isEmpty,
              let url = Self.resolveSafeDownloadPath(root: downloadsRoot, relative: queryPath)
        else {
            return .json(403, ["error": "路径被拒绝"])
        }
        // 大文件读盘放后台线程，别卡主线程
        let readUrl = url
        let data = await Task.detached(priority: .utility) { try? Data(contentsOf: readUrl) }.value
        guard let data else { return .json(404, ["error": "文件不存在"]) }
        return .binary(200, contentType: "application/octet-stream", data)
    }
}
