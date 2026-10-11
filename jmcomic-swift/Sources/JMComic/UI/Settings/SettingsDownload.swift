import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - 下载位置

    /// 默认下载根目录（与 DownloadStore 的默认值保持一致）
    static var defaultDownloadRoot: URL {
        let d = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        return d.appendingPathComponent("JMComic", isDirectory: true)
    }

    var downloadSection: some View {
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

    func chooseDownloadFolder() {
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
}
