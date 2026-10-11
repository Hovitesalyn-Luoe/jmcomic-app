import SwiftUI
import AppKit

extension SettingsView {

    // MARK: - 本地偏好

    var preferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("本地偏好").font(.headline)
            Toggle("无痕模式（不写历史/进度）", isOn: $library.privateMode)
                .font(.caption)
            Text("阅读方式").font(.subheadline.weight(.medium))
            Picker("", selection: $readerMode) {
                ForEach(ReaderMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("单页=一屏一页；连续=长条滚动；双页=像实体书那样对开（第 1 页单独）。翻页方式选「左右翻页」后可用双指左右滑翻页。")
                .font(.caption2).foregroundStyle(.secondary)

            if readerMode != .continuous {
                Picker("翻页方式", selection: $readerPaging) {
                    ForEach(PagingStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .font(.caption)
                .pickerStyle(.menu)
            }

            if readerMode == .spread {
                Picker("双页方向", selection: $spreadDirection) {
                    ForEach(SpreadDirection.allCases) { dir in
                        Text(dir.label).tag(dir)
                    }
                }
                .font(.caption)
                .pickerStyle(.menu)
            }

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
}
