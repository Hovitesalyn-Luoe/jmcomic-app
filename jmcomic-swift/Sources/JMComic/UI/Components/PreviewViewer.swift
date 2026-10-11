import SwiftUI
import CoreGraphics

/// 预览查看器：与阅读器完全隔离的看图窗口。
///
/// 只显示已解码的预览图：左右切换、双击放大，**不调任何 record**——
/// 不会写历史、不会写进度、不会污染任何阅读状态。
/// 用完即走，随时可关。
struct PreviewViewer: View {
    let images: [CGImage]
    @State var startIndex: Int

    @Environment(\.dismiss) private var dismiss
    @State private var index: Int
    @State private var zoomed = false

    init(images: [CGImage], startIndex: Int) {
        self.images = images
        self.startIndex = startIndex
        _index = State(initialValue: min(max(startIndex, 0), max(images.count - 1, 0)))
    }

    var body: some View {
        ZStack {
            // 点图片旁边的黑边：直接关闭（不用 Esc/按钮）
            Color.black.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            if !images.isEmpty {
                Image(decorative: images[index], scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomed ? 2 : 1)
                    .onTapGesture(count: 2) { zoomed.toggle() }
                    // 图片上单击不关闭（空操作拦截，避免误关）
                    .onTapGesture(count: 1) {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // 左右切换
            HStack {
                Button { prev() } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                Spacer()
                Button { next() } label: { Image(systemName: "chevron.right") }
                    .disabled(index >= images.count - 1)
            }
            .buttonStyle(.plain)
            .font(.title2)
            .padding(.horizontal, 18)
        }
        .overlay(alignment: .top) {
            HStack {
                Text("预览 \(index + 1) / \(images.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered).font(.caption)
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        // 两指向右滑 = 关掉预览（本页翻图用的是左右箭头按钮，不会撞车）
        .swipeBackToPrevious { dismiss() }
    }

    private func prev() {
        guard index > 0 else { return }
        index -= 1
        zoomed = false
    }

    private func next() {
        guard index < images.count - 1 else { return }
        index += 1
        zoomed = false
    }
}

