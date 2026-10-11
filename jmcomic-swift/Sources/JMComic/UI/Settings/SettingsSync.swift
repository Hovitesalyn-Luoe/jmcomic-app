import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - GitHub 同步

    var githubSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub 同步").font(.headline)
            Text("收藏 + 历史 + 进度加密存私有仓库，换机/多机自动同步。")
                .font(.caption2).foregroundStyle(.secondary)

            TextField("仓库地址（https://github.com/你/仓库.git）", text: $syncRepoURL)
                .font(.caption)
            SecureField("GitHub Token（存本机钥匙串）", text: $syncToken)
                .font(.caption)
            SecureField("同步密码（加密密钥，存钥匙串）", text: $syncPassword)
                .font(.caption)

            HStack(spacing: 10) {
                Button("保存配置") { saveSyncConfig() }
                    .buttonStyle(.bordered).font(.caption)
                Button("从 gh 导入 Token") { importTokenFromGH() }
                    .buttonStyle(.bordered).font(.caption)
                Button(syncStore.syncing ? "同步中…" : "立即同步") {
                    Task { await syncStore.sync() }
                }
                .buttonStyle(.bordered).font(.caption)
                .disabled(syncStore.syncing)
                Spacer()
                if let last = syncStore.lastSync {
                    Text("上次同步：\(Self.relativeTime(last))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let err = syncStore.lastError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    func saveSyncConfig() {
        syncStore.setRepoURL(syncRepoURL)
        if !syncToken.isEmpty { syncStore.setToken(syncToken) }
        if !syncPassword.isEmpty { syncStore.setSyncPassword(syncPassword) }
        flash("已保存，点「立即同步」测试", error: false)
    }

    func importTokenFromGH() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["gh", "auth", "token"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0,
                  let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                flash("读取失败：请先在本机执行 gh auth login", error: true)
                return
            }
            syncStore.setToken(token)
            flash("Token 已导入（存本机钥匙串）", error: false)
        } catch {
            flash("读取失败：\(error.localizedDescription)", error: true)
        }
    }

    // MARK: - iPhone 同步（局域网）

    var iphoneSyncSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("iPhone 同步").font(.headline)
            Text("Mac 起局域网服务，iPhone 扫码配对后双向同步收藏/历史/进度并传输已下载漫画。payload 加密传输，明文不出本机。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("开启服务", isOn: $lan.enabled)
                .font(.caption)

            if lan.enabled {
                if let addr = lan.addressText {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi").font(.caption)
                        Text(addr).font(.caption.monospaced())
                        Button("复制地址") { copyToPasteboard(addr) }
                            .buttonStyle(.borderless).font(.caption2)
                        Spacer()
                        if lan.running == false {
                            ProgressView().controlSize(.small)
                        }
                    }

                    HStack(alignment: .top, spacing: 14) {
                        QRCodeView(text: lan.qrConfigString() ?? "")
                            .frame(width: 148, height: 148)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("iPhone 未扫码时可手动输入：").font(.caption)
                                .foregroundStyle(.secondary)
                            Text(lan.pairCode)
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .kerning(3)
                            Button("重新生成配对码") {
                                lan.regeneratePairCode()
                                flash("已重置，旧配对码失效；已配对设备不受影响", error: false)
                            }
                            .buttonStyle(.bordered).font(.caption)
                            Text("配对码既是 /pair 凭证，也是同步数据的加密密钥来源，仅限自己使用。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else if lan.lastError == nil {
                    Text("正在启动监听…（未检测到局域网 IPv4 地址）")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !lan.devices.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("已配对设备（\(lan.devices.count)）")
                        .font(.subheadline.weight(.medium))
                    ForEach(lan.devices) { d in
                        HStack(spacing: 8) {
                            Image(systemName: "iphone").font(.caption)
                            Text(d.name).font(.caption)
                            Text(Self.relativeTime(d.pairedAt))
                                .font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Button("撤销") {
                                lan.revoke(d.id)
                                flash("已撤销「\(d.name)」，其会话立即失效", error: false)
                            }
                            .buttonStyle(.borderless).font(.caption)
                        }
                    }
                    Text("撤销后该设备的后续请求一律被拒（401），需重新扫码配对。")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let err = lan.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        flash("已复制 \(s)", error: false)
    }
}
