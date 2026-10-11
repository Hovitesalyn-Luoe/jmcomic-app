import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - 数据备份

    var backupSection: some View {
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

    func exportFavorites() {
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

    func importFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = favorites.importJSON(data)
        flash(n > 0 ? "导入 \(n) 条新收藏" : "无新增（都已存在）", error: n == 0)
    }

    func exportState() {
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

    func importState() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        let n = library.importState(data)
        flash(n > 0 ? "已合并 \(n) 条进度" : "无新增进度", error: n == 0)
    }
}
