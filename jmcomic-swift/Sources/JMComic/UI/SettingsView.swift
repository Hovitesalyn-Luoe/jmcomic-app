import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 设置页（侧边栏独立页面，两栏排版）。
///
/// 左栏：本地偏好 / 隐私保护；右栏：数据备份 / GitHub 同步。
struct SettingsView: View {

    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var favorites = FavoriteStore.shared
    @ObservedObject private var downloads = DownloadStore.shared

    /// 设置页只响应「回到顶部」（静态两栏，不做位置记忆）
    @State private var scrolledID: String?

    @State private var notice: String?
    @State private var isError = false

    // 隐私保护快捷键
    @State private var shortcutEnabled = UserDefaults.standard.bool(forKey: "privacyShortcutEnabled")
    @State private var shortcutText = SettingsView.shortcutDisplay()
    @State private var recordingShortcut = false
    @State private var shortcutMonitor: Any?

    // 阅读器默认单页模式
    @State private var defaultSinglePage = UserDefaults.standard.bool(forKey: "readerSinglePage") {
        didSet { UserDefaults.standard.set(defaultSinglePage, forKey: "readerSinglePage") }
    }

    // GitHub 同步
    @ObservedObject private var syncStore = SyncStore.shared
    @State private var syncRepoURL = SyncStore.shared.repoURL
    @State private var syncToken = ""
    @State private var syncPassword = ""

    // iPhone 局域网同步
    @ObservedObject private var lan = LanSyncServer.shared

    // 内容过滤
    private static let exclusionOptions = [
        "NTR", "觸手", "獸人", "偽娘", "百合", "純愛",
        "兄妹", "亂倫", "中出", "足控", "3D", "AI繪圖",
        "全彩", "血腥", "獵奇", "SM", "強暴", "睡奸",
    ]
    @State private var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    private var initialExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 顶部哨兵：工具栏「回到顶部」用它定位
                Color.clear.frame(height: 0).id("settings-top")
                Text("设置").font(.title2.weight(.semibold))
                LazyVGrid(columns: [
                    GridItem(.flexible(minimum: 330), alignment: .top),
                    GridItem(.flexible(minimum: 330), alignment: .top),
                ], alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        card { preferenceSection }
                        card { downloadSection }
                        card { privacySection }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        card { backupSection }
                        card { githubSyncSection }
                        card { iphoneSyncSection }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .scrollMemory(page: "settings", scrolledID: $scrolledID, topID: "settings-top", remember: false)
        }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 下载位置

    /// 默认下载根目录（与 DownloadStore 的默认值保持一致）
    private static var defaultDownloadRoot: URL {
        let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("JMComic", isDirectory: true)
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("下载").font(.headline)

            Text("保存位置").font(.subheadline.weight(.medium))
            Text(downloads.root.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Button("更改…") { chooseDownloadFolder() }
                Button("在访达中打开") {
                    try? FileManager.default.createDirectory(at: downloads.root,
                                                             withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([downloads.root])
                }
                if UserDefaults.standard.string(forKey: "downloadRoot") != nil {
                    Button("恢复默认") { downloads.root = Self.defaultDownloadRoot }
                }
            }
            .font(.caption)

            Text("每本会在这个文件夹里建自己的子文件夹。改位置只影响之后新下载的；已经下好的留在原处，本地漫画里照样能看到。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloads.root
        panel.prompt = "选用此文件夹"
        panel.message = "选择下载保存的位置（JMComic 会在其中为每本建子文件夹）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloads.root = url
        flash("下载位置已改为 \(url.path)", error: false)
    }

    // MARK: - 本地偏好

    private var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地偏好").font(.headline)
            Toggle("无痕模式（不写历史/进度）", isOn: $library.privateMode)
                .font(.caption)
            Toggle("阅读器默认单页模式", isOn: $defaultSinglePage)
                .font(.caption)
            Text("单页=一屏一页翻书；连续=长条滚动。阅读器里也能临时切。")
                .font(.caption2).foregroundStyle(.secondary)

            Divider().padding(.vertical, 2)

            Text("内容过滤（不感兴趣）").font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6)],
                      alignment: .leading, spacing: 6) {
                ForEach(Self.exclusionOptions, id: \.self) { t in
                    Button {
                        if excluded.contains(t) { excluded.remove(t) } else { excluded.insert(t) }
                    } label: {
                        Text(t).font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(excluded.contains(t)
                                        ? Color.accentColor.opacity(0.3)
                                        : Color.primary.opacity(0.08))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Text(excluded.isEmpty ? "未设置过滤" : "已排除：\(excluded.sorted().joined(separator: ", "))")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { excluded.removeAll() }
                    .buttonStyle(.borderless).font(.caption)
                    .disabled(excluded.isEmpty)
            }
            Button("保存过滤") {
                UserDefaults.standard.set(Array(excluded), forKey: "excludedTags")
                flash("已保存：\(excluded.isEmpty ? "不过滤" : excluded.sorted().joined(separator: ", "))",
                      error: false)
            }
            .buttonStyle(.bordered).font(.caption)
            .disabled(excluded == initialExcluded)
            Text("热门/最新/分类/推荐都会剔除含这些标签的作品。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 隐私保护

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("隐私保护").font(.headline)
            Text("侧边栏底部「保护」按钮一键最小化。")
                .font(.caption2).foregroundStyle(.secondary)

            Toggle("启用快捷键", isOn: $shortcutEnabled)
                .font(.caption)
                .onChange(of: shortcutEnabled) { _, on in
                    UserDefaults.standard.set(on, forKey: "privacyShortcutEnabled")
                    if !on { stopRecording() }
                }

            if shortcutEnabled {
                HStack(spacing: 8) {
                    Button(recordingShortcut ? "请按键…（Esc 取消）"
                                            : "快捷键：\(shortcutText)") {
                        toggleRecording()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    if shortcutText != "未设置" {
                        Button("清除") {
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutKeyCode")
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutModifiers")
                            UserDefaults.standard.removeObject(forKey: "privacyShortcutChar")
                            shortcutText = "未设置"
                        }
                        .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }

    private func toggleRecording() {
        recordingShortcut.toggle()
        guard recordingShortcut else { stopRecording(); return }
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            if ev.keyCode == 53 {
                self.recordingShortcut = false
                self.stopRecording()
                return nil
            }
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let char = ev.charactersIgnoringModifiers?.uppercased().first.map(String.init) ?? "?"
            UserDefaults.standard.set(Int(ev.keyCode), forKey: "privacyShortcutKeyCode")
            UserDefaults.standard.set(Int(flags.rawValue), forKey: "privacyShortcutModifiers")
            UserDefaults.standard.set(char, forKey: "privacyShortcutChar")
            self.shortcutText = SettingsView.modifierText(flags) + char
            self.recordingShortcut = false
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let m = shortcutMonitor {
            NSEvent.removeMonitor(m)
            shortcutMonitor = nil
        }
    }

    private static func shortcutDisplay() -> String {
        let kc = UserDefaults.standard.integer(forKey: "privacyShortcutKeyCode")
        guard kc != 0 else { return "未设置" }
        let mods = UInt(UserDefaults.standard.integer(forKey: "privacyShortcutModifiers"))
        let char = UserDefaults.standard.string(forKey: "privacyShortcutChar") ?? "?"
        return modifierText(NSEvent.ModifierFlags(rawValue: mods)) + char
    }

    private static func modifierText(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.command) { s += "⌘" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.shift) { s += "⇧" }
        return s
    }

    // MARK: - GitHub 同步

    private var githubSyncSection: some View {
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

    private func saveSyncConfig() {
        syncStore.setRepoURL(syncRepoURL)
        if !syncToken.isEmpty { syncStore.setToken(syncToken) }
        if !syncPassword.isEmpty { syncStore.setSyncPassword(syncPassword) }
        flash("已保存，点「立即同步」测试", error: false)
    }

    private func importTokenFromGH() {
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

    private var iphoneSyncSection: some View {
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

    private func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        flash("已复制 \(s)", error: false)
    }

    // MARK: - 数据备份

    private var backupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("数据备份").font(.headline)
            Text("换机器/替换 App 前导出，之后导入（按 id 合并，不覆盖）。")
                .font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("导出收藏（\(favorites.entries.count)）") { exportFavorites() }
                Button("导入收藏") { importFavorites() }
            }
            .font(.caption)
            HStack(spacing: 8) {
                Button("导出历史进度（\(library.history.count)）") { exportState() }
                Button("导入历史进度") { importState() }
            }
            .font(.caption)
        }
    }

    private func exportFavorites() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jmcomic-favorites.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = favorites.exportJSON() else { return }
        do {
            try data.write(to: url, options: .atomic)
            flash("已导出 \(favorites.entries.count) 条收藏", error: false)
        } catch {
            flash("导出失败：\(error.localizedDescription)", error: true)
        }
    }

    private func importFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = favorites.importJSON(data)
        flash(n > 0 ? "导入 \(n) 条新收藏" : "无新增（都已存在）", error: n == 0)
    }

    private func exportState() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "jmcomic-history.json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = library.exportState() else { return }
        do {
            try data.write(to: url, options: .atomic)
            flash("已导出历史 \(library.history.count) 条、进度 \(library.positions.count) 条", error: false)
        } catch {
            flash("导出失败：\(error.localizedDescription)", error: true)
        }
    }

    private func importState() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = library.importState(data)
        flash(n > 0 ? "已合并 \(n) 条进度" : "无新增进度", error: n == 0)
    }

    // MARK: - 工具

    private static func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    private func flash(_ msg: String, error: Bool) {
        notice = msg
        isError = error
    }
}

/// 二维码渲染：CoreImage CIFilter.qrCodeGenerator → CGImage → NSImage。
/// 内容即 LanSyncServer.qrConfigString() 的自包含配置串。
private struct QRCodeView: View {
    let text: String

    var body: some View {
        Group {
            if let ns = Self.image(for: text) {
                Image(nsImage: ns)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if !text.isEmpty {
                Text("二维码生成失败").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func image(for text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage, ci.extent.width > 0 else { return nil }
        // 原始模块矩阵很小，放大到 ~300px 供屏显清晰
        let scale = 300.0 / ci.extent.width
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
