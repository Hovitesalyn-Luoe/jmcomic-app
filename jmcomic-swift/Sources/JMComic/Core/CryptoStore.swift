import Foundation
import CryptoKit
import Security

/// 本地敏感数据的静态加密。
///
/// 威胁模型：以本机用户身份运行的任意进程（流氓 App、中毒后）都能直接读文件，
/// 0600 权限挡不住同权限进程。所以数据落盘前先 AES-GCM 加密，
/// 别人读到的是密文，只有本应用运行时能用钥匙串里的密钥解开。
///
/// 密钥：32 字节随机，首次启动生成，存钥匙串（GenericPassword）。
/// 按签名隔离：dev 裸二进制和正式 .app 签名/路径不同，各自读不到对方的密钥，
/// 所以 dev 加密的数据正式版替换后需要先导出明文再导入（收藏已有导出/导入）。
///
/// 文件格式：`nonce(12) || ciphertext || tag(16)`，一眼就能和明文 JSON 区分。
///
/// 不覆盖的场景（注释里写明，避免误以为万能）：
/// - FileVault 没开时，备份/物理取盘里的密文虽然不可读，但"密码哈希"仍可离线爆破；
///   图片磁盘缓存（ImageStore）也仍是明文 —— 那些量大，加密不值，靠 FileVault。
enum CryptoStore {

    private static let service = "local.jmcomic"
    private static let account = "store-key"
    private static var cachedKey: SymmetricKey?

    /// 取密钥。失败返回 nil（钥匙串不可用等），调用方按"无数据"处理。
    static func key() -> SymmetricKey? {
        if let cachedKey { return cachedKey }
        guard let k = loadOrCreateKey() else { return nil }
        cachedKey = k
        return k
    }

    private static func loadOrCreateKey() -> SymmetricKey? {
        // 本地文件存储（原为钥匙串：ad-hoc 签名每次重编身份都变，会反复弹窗）
        if let data = LocalSecrets.read(service: service, account: account), data.count == 32 {
            return SymmetricKey(data: data)
        }

        var raw = Data(count: 32)
        guard raw.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess
        else { return nil }
        guard LocalSecrets.write(raw, service: service, account: account) else { return nil }
        return SymmetricKey(data: raw)
    }

    static func encrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        var out = Data()
        out.append(contentsOf: nonce.withUnsafeBytes { Data($0) })
        out.append(contentsOf: sealed.ciphertext)
        out.append(contentsOf: sealed.tag)
        return out
    }

    static func decrypt(_ data: Data, key: SymmetricKey) throws -> Data {
        guard data.count > 12 + 16 else { throw CocoaError(.coderReadCorrupt) }
        let nonce = try AES.GCM.Nonce(data: data.prefix(12))
        let box = try AES.GCM.SealedBox(nonce: nonce,
                                        ciphertext: data[12..<(data.count - 16)],
                                        tag: data.suffix(16))
        return try AES.GCM.open(box, using: key)
    }
}
