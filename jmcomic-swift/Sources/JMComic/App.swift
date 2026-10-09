import SwiftUI
import AppKit

@main
struct JMComicApp: App {
    /// 侧边栏是否展开：BrowseView 用同一个键，⌘S 切换
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    init() {
        if CommandLine.arguments.contains("--selfcheck") { SelfCheck.run() }
        installPrivacyShortcut()
        Concurrency.detached {
            await SyncStore.shared.sync()
        }
        // 恢复「iPhone 同步」开关：上次开启过就自动重启局域网服务（Bonjour 广播）
        Concurrency.detached {
            await LanSyncServer.shared.applyStartupState()
        }
        NSApplication.shared.setActivationPolicy(.regular)
    }

    private func installPrivacyShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            let d = UserDefaults.standard
            guard d.bool(forKey: "privacyShortcutEnabled") else { return ev }
            let kc = d.integer(forKey: "privacyShortcutKeyCode")
            guard ev.keyCode == kc else { return ev }
            let mods = UInt(d.integer(forKey: "privacyShortcutModifiers"))
            guard ev.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue == mods
            else { return ev }
            NSApp.keyWindow?.miniaturize(nil)
            return nil
        }
    }

    var body: some Scene {
        WindowGroup("JMComic") {
            BrowseView()
                .frame(minWidth: 900, minHeight: 620)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                    Task { await JmClient.shared.bootstrap() }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .sidebar) {
                Button(sidebarVisible ? "隐藏侧边栏" : "显示侧边栏") {
                    sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
