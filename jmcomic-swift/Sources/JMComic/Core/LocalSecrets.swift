import Foundation

/// 本地文件版凭证存储（替代钥匙串）。
///
/// 为什么不用钥匙串：本 App 只有 ad-hoc 签名，每重新构建一次，代码签名身份
/// （cdhash）就会变化，钥匙串条目 ACL 里记录的是旧身份，于是每次重编后系统都会
/// 弹出"想要使用钥匙串中的机密信息"。即使用户点了"始终允许"，下一次重编又会再弹。
///
/// 这里改为存到应用自己的支持目录（权限 0600，仅当前用户可读）。
/// 注意：同步数据本身在写入仓库前已用"同步密码"做 AES-GCM 加密，
/// 因此仓库里始终只有密文；本文件保存的是访问仓库所需的 Token 与解密口令。
enum LocalSecrets {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("JMComic/secrets", isDirectory: true)
    }

    /// service/account 拼成安全的文件名
    private static func fileURL(service: String, account: String) -> URL {
        let raw = service + "__" + account
        let safe = raw.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == ".") ? ch : "_"
        }
        return directory.appendingPathComponent(String(safe))
    }

    static func read(service: String, account: String) -> Data? {
        try? Data(contentsOf: fileURL(service: service, account: account))
    }

    @discardableResult
    static func write(_ data: Data, service: String, account: String) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let url = fileURL(service: service, account: account)
            try data.write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    static func write(string: String, service: String, account: String) -> Bool {
        write(Data(string.utf8), service: service, account: account)
    }

    static func delete(service: String, account: String) {
        try? FileManager.default.removeItem(at: fileURL(service: service, account: account))
    }
}
