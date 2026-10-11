import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// 设置页（侧边栏独立页面，两栏排版）。
///
/// 左栏：本地偏好 / 隐私保护；右栏：数据备份 / GitHub 同步。
struct SettingsView: View {

    @ObservedObject var library = LibraryStore.shared
    @ObservedObject var updates = UpdateChecker.shared
    @ObservedObject var favorites = FavoriteStore.shared
    @ObservedObject var downloads = DownloadStore.shared

    /// 启动时自动检查更新（默认开）
    @AppStorage(UpdateChecker.autoCheckKey) var autoCheckUpdates = true
    @State var notice: String?
    @State var isError = false

    // 隐私保护快捷键
    @State var shortcutEnabled = UserDefaults.standard.bool(forKey: "privacyShortcutEnabled")
    @State var shortcutText = SettingsView.shortcutDisplay()
    @State var recordingShortcut = false
    @State var shortcutMonitor: Any?

    // 阅读器偏好：@AppStorage 会自动落盘，并且所有界面实时同步
    @AppStorage(ReaderPrefs.modeKey) var readerMode: ReaderMode = ReaderPrefs.currentMode()
    @AppStorage(ReaderPrefs.directionKey) var spreadDirection: SpreadDirection = ReaderPrefs.currentDirection()
    @AppStorage(ReaderPrefs.pagingKey) var readerPaging: PagingStyle = ReaderPrefs.currentPaging()

    // GitHub 同步
    @ObservedObject var syncStore = SyncStore.shared
    @State var syncRepoURL = SyncStore.shared.repoURL
    @State var syncToken = ""
    @State var syncPassword = ""

    // iPhone 局域网同步
    @ObservedObject var lan = LanSyncServer.shared

    // 内容过滤
    static let exclusionOptions = [
        "NTR", "觸手", "獸人", "偽娘", "百合", "純愛",
        "兄妹", "亂倫", "中出", "足控", "3D", "AI繪圖",
        "全彩", "血腥", "獵奇", "SM", "強暴", "睡奸",
    ]
    @State var excluded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    var initialExcluded: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "excludedTags") ?? [])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                        card { updateSection }
                        card { backupSection }
                        card { githubSyncSection }
                        card { iphoneSyncSection }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
    }

    func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { c() }
            .padding(14)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 工具

    static func relativeTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }

    func flash(_ msg: String, error: Bool) {
        notice = msg
        isError = error
    }
}
