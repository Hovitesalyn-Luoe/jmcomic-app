import Foundation
import CryptoKit
import Security
import CommonCrypto

/// GitHub 自动同步（收藏 + 历史 + 进度）。
///
/// 设计：
/// - 数据打包成单文件 backup.bin，用「同步密码」PBKDF2 派生密钥 AES-GCM 加密
/// - 仓库里只有密文：私有仓库 + 密码双重保护，密钥不在仓库里
/// - token 存本机钥匙串（配置一次），换机重新配置 token + 输同步密码即可解密
/// - 合并：收藏按 id、进度按 updatedAt 新的赢（两台 Mac 不打架）
/// - git 用系统自带 CLI，零第三方依赖
@MainActor
final class SyncStore: ObservableObject {

    static let shared = SyncStore()

    @Published var repoURL: String = UserDefaults.standard.string(forKey: "syncRepoURL") ?? ""
    @Published var syncing = false
    @Published var lastSync: Date?
    @Published var lastError: String?
    @Published private(set) var tokenConfigured = false

    private let service = "local.jmcomic"
    private var tokenAccount = "github-token"
    private var passwordAccount = "sync-password"

    private init() {
        tokenConfigured = readToken() != nil && !repoURL.isEmpty
    }

    func setRepoURL(_ url: String) {
        repoURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(repoURL, forKey: "syncRepoURL")
        tokenConfigured = readToken() != nil && !repoURL.isEmpty
    }

    // MARK: - 钥匙串凭证

    func setToken(_ token: String) {
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
        tokenConfigured = readToken() != nil && !repoURL.isEmpty
    }

    func setSyncPassword(_ pw: String) {
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecValueData as String: Data(pw.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(add as CFDictionary)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func readToken() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func readSyncPassword() -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 数据打包（收藏 + 历史 + 进度）

    private func syncDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("JMComic/sync", isDirectory: true)
    }

    private var backupFile: URL { syncDir().appendingPathComponent("backup.bin") }

    /// 打包本地数据并加密（同步密码派生密钥）
    private func packAndEncrypt() -> Data? {
        guard let password = readSyncPassword(), !password.isEmpty,
              let fav = FavoriteStore.shared.exportJSON(),
              let state = LibraryStore.shared.exportState(),
              let root = try? JSONSerialization.jsonObject(with: fav) as? [String: Any],
              let stateObj = try? JSONSerialization.jsonObject(with: state) as? [String: Any]
        else { return nil }

        // 组合 {"favorites": ..., "state": ...}（base64 包两层，避免键冲突）
        let payload: [String: Any] = [
            "favorites": fav.base64EncodedString(),
            "state": state.base64EncodedString(),
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload)
        else { return nil }

        // PBKDF2 派生 + AES-GCM（与 CryptoStore 文件格式一致：nonce||密文||tag）
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
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
        let key = SymmetricKey(data: keyData)
        let nonce = AES.GCM.Nonce()
        guard let sealed = try? AES.GCM.seal(payloadData, using: key, nonce: nonce)
        else { return nil }
        var out = Data()
        out.append(salt)
        out.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        out.append(contentsOf: sealed.ciphertext)
        out.append(contentsOf: sealed.tag)
        return out
    }

    /// 解密并合并到本地 stores
    private func decryptAndImport(_ data: Data) -> Bool {
        guard let password = readSyncPassword(), !password.isEmpty,
              data.count > 16 + 12 + 16
        else { return false }
        // 格式：salt(16) || nonce(12) || ciphertext || tag(16)
        // 注意：必须用原 Data 的绝对索引（dropFirst 返回的 SubSequence 索引是绝对偏移，相对下标会越界崩溃）
        let salt = data.prefix(16)
        let nonceData = data[16..<28]
        let ciphertext = data[28..<(data.count - 16)]
        let tag = data.suffix(16)
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
        let key = SymmetricKey(data: keyData)
        guard let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plain = try? AES.GCM.open(box, using: key),
              let obj = try? JSONSerialization.jsonObject(with: plain) as? [String: Any]
        else { return false }

        var ok = false
        if let favB64 = obj["favorites"] as? String,
           let favData = Data(base64Encoded: favB64) {
            let n = FavoriteStore.shared.importJSON(favData)
            ok = ok || n >= 0
        }
        if let stateB64 = obj["state"] as? String,
           let stateData = Data(base64Encoded: stateB64) {
            let n = LibraryStore.shared.importState(stateData)
            ok = ok || n >= 0
        }
        return ok
    }

    // MARK: - Git 同步

    private func git(_ args: [String], in dir: URL? = nil, extraAuth: Bool = false) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var finalArgs = args
        if extraAuth, let token = readToken() {
            finalArgs = ["-c", "http.extraHeader=Authorization: Basic "
                         + Data("x-access-token:\(token)".utf8).base64EncodedString()]
                + finalArgs
        }
        p.arguments = finalArgs
        if let dir { p.currentDirectoryURL = dir }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return false }
        return p.terminationStatus == 0
    }

    /// 完整同步：拉远端 → 合并 → 打包 → 推送。双向合并。
    func sync() async {
        guard !syncing else { return }
        guard !repoURL.isEmpty, let _ = readToken(), let _ = readSyncPassword() else {
            lastError = "请先配置仓库地址、Token 和同步密码"
            return
        }
        syncing = true
        lastError = nil
        defer { syncing = false }

        let dir = syncDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1. 初始化仓库（没有则 clone）
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) {
            // 私有仓库必须带认证头，否则 clone 一定失败（后面 pull/push 都带了 extraAuth，这里原先漏了）
            guard git(["clone", repoURL, dir.path], extraAuth: true) else {
                lastError = "克隆仓库失败：检查仓库地址 / Token 权限（需 repo 权限）"
                return
            }
        }

        // 2. 拉远端（可能拿到别人/别的机器推的 backup.bin）
        _ = git(["pull", "--no-edit"], in: dir, extraAuth: true)

        // 3. 远端数据 → 合并进本地
        if FileManager.default.fileExists(atPath: backupFile.path),
           let data = try? Data(contentsOf: backupFile) {
            _ = decryptAndImport(data)
        }

        // 4. 本地（含合并结果）→ 重新打包
        guard let packed = packAndEncrypt() else {
            lastError = "打包失败：请确认已设置同步密码"
            return
        }
        try? packed.write(to: backupFile, options: .atomic)

        // 5. 提交 + 推送（失败重试一次：远端又变了就再拉再推）
        _ = git(["add", "backup.bin"], in: dir)
        _ = git(["commit", "-m", "sync \(Date())"], in: dir)
        var pushed = git(["push"], in: dir, extraAuth: true)
        if !pushed {
            _ = git(["pull", "--no-edit"], in: dir, extraAuth: true)
            if let data = try? Data(contentsOf: backupFile) { _ = decryptAndImport(data) }
            if let packed = packAndEncrypt() {
                try? packed.write(to: backupFile, options: .atomic)
                _ = git(["add", "backup.bin"], in: dir)
                _ = git(["commit", "-m", "sync retry \(Date())"], in: dir)
                pushed = git(["push"], in: dir, extraAuth: true)
            }
        }
        lastSync = Date()
        lastError = pushed ? nil : "推送失败（网络或远端冲突），本地数据已保存，下次同步重试"
    }
}
