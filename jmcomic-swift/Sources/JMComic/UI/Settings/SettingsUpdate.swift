import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - 检查更新（逻辑在 Core/UpdateChecker.swift，启动检查也用它）

    var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("软件更新").font(.headline)
            Text("当前版本：\(updates.currentTag)").font(.caption).foregroundStyle(.secondary)

            Toggle("启动时自动检查更新", isOn: $autoCheckUpdates)
                .font(.caption)

            HStack(spacing: 8) {
                Button("检查更新") { updates.check() }
                    .font(.caption)
                    .disabled(isChecking)

                switch updates.state {
                case .idle:
                    EmptyView()
                case .checking:
                    ProgressView().controlSize(.small)
                case .latest(let v):
                    Label("当前已是最新版本（\(v)）", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.green)
                case .newer(let v, let page):
                    Button {
                        updates.openReleasePage(page)
                    } label: {
                        Label("发现新版本 \(v)，前往下载", systemImage: "arrow.down.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)
                case .failed:
                    Label("检查失败，请稍后重试", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Text("更新通过 GitHub 发布，检查时需要联网。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    var isChecking: Bool {
        if case .checking = updates.state { return true }
        return false
    }
}
