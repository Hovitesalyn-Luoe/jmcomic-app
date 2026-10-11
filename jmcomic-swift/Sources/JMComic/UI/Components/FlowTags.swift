import SwiftUI
import CoreGraphics

/// 标签自动换行（胶囊样式）。可传点击回调（分类页点标签搜索用）。
struct FlowTags: View {
    let tags: [String]
    var onTap: ((String) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 6, alignment: .leading)],
                  alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { t in
                if let onTap {
                    Button {
                        onTap(t)
                    } label: {
                        tagView(t)
                    }
                    .buttonStyle(.plain)
                } else {
                    tagView(t)
                }
            }
        }
    }

    private func tagView(_ t: String) -> some View {
        Text(t).font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color.primary.opacity(0.08))
            .foregroundStyle(.secondary)
            .clipShape(Capsule())
    }
}
