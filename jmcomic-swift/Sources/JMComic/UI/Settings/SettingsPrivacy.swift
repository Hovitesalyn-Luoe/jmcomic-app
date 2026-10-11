import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - 隐私保护

    var privacySection: some View {
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

    func toggleRecording() {
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

    func stopRecording() {
        if let m = shortcutMonitor {
            NSEvent.removeMonitor(m)
            shortcutMonitor = nil
        }
    }

    static func shortcutDisplay() -> String {
        let kc = UserDefaults.standard.integer(forKey: "privacyShortcutKeyCode")
        guard kc != 0 else { return "未设置" }
        let mods = UInt(UserDefaults.standard.integer(forKey: "privacyShortcutModifiers"))
        let char = UserDefaults.standard.string(forKey: "privacyShortcutChar") ?? "?"
        return modifierText(NSEvent.ModifierFlags(rawValue: mods)) + char
    }

    static func modifierText(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.command) { s += "⌘" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.shift) { s += "⇧" }
        return s
    }
}
